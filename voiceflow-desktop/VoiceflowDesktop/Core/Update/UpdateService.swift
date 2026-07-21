import AppKit
import Foundation

/// Lightweight in-app updater built on the project's **public GitHub Releases**
/// — no Sparkle, no appcast, no EdDSA keys, no extra hosting.
///
/// Flow:
///   1. Daily (and on launch, throttled) it asks the GitHub API for the latest
///      release and compares the tag to the running version.
///   2. If a newer version exists it shows a native popup with the release
///      notes and three choices: update now / later / always-automatic.
///   3. "Update" downloads the notarised DMG, **verifies its Developer ID
///      signature** (team `GD42PF6FBY`) so nothing unsigned can be installed,
///      then self-replaces the app bundle and relaunches.
///
/// The "deploy" workflow for the maintainer is just: publish a GitHub release
/// with a notarised `Voiceflow-x.y.z.dmg` asset and release notes. That's it.
@MainActor
final class UpdateService {

    static let shared = UpdateService()

    // MARK: - Configuration

    /// owner/repo of the public distribution repository.
    private let repo = "tmurschetz/voiceflow"
    /// The Developer ID Team that legitimately signs Voiceflow. A downloaded
    /// build must match this or it is refused — defends against a tampered or
    /// spoofed release asset.
    private let expectedTeamID = "GD42PF6FBY"

    private let lastCheckKey  = "com.voiceflow.desktop.lastUpdateCheck"
    private let skippedKey    = "com.voiceflow.desktop.skippedUpdateVersion"
    static let autoUpdateKey  = "com.voiceflow.desktop.autoUpdateEnabled"

    private var isWorking = false

    private var autoUpdateEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoUpdateKey)
    }

    // MARK: - Release model

    private struct Release {
        let version: String      // normalised numeric string, e.g. "1.1.0"
        let title: String        // release name (falls back to tag)
        let notes: String        // markdown body
        let dmgURL: URL?         // first .dmg asset, if any
        let pageURL: URL         // html release page (fallback target)
    }

    // MARK: - Public entry points

    /// Launch / daily heartbeat. Silent unless an update is actually found.
    func checkInBackground() {
        let now  = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard now - last > 23 * 3600 else { return }   // ~once per day
        Task { await check(manual: false) }
    }

    /// "Nach Updates suchen…" menu item — always reports a result.
    func checkManually() {
        Task { await check(manual: true) }
    }

    // MARK: - Core

    private func check(manual: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        do {
            guard let release = try await fetchLatest() else {
                if manual { info("Keine Update-Info", "Konnte die Release-Informationen nicht laden. Bitte später erneut versuchen.") }
                return
            }

            let current = AppInfo.version
            guard Self.compareVersions(release.version, current) > 0 else {
                if manual { info("Du bist aktuell ✅", "Voiceflow \(current) ist bereits die neueste Version.") }
                return
            }

            // A newer version exists.
            if !manual && !autoUpdateEnabled,
               UserDefaults.standard.string(forKey: skippedKey) == release.version {
                return   // user chose "skip this version" on a previous background check
            }

            if autoUpdateEnabled {
                await downloadAndInstall(release)         // silent path
            } else {
                presentPrompt(for: release)               // ask the user
            }
        } catch {
            NSLog("[VF-Update] check failed: %@", String(describing: error))
            if manual { info("Update-Prüfung fehlgeschlagen", error.localizedDescription) }
        }
    }

    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Voiceflow-Desktop", forHTTPHeaderField: "User-Agent")   // GitHub requires a UA
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct GHRelease: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: String
            let assets: [Asset]
            let draft: Bool?
            let prerelease: Bool?
        }
        let r = try JSONDecoder().decode(GHRelease.self, from: data)
        if r.draft == true || r.prerelease == true { return nil }

        let dmg = r.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        return Release(
            version: normalise(r.tag_name),
            title:   (r.name?.isEmpty == false ? r.name! : r.tag_name),
            notes:   r.body ?? "",
            dmgURL:  dmg.flatMap { URL(string: $0.browser_download_url) },
            pageURL: URL(string: r.html_url)!
        )
    }

    // MARK: - Prompt

    private func presentPrompt(for release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Voiceflow \(release.version) ist verfügbar"
        alert.informativeText = trimmedNotes(release.notes, title: release.title)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Jetzt aktualisieren")     // .alertFirstButtonReturn
        alert.addButton(withTitle: "Später")                  // .alertSecondButtonReturn
        alert.addButton(withTitle: "Automatisch aktualisieren") // .alertThirdButtonReturn

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await downloadAndInstall(release) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: Self.autoUpdateKey)
            Task { await downloadAndInstall(release) }
        default:
            // "Später" — remember the skip so we don't nag on every daily check.
            UserDefaults.standard.set(release.version, forKey: skippedKey)
        }
    }

    /// Keeps the release notes readable inside an NSAlert (strips heavy markdown,
    /// caps the length).
    private func trimmedNotes(_ body: String, title: String) -> String {
        var text = body
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = title }
        if text.count > 700 { text = String(text.prefix(700)) + "…" }
        return text
    }

    // MARK: - Download + verify + self-install

    private func downloadAndInstall(_ release: Release) async {
        guard let dmgURL = release.dmgURL else {
            // No DMG asset attached — fall back to opening the release page.
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        do {
            // 1. Download the DMG to a temp file.
            let (tmp, _) = try await URLSession.shared.download(from: dmgURL)
            let dmgPath = NSTemporaryDirectory() + "Voiceflow-update.dmg"
            try? FileManager.default.removeItem(atPath: dmgPath)
            try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: dmgPath))

            // 2. Mount it (no Finder window, no extra verification prompt).
            let mountPoint = NSTemporaryDirectory() + "vf-update-mnt"
            try? FileManager.default.removeItem(atPath: mountPoint)
            guard run("/usr/bin/hdiutil", ["attach", dmgPath, "-nobrowse", "-noverify", "-mountpoint", mountPoint]) else {
                throw UpdateError.mountFailed
            }

            let newApp = mountPoint + "/Voiceflow.app"
            guard FileManager.default.fileExists(atPath: newApp) else {
                _ = run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
                throw UpdateError.appNotFound
            }

            // 3. SECURITY: refuse anything not signed by our Developer ID team.
            guard verifyDeveloperID(at: newApp) else {
                _ = run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
                throw UpdateError.untrusted
            }

            // 4. Hand off to a detached script that swaps the bundle once we quit.
            installAndRelaunch(from: newApp, mountPoint: mountPoint)

        } catch {
            NSLog("[VF-Update] install failed: %@", String(describing: error))
            // Graceful fallback: let the user grab it manually.
            let alert = NSAlert()
            alert.messageText = "Automatisches Update nicht möglich"
            alert.informativeText = "Du kannst die neue Version direkt herunterladen."
            alert.addButton(withTitle: "Download öffnen")
            alert.addButton(withTitle: "Abbrechen")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.pageURL)
            }
        }
    }

    /// Verifies the downloaded bundle is valid AND carries our team identifier.
    private func verifyDeveloperID(at appPath: String) -> Bool {
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath]) else { return false }
        guard let out = runCapturing("/usr/bin/codesign", ["-dvvv", appPath]) else { return false }
        return out.contains("TeamIdentifier=\(expectedTeamID)")
    }

    /// Writes a small shell script that waits for this app to quit, replaces the
    /// running bundle in place, and relaunches — then quits to let it run.
    private func installAndRelaunch(from newApp: String, mountPoint: String) {
        let dest = Bundle.main.bundlePath            // replace wherever we run from
        let script = NSTemporaryDirectory() + "vf-update.sh"
        let body = """
        #!/bin/sh
        for i in $(seq 1 60); do
          pgrep -x Voiceflow >/dev/null 2>&1 || break
          sleep 0.5
        done
        rm -rf "\(dest)"
        cp -R "\(newApp)" "\(dest)"
        xattr -cr "\(dest)" 2>/dev/null
        hdiutil detach "\(mountPoint)" -force >/dev/null 2>&1
        open "\(dest)"
        """
        try? body.write(toFile: script, atomically: true, encoding: .utf8)

        // nohup + & reparents the script to launchd so it survives our exit.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "nohup /bin/sh \"\(script)\" >/dev/null 2>&1 &"]
        try? task.run()
        task.waitUntilExit()

        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private enum UpdateError: LocalizedError {
        case mountFailed, appNotFound, untrusted
        var errorDescription: String? {
            switch self {
            case .mountFailed: return "DMG konnte nicht geöffnet werden."
            case .appNotFound: return "Im DMG wurde keine Voiceflow.app gefunden."
            case .untrusted:   return "Die heruntergeladene Version ist nicht korrekt signiert."
            }
        }
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    private func runCapturing(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        // codesign prints to stderr.
        p.standardError = pipe
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    private func info(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Strips a leading "v" and keeps digits/dots, e.g. "v1.1.0" → "1.1.0".
    private func normalise(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Semantic-ish compare. Returns 1 if a > b, -1 if a < b, 0 if equal.
    /// Tolerant of a leading "v" and trailing suffixes (e.g. "v1.2.0-beta").
    nonisolated static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.first == "v" || t.first == "V" { t.removeFirst() }
            return t.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}
