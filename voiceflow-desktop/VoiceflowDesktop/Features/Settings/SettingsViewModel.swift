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
    /// AuthService reference — always reads the LIVE current session, never a stale copy.
    private let authService: AuthService

    init(settingsService: SettingsService, authService: AuthService) {
        self.settingsService = settingsService
        self.authService     = authService
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

        // Always use the live session — avoids 401s from stale token snapshots.
        guard let session = authService.currentSession else {
            saveError = "Not signed in. Please restart the app."
            return
        }

        // Sync shortcut strings from KeyboardShortcuts' own UserDefaults storage
        // before writing to the DB.
        syncShortcutsFromRecorder()

        do {
            try await performSave(session: session)
            saveSuccess = true
            ShortcutManager.shared.reattachHandlers()
        } catch APIError.httpError(let code, _) where code == 401 {
            // Access token expired — refresh and retry once.
            do {
                try await authService.refreshCurrentSession()
                guard let fresh = authService.currentSession else {
                    saveError = "Session expired. Please sign out and sign in again."
                    return
                }
                do {
                    try await performSave(session: fresh)
                    saveSuccess = true
                    ShortcutManager.shared.reattachHandlers()
                } catch {
                    saveError = error.localizedDescription
                }
            } catch {
                saveError = "Session expired. Please sign out and sign in again."
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func performSave(session: SupabaseSession) async throws {
        try await settingsService.saveSettings(draft, session: session)
    }

    func resetToDefaults() {
        draft = AppSettings()
    }

    // MARK: - Shortcut Sync

    /// Reads the current shortcut bindings from KeyboardShortcuts (which the
    /// `KeyboardShortcuts.Recorder` UI component updates in-place) and writes
    /// them back into `draft` so they're included in the DB save.
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
