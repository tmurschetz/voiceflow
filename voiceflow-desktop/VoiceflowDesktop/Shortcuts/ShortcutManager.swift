import AppKit
import KeyboardShortcuts

// MARK: - Shortcut Names
// KeyboardShortcuts requires static extensions at file scope.

extension KeyboardShortcuts.Name {
    static let dictatePrivate  = Self("dictate_private")
    static let dictateBusiness = Self("dictate_business")
    static let dictateRandom   = Self("dictate_random")
}

/// Manages global keyboard shortcuts for the three dictation modes.
///
/// Bindings are persisted by the KeyboardShortcuts framework in UserDefaults;
/// AppSettings stores only the display strings shown in the status panel.
final class ShortcutManager {

    static let shared = ShortcutManager()
    private init() {}

    private var handler: ((ProcessingMode) -> Void)?

    // MARK: - Registration

    /// Bind the mode handler and activate all three shortcuts.
    /// Called once at startup. Must NOT call reset() — that would wipe the
    /// user's persisted key bindings.
    func register(settings: AppSettings, handler: @escaping (ProcessingMode) -> Void) {
        migrateLegacyCalmBinding()
        self.handler = handler
        attachHandlers()
    }

    /// Re-attach handlers after settings changes.
    func reattachHandlers() {
        attachHandlers()
    }

    /// Removes key bindings AND handlers — used by the uninstaller.
    func unregisterAll() {
        KeyboardShortcuts.reset(.dictatePrivate, .dictateBusiness, .dictateRandom)
        handler = nil
    }

    // MARK: - 0.3.x migration (calm → random)

    /// The third mode was renamed from "calm" to "random". KeyboardShortcuts
    /// persists bindings under "KeyboardShortcuts_<name>" — copy the old
    /// binding once so the user's shortcut survives the rename.
    private func migrateLegacyCalmBinding() {
        let defaults = UserDefaults.standard
        let oldKey = "KeyboardShortcuts_dictate_calm"
        let newKey = "KeyboardShortcuts_dictate_random"
        if defaults.object(forKey: newKey) == nil,
           let legacy = defaults.object(forKey: oldKey) {
            defaults.set(legacy, forKey: newKey)
            defaults.removeObject(forKey: oldKey)
            NSLog("[ShortcutManager] Migrated calm → random shortcut binding")
        }
    }

    // MARK: - Private

    private func attachHandlers() {
        KeyboardShortcuts.onKeyDown(for: .dictatePrivate) { [weak self] in
            self?.handler?(.private)
        }
        KeyboardShortcuts.onKeyDown(for: .dictateBusiness) { [weak self] in
            self?.handler?(.business)
        }
        KeyboardShortcuts.onKeyDown(for: .dictateRandom) { [weak self] in
            self?.handler?(.random)
        }
    }

    // MARK: - Current Combo Strings (for display)

    @MainActor
    func currentCombos() -> (private: String, business: String, random: String) {
        return (
            private:  descriptionFor(.dictatePrivate),
            business: descriptionFor(.dictateBusiness),
            random:   descriptionFor(.dictateRandom)
        )
    }

    @MainActor
    private func descriptionFor(_ name: KeyboardShortcuts.Name) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return "" }
        return shortcut.description
    }
}
