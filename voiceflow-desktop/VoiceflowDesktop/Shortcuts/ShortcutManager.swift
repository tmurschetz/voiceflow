import AppKit
import KeyboardShortcuts

// MARK: - Shortcut Names
// KeyboardShortcuts requires static extensions at file scope.

extension KeyboardShortcuts.Name {
    static let dictatePrivate  = Self("dictate_private")
    static let dictateBusiness = Self("dictate_business")
    static let dictateCalm     = Self("dictate_calm")
}

/// Manages global keyboard shortcuts for the three dictation modes.
///
/// Shortcuts are stored in the DB as plain strings (e.g. "⌘⌥P").
/// The actual key binding is managed by KeyboardShortcuts, which persists
/// bindings in UserDefaults under the shortcut name. The DB value is the
/// canonical source of truth shown to the user; the framework binding is
/// what actually fires.
///
/// Integration pattern:
///   - Settings UI uses KeyboardShortcuts.Recorder — user picks a combo in the UI
///   - On save, we read the current binding as a display string and store it in DB
///   - On startup, we read from DB (if non-empty) but let the framework use its
///     own persisted binding (they should match after a save)
final class ShortcutManager {

    static let shared = ShortcutManager()
    private init() {}

    private var handler: ((ProcessingMode) -> Void)?

    // MARK: - Registration

    /// Bind the mode handler and activate all three shortcuts.
    /// Call after loading settings on startup, and again after the user saves settings.
    func register(settings: AppSettings, handler: @escaping (ProcessingMode) -> Void) {
        self.handler = handler
        unregisterAll()

        // Bind handlers — KeyboardShortcuts uses its own UserDefaults persistence
        // for the actual key combo. The DB strings are used for display only.
        KeyboardShortcuts.onKeyDown(for: .dictatePrivate) { [weak self] in
            self?.handler?(.private)
        }
        KeyboardShortcuts.onKeyDown(for: .dictateBusiness) { [weak self] in
            self?.handler?(.business)
        }
        KeyboardShortcuts.onKeyDown(for: .dictateCalm) { [weak self] in
            self?.handler?(.calm)
        }
    }

    func unregisterAll() {
        KeyboardShortcuts.reset(.dictatePrivate, .dictateBusiness, .dictateCalm)
    }

    // MARK: - Current Combo Strings (for saving to DB)

    /// Returns the current shortcut display strings in the order [private, business, calm].
    /// Used when saving settings to write back to the DB.
    @MainActor
    func currentCombos() -> (private: String, business: String, calm: String) {
        return (
            private:  descriptionFor(.dictatePrivate),
            business: descriptionFor(.dictateBusiness),
            calm:     descriptionFor(.dictateCalm)
        )
    }

    @MainActor
    private func descriptionFor(_ name: KeyboardShortcuts.Name) -> String {
        // KeyboardShortcuts.getShortcut(for:) returns the currently registered combo.
        // .description produces a human-readable string like "⌥⌘P".
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return "" }
        return shortcut.description
    }
}
