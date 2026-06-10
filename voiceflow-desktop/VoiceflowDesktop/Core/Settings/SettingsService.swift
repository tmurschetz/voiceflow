import Foundation

/// Loads and saves user settings — fully local (UserDefaults), no backend.
///
/// Shortcut key bindings themselves are persisted separately by the
/// KeyboardShortcuts framework; AppSettings stores the display strings.
@MainActor
final class SettingsService: ObservableObject {

    @Published private(set) var currentSettings: AppSettings?

    private let cacheKey = "com.voiceflow.desktop.settings_v2"

    // MARK: - Load

    /// Loads settings from UserDefaults, falling back to defaults.
    @discardableResult
    func loadSettings() -> AppSettings {
        let settings: AppSettings
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        currentSettings = settings
        return settings
    }

    // MARK: - Save

    /// Persists settings locally. Validates shortcut uniqueness first.
    func saveSettings(_ settings: AppSettings) throws {
        guard settings.shortcutsAreValid else {
            throw SettingsError.shortcutsNotUnique
        }
        guard let data = try? JSONEncoder().encode(settings) else {
            throw SettingsError.encodingFailed
        }
        UserDefaults.standard.set(data, forKey: cacheKey)
        currentSettings = settings
    }
}

// MARK: - Errors

enum SettingsError: LocalizedError {
    case shortcutsNotUnique
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .shortcutsNotUnique:
            return "Zwei oder mehr Shortcuts sind identisch. Jeder Shortcut muss eindeutig sein."
        case .encodingFailed:
            return "Einstellungen konnten nicht gespeichert werden."
        }
    }
}
