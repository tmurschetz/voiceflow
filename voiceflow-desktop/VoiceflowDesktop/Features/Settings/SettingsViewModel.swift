import Foundation
import SwiftUI
import KeyboardShortcuts
import ServiceManagement

@MainActor
final class SettingsViewModel: ObservableObject {

    /// Working copy — auto-saved on every change (no Save button, System-Settings style).
    @Published var draft: AppSettings

    /// Brief "Gespeichert" flash after an auto-save.
    @Published var savedFlash: Bool = false
    @Published var saveError: String? = nil

    // MARK: - Launch at login (SMAppService, macOS 13+)

    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[Settings] Launch-at-login toggle failed: %@", String(describing: error))
                // Revert UI to the actual state
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

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
    private var flashTask: Task<Void, Never>?

    init(settingsService: SettingsService) {
        self.settingsService = settingsService
        self.draft = settingsService.currentSettings ?? AppSettings()
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Validation

    var validationError: String? { draft.shortcutValidationError }

    var maskedKey: String { KeychainStore.maskedKey }

    // MARK: - Auto-save

    /// Called on every draft change and every shortcut-recorder change.
    /// Persists locally (instant) and re-attaches shortcut handlers.
    func autoSave() {
        syncShortcutsFromRecorder()
        saveError = nil

        guard draft.shortcutsAreValid else {
            // Conflict shown inline via validationError; don't persist a broken state.
            return
        }
        do {
            try settingsService.saveSettings(draft)
            ShortcutManager.shared.reattachHandlers()
            flashSaved()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func flashSaved() {
        flashTask?.cancel()
        savedFlash = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.savedFlash = false
        }
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

    /// Mirrors the framework-persisted bindings into `draft` for display/persistence.
    private func syncShortcutsFromRecorder() {
        draft.shortcutPrivate  = shortcutString(for: .dictatePrivate)
        draft.shortcutBusiness = shortcutString(for: .dictateBusiness)
        draft.shortcutCalm     = shortcutString(for: .dictateCalm)
    }

    private func shortcutString(for name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)?.description ?? ""
    }
}
