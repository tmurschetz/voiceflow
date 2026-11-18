import AppKit
import ApplicationServices
import CoreAudio
import Foundation

/// Detects Microsoft Teams calls by asking Core Audio whether a Teams process
/// is currently capturing the microphone (macOS 14.2+ process objects,
/// `kAudioProcessPropertyIsRunningInput`). Independent of our own capture, so
/// it still sees the call END while we are recording it. Also reads Teams'
/// window titles via Accessibility for the participant / meeting name.
///
/// New Teams (com.microsoft.teams2) captures audio in helper processes
/// (`com.microsoft.teams2.helper`, `…modulehost`) — the main MSTeams process is
/// not even a Core Audio client. Matching only the main PID is why auto-start
/// never fired before build 34; every Teams bundle ID is matched now.
final class TeamsCallDetector {

    static let teamsBundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]

    /// Pure decision helper (unit-tested): debounced start/stop.
    struct Debouncer {
        var activeTicks = 0
        var idleTicks = 0
        let startAfter: Int
        let stopAfter: Int
        init(startAfter: Int = 3, stopAfter: Int = 5) { self.startAfter = startAfter; self.stopAfter = stopAfter }

        enum Decision { case none, start, stop }

        /// Feed one poll result; returns whether a transition fired.
        mutating func tick(callActive: Bool, recording: Bool) -> Decision {
            if callActive { activeTicks += 1; idleTicks = 0 } else { idleTicks += 1; activeTicks = 0 }
            if !recording, activeTicks == startAfter { return .start }
            if recording, idleTicks == stopAfter { return .stop }
            return .none
        }
    }

    static func teamsApp() -> NSRunningApplication? {
        for id in teamsBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return app }
        }
        return nil
    }

    /// Any Teams process (main app, WebView helper, module host).
    static func isTeamsBundle(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.microsoft.teams")
    }

    /// True when a Teams process has an active microphone input stream.
    static func teamsIsUsingMicrophone() -> Bool {
        !teamsProcessesUsingMicrophone().isEmpty
    }

    /// Bundle IDs of Teams processes currently capturing audio input.
    static func teamsProcessesUsingMicrophone() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr else { return [] }

        var found: [String] = []
        for obj in objects {
            guard let bundle = bundleID(of: obj), isTeamsBundle(bundle) else { continue }
            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(obj, &runAddr, 0, nil, &runSize, &running) == noErr, running != 0 {
                found.append(bundle)
            }
        }
        return found
    }

    @available(macOS 14.2, *)
    private static func bundleID(of obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Teams window titles (Accessibility).
    static func teamsWindowTitles() -> [String] {
        guard let teams = teamsApp() else { return [] }
        let app = AXUIElementCreateApplication(teams.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        var titles: [String] = []
        for w in windows {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success,
               let title = t as? String, !title.isEmpty {
                titles.append(title)
            }
        }
        return titles
    }

    // MARK: - Participant / meeting name

    /// Teams areas that show up as the first part of a window title.
    static let sections: Set<String> = [
        "chat", "calendar", "kalender", "activity", "aktivität", "teams and channels", "teams und kanäle",
        "teams", "calls", "anrufe", "files", "dateien", "apps", "copilot", "onedrive", "people", "personen",
        "assignments", "settings", "einstellungen", "sharing control bar", "meeting compact view",
        "notifications", "benachrichtigungen", "microsoft teams"
    ]

    /// One window title → (Teams area, the meaningful rest). Strips the
    /// "| Tenant | account@domain" suffix, "Microsoft Teams" and "Pinned window".
    /// "Calendar | ISOLUTIONS AG | me@x.ch" → ("calendar", "").
    static func parseTitle(_ raw: String) -> (section: String?, name: String) {
        var parts = raw.components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let at = parts.firstIndex(where: { $0.contains("@") && !$0.contains(" ") }) {
            parts.removeSubrange((at > 0 ? at - 1 : at)...)   // tenant + account (+ anything after)
        }
        parts.removeAll { ["microsoft teams", "pinned window", "angeheftetes fenster"].contains($0.lowercased()) }
        var section: String? = nil
        if let first = parts.first, sections.contains(first.lowercased()) {
            section = first.lowercased()
            parts.removeFirst()
        }
        var name = parts.joined(separator: " | ")
        for prefix in ["Call with ", "Anruf mit ", "Meeting with ", "Besprechung mit "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            if section == nil { section = "call" }
        }
        return (section, name)
    }

    /// Best meeting/participant name from the window titles seen during a call.
    /// `newAtStart` = titles of windows that appeared when the call began — the
    /// call window itself — and win ties. Long-open windows (a calendar entry,
    /// a chat) only count when nothing better exists.
    static func participantGuess(from titles: Set<String>, newAtStart: Set<String> = []) -> String? {
        var best: (score: Double, name: String)? = nil
        for raw in titles {
            let (section, name) = parseTitle(raw)
            guard !name.isEmpty else { continue }
            var score: Double
            switch section {
            case "meeting compact view", "call": score = 3
            case nil:                            score = 2
            case "chat":                         score = 1
            default:                             continue
            }
            if newAtStart.contains(raw) { score += 1.5 }
            if best == nil || score > best!.score || (score == best!.score && name.count < best!.name.count) {
                best = (score, name)
            }
        }
        return best?.name
    }
}
