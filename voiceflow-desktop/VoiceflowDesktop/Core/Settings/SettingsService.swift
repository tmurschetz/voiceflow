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

    // MARK: - Migration

    /// One-time upgrade of the default transcription model. Builds up to 1.0.x
    /// defaulted to `gpt-4o-mini-transcribe` (cheapest, but noticeably less
    /// accurate — it mishears compounds and names, e.g. "Budget" → "Birgley").
    /// 1.1 makes `gpt-4o-transcribe` the default. Users who are still on the old
    /// default are upgraded once; the flag guarantees we never override a later
    /// deliberate choice (and that someone who *wants* the cheaper model can
    /// re-select it and have it stick).
    func migrateTranscribeModelIfNeeded() {
        let flag = "com.voiceflow.desktop.transcribeModelMigrated_v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        var settings = loadSettings()
        guard settings.transcribeModel == "gpt-4o-mini-transcribe" else { return }
        settings.transcribeModel = "gpt-4o-transcribe"
        try? saveSettings(settings)
        NSLog("[VF-Settings] Migrated transcription model: gpt-4o-mini-transcribe → gpt-4o-transcribe")
    }

    /// One-time upgrade of the rewrite model (1.1.2): mini's cleanup measurably
    /// degraded dictations (dropped qualifiers, swapped synonyms) — gpt-4o is
    /// the new default for faithful cleanup. Same pattern as above: users still
    /// on the old default are lifted once, deliberate choices stay untouched.
    func migrateTextModelIfNeeded() {
        let flag = "com.voiceflow.desktop.textModelMigrated_v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        var settings = loadSettings()
        guard settings.textModel == "gpt-4o-mini" else { return }
        settings.textModel = "gpt-4o"
        try? saveSettings(settings)
        NSLog("[VF-Settings] Migrated text model: gpt-4o-mini → gpt-4o")
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
