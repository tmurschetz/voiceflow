import Foundation
import SwiftUI
import KeyboardShortcuts

@MainActor
final class SettingsViewModel: ObservableObject {

    /// Working copy — committed locally when the user presses Save.
    @Published var draft: AppSettings

    @Published var isSaving:    Bool    = false
    @Published var saveError:   String? = nil
    @Published var saveSuccess: Bool    = false

    // MARK: - API key management

    /// New key the user typed (empty = no change).
    @Published var apiKeyInput: String = ""
    @Published var apiKeyStatus: APIKeyStatus = KeychainStore.hasAPIKey ? .stored : .missing
    @Published var isValidatingKey = false

    enum APIKeyStatus: Equatable {
        case missing
        case stored
        case validated
        case invalid(String)
    }

    private let settingsService: SettingsService

    init(settingsService: SettingsService) {
        self.settingsService = settingsService
        self.draft = settingsService.currentSettings ?? AppSettings()
    }

    // MARK: - Validation

    var validationError: String? { draft.shortcutValidationError }

    var canSave: Bool { validationError == nil && !isSaving }

    var maskedKey: String { KeychainStore.maskedKey }

    // MARK: - Save settings (local)

    func save() {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        saveSuccess = false
        defer { isSaving = false }

        syncShortcutsFromRecorder()

        do {
            try settingsService.saveSettings(draft)
            saveSuccess = true
            ShortcutManager.shared.reattachHandlers()
        } catch {
            saveError = error.localizedDescription
        }
    }

    func resetToDefaults() {
        draft = AppSettings()
    }

    // MARK: - API key save

    /// Validates the typed key against the OpenAI API and stores it in the Keychain.
    func saveAPIKey() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isValidatingKey = true
        defer { isValidatingKey = false }

        do {
            try await OpenAIClient.shared.validate(apiKey: key)
            KeychainStore.apiKey = key
            apiKeyInput = ""
            apiKeyStatus = .validated
        } catch {
            apiKeyStatus = .invalid(error.localizedDescription)
        }
    }

    func removeAPIKey() {
        KeychainStore.apiKey = nil
        apiKeyStatus = .missing
    }

    // MARK: - Shortcut sync

    /// Reads the current bindings from KeyboardShortcuts (the Recorder updates
    /// them in place) and mirrors them into `draft` for display/persistence.
    private func syncShortcutsFromRecorder() {
        draft.shortcutPrivate  = shortcutString(for: .dictatePrivate)
        draft.shortcutBusiness = shortcutString(for: .dictateBusiness)
        draft.shortcutCalm     = shortcutString(for: .dictateCalm)
    }

    private func shortcutString(for name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)?.description ?? ""
    }
}
