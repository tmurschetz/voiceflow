import AppKit
import KeyboardShortcuts

// MARK: - Shortcut Names
// KeyboardShortcuts requires static extensions at file scope.

extension KeyboardShortcuts.Name {
    /// Dictate — the persisted key keeps its 1.x name so users' bindings survive 2.0.
    static let dictatePrivate   = Self("dictate_private")
    /// Transcribe — starts/stops a call recording.
    static let transcribeToggle = Self("transcribe_toggle")
}

/// Manages the global keyboard shortcuts for the two modes.
///
/// Bindings are persisted by the KeyboardShortcuts framework in UserDefaults;
/// AppSettings stores only the display strings shown in the status panel.
///
/// KeyboardShortcuts 3.x isolates its API to the main actor; all callers
/// (AppDelegate, SettingsViewModel, SetupWizard) already run there.
@MainActor
final class ShortcutManager {

    static let shared = ShortcutManager()
    private init() {}

    private var handler: ((ProcessingMode) -> Void)?

    // MARK: - Registration

    /// Bind the mode handler and activate the shortcuts.
    /// Called once at startup. Must NOT call reset() on live names — that would
    /// wipe the user's persisted key bindings.
    func register(settings: AppSettings, handler: @escaping (ProcessingMode) -> Void) {
        retireLegacyBindings()
        self.handler = handler
        attachHandlers()
    }

    /// Re-attach handlers after settings changes.
    func reattachHandlers() {
        attachHandlers()
    }

    /// Removes key bindings AND handlers — used by the uninstaller.
    func unregisterAll() {
        KeyboardShortcuts.reset(.dictatePrivate, .transcribeToggle)
        handler = nil
    }

    // MARK: - 2.0 migration (business/random removed)

    /// 1.x had three modes. Their bindings stay in UserDefaults and would keep
    /// firing if the names were ever bound again — clear them once. If the
    /// user never set a Dictate shortcut but had a Business one, move it over
    /// so dictation keeps working without a trip to Settings.
    private func retireLegacyBindings() {
        let defaults = UserDefaults.standard
        let flag = "com.voiceflow.desktop.shortcutsMigrated_v2"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let dictateKey  = "KeyboardShortcuts_dictate_private"
        let businessKey = "KeyboardShortcuts_dictate_business"
        if defaults.object(forKey: dictateKey) == nil,
           let business = defaults.object(forKey: businessKey) {
            defaults.set(business, forKey: dictateKey)
            NSLog("[ShortcutManager] Moved Business shortcut to Dictate")
        }
        for legacy in [businessKey, "KeyboardShortcuts_dictate_random", "KeyboardShortcuts_dictate_calm"] {
            defaults.removeObject(forKey: legacy)
        }
    }

    // MARK: - Private

    private func attachHandlers() {
        // onKeyDown APPENDS. Settings auto-saves on every draft change and
        // re-attaches, so handlers used to pile up — one key press then ran the
        // toggle N times and Transcribe started and stopped in the same instant.
        KeyboardShortcuts.removeAllHandlers()
        KeyboardShortcuts.onKeyDown(for: .dictatePrivate) { [weak self] in
            self?.handler?(.dictate)
        }
        KeyboardShortcuts.onKeyDown(for: .transcribeToggle) { [weak self] in
            self?.handler?(.transcribe)
        }
    }
}
