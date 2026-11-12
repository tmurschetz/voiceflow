import AppKit
import ApplicationServices
import CoreAudio
import Foundation

/// Detects Microsoft Teams calls by asking Core Audio whether the Teams
/// process is currently capturing the microphone (macOS 14.2+ process objects,
/// `kAudioProcessPropertyIsRunningInput`). Independent of our own capture, so
/// it still sees the call END while we are recording it. Also reads Teams'
/// window titles via Accessibility for participant hints.
final class TeamsCallDetector {

    static let teamsBundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]

    /// Pure decision helper (unit-tested): debounced start/stop.
    struct Debouncer {
        var activeTicks = 0
        var idleTicks = 0
        let startAfter: Int
        let stopAfter: Int
        init(startAfter: Int = 3, stopAfter: Int = 4) { self.startAfter = startAfter; self.stopAfter = stopAfter }

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

    /// True when the Teams process has an active microphone input stream.
    static func teamsIsUsingMicrophone() -> Bool {
        guard let teams = teamsApp() else { return false }
        return processIsRunningInput(pid: teams.processIdentifier)
    }

    static func processIsRunningInput(pid: pid_t) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr else { return false }

        for obj in objects {
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var objPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &objPID) == noErr, objPID == pid else { continue }
            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(obj, &runAddr, 0, nil, &runSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    /// Teams window titles (Accessibility). Generic titles are filtered so what
    /// remains is usually the call/meeting name or the 1:1 partner.
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

    /// Best participant guess from a set of window titles.
    static func participantGuess(from titles: Set<String>) -> String? {
        let cleaned = titles
            .map { $0.replacingOccurrences(of: " | Microsoft Teams", with: "")
                     .replacingOccurrences(of: "Microsoft Teams", with: "")
                     .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !["Chat", "Teams", "Kalender", "Calendar", "Aktivität", "Activity", "Anrufe", "Calls"].contains($0) }
        // Prefer the shortest meaningful title (1:1 calls show just the name).
        return cleaned.sorted { $0.count < $1.count }.first
    }
}
