import Foundation
import SwiftUI
import KeyboardShortcuts

@MainActor
final class SettingsViewModel: ObservableObject {

    /// Working copy — only committed to backend when user presses Save.
    @Published var draft: AppSettings

    @Published var isSaving:     Bool   = false
    @Published var saveError:    String? = nil
    @Published var saveSuccess:  Bool   = false

    private let settingsService: SettingsService
    private let session:         SupabaseSession

    init(settingsService: SettingsService, session: SupabaseSession) {
        self.settingsService = settingsService
        self.session         = session
        self.draft           = settingsService.currentSettings ?? AppSettings()
    }

    // MARK: - Validation

    var validationError: String? { draft.shortcutValidationError }

    var canSave: Bool { validationError == nil && !isSaving }

    // MARK: - Save

    func save() async {
        guard canSave else { return }
        isSaving     = true
        saveError    = nil
        saveSuccess  = false
        defer { isSaving = false }

        // Sync shortcut strings from KeyboardShortcuts' own UserDefaults storage
        // before writing to the DB.
        syncShortcutsFromRecorder()

        do {
            try await settingsService.saveSettings(draft, session: session)
            saveSuccess = true

            // Re-register global shortcuts with the updated bindings.
            // Note: AppDelegate's handler is replaced here; this is safe because
            // the handler is stateless (it just calls handleShortcutTriggered on
            // the delegate, not a closure that captures local state).
            ShortcutManager.shared.register(settings: draft) { _ in }
        } catch {
            saveError = error.localizedDescription
        }
    }

    func resetToDefaults() {
        draft = AppSettings()
    }

    // MARK: - Shortcut Sync

    /// Reads the current shortcut bindings from KeyboardShortcuts (which the
    /// `KeyboardShortcuts.Recorder` UI component updates in-place) and writes
    /// them back into `draft` so they're included in the DB save.
    ///
    /// Why this is needed:
    ///   `KeyboardShortcuts.Recorder` writes directly to the framework's own
    ///   UserDefaults persistence when the user picks a new combo. It does NOT
    ///   update our `draft.shortcutPrivate/Business/Calm` strings. We must read
    ///   them back via `KeyboardShortcuts.getShortcut(for:)` before saving.
    ///
    /// DB storage: we store the human-readable description (e.g. "⌘⌥P") as a
    /// convenience for display in the status-panel popover and for future
    /// cross-device sync. The KeyboardShortcuts framework itself is the
    /// authoritative source for the actual binding on this device.
    private func syncShortcutsFromRecorder() {
        draft.shortcutPrivate  = shortcutString(for: .dictatePrivate)
        draft.shortcutBusiness = shortcutString(for: .dictateBusiness)
        draft.shortcutCalm     = shortcutString(for: .dictateCalm)
    }

    /// Returns the current display string for a named shortcut, or "" if not set.
    private func shortcutString(for name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)?.description ?? ""
    }
}
