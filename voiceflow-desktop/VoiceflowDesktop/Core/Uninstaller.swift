import AppKit
import ServiceManagement
import KeyboardShortcuts

/// Trace-free removal of Voiceflow from this Mac, triggered from Settings.
///
/// What gets deleted, in order:
///   1. Login item registration (SMAppService)
///   2. OpenAI API key (Keychain)
///   3. Keyboard shortcut bindings + all app preferences (UserDefaults domain)
///   4. Local dictation history + the entire Application Support folder
///   5. App caches
///   6. Privacy permissions (TCC entries for mic/accessibility — best effort
///      via `tccutil reset`; macOS removes orphaned entries itself eventually)
///   7. The app bundle itself (moved to the Trash)
///
/// What CANNOT be removed programmatically: nothing user-identifying remains.
/// The unified system log retains generic log lines until macOS rotates them.
@MainActor
enum Uninstaller {

    /// Human-readable summary shown in the confirmation dialog.
    static var summary: String {
        """
        Folgendes wird unwiderruflich entfernt:

        • OpenAI API-Key aus dem Schlüsselbund
        • Alle Einstellungen und Shortcuts
        • Lokaler Diktat-Verlauf
        • Anmeldeobjekt («Bei Anmeldung starten»)
        • Mikrofon- und Bedienungshilfen-Berechtigungen
        • Die App selbst (wandert in den Papierkorb)
        """
    }

    /// Runs the confirmation dialog; on confirm wipes everything and quits.
    static func requestUninstall() {
        let alert = NSAlert()
        alert.messageText = "Voiceflow vollständig entfernen?"
        alert.informativeText = summary
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Vollständig entfernen")
        alert.addButton(withTitle: "Abbrechen")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performUninstall()
    }

    private static func performUninstall() {
        // 1. Login item
        try? SMAppService.mainApp.unregister()

        // 2. API key
        KeychainStore.apiKey = nil

        // 3. Shortcuts + preferences
        KeyboardShortcuts.reset(.dictatePrivate, .dictateBusiness, .dictateRandom)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // 4. Application Support (history + anything else we created)
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: appSupport.appendingPathComponent("Voiceflow", isDirectory: true))
        }

        // 5. Caches
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let bundleID = Bundle.main.bundleIdentifier {
            try? fm.removeItem(at: caches.appendingPathComponent(bundleID, isDirectory: true))
        }

        // 6. TCC permissions (best effort — succeeds without admin for own bundle ID)
        if let bundleID = Bundle.main.bundleIdentifier {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", "All", bundleID]
            try? proc.run()
            proc.waitUntilExit()
        }

        // 7. Trash the app bundle. Works while running — the binary stays
        //    mapped in memory until the process exits.
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.path.hasSuffix(".app") {
            try? fm.trashItem(at: bundleURL, resultingItemURL: nil)
        }

        // Farewell + quit
        let done = NSAlert()
        done.messageText = "Voiceflow wurde entfernt"
        done.informativeText = "Alle Daten sind gelöscht, die App liegt im Papierkorb. Danke & uf Wiederluege!"
        done.alertStyle = .informational
        done.addButton(withTitle: "Beenden")
        done.runModal()

        NSApp.terminate(nil)
    }
}
