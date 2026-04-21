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
    /// Called once at startup from AppDelegate. The KeyboardShortcuts framework
    /// persists the actual key combos in UserDefaults via KeyboardShortcuts.Recorder —
    /// we must NOT call reset() here as that would wipe those persisted bindings.
    func register(settings: AppSettings, handler: @escaping (ProcessingMode) -> Void) {
        self.handler = handler
        attachHandlers()
    }

    /// Re-attach handlers to the currently persisted key bindings.
    /// Call after settings are saved so the handler stays live.
    /// Does NOT touch key bindings — the Recorder already persisted them in UserDefaults.
    func reattachHandlers() {
        attachHandlers()
    }

    /// Removes key bindings AND handlers — call only on sign-out.
    func unregisterAll() {
        KeyboardShortcuts.reset(.dictatePrivate, .dictateBusiness, .dictateCalm)
        handler = nil
    }

    // MARK: - Private

    private func attachHandlers() {
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
