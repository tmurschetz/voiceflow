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

    /// Second transcription migration (1.1.2): gpt-4o-transcribe demonstrably
    /// stops transcribing at longer thinking pauses (verified on a real 20-min
    /// dictation: ended mid-sentence, 18 % less content than whisper-1; short
    /// pause-heavy dictations lost almost everything). whisper-1 transcribes
    /// the same audio completely — mishearings are fixed by the gpt-4o cleanup
    /// stage since 1.1.2, so accuracy is preserved.
    func migrateTranscribeModelToWhisperIfNeeded() {
        let flag = "com.voiceflow.desktop.transcribeModelMigrated_v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        var settings = loadSettings()
        guard settings.transcribeModel == "gpt-4o-transcribe"
                || settings.transcribeModel == "gpt-4o-mini-transcribe" else { return }
        settings.transcribeModel = "whisper-1"
        try? saveSettings(settings)
        NSLog("[VF-Settings] Migrated transcription model: %@ → whisper-1 (pause robustness)",
              settings.transcribeModel)
    }

    /// Third transcription migration (2.0): OpenAI deprecated whisper-1 and the
    /// gpt-4o transcribe models (shutdown 2027-02-26). `gpt-transcribe` is the
    /// documented successor and — verified on the same real 20-minute dictation —
    /// transcribes pause-heavy speech completely (10 894 chars vs whisper's 10 714).
    func migrateTranscribeModelToGptTranscribeIfNeeded() {
        let flag = "com.voiceflow.desktop.transcribeModelMigrated_v3"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        var settings = loadSettings()
        guard ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"].contains(settings.transcribeModel) else { return }
        let old = settings.transcribeModel
        settings.transcribeModel = "gpt-transcribe"
        try? saveSettings(settings)
        NSLog("[VF-Settings] Migrated transcription model: %@ → gpt-transcribe (deprecation)", old)
    }

    /// 2.0: Dictate is ChatGPT-style cleanup — the 1.x "Instruktion" was a
    /// persona that RESTYLED every dictation (tone, slang, sentence length), the
    /// opposite of what Dictate now promises. Park it once under a legacy key so
    /// nothing is lost (Settings can be re-filled by hand), and start 2.0 with an
    /// empty instruction. Users who open Settings and type a new one are untouched
    /// afterwards (flag).
    static let legacyInstructionKey = "com.voiceflow.desktop.legacyInstructionPrivate_v1"

    func migrateDictateInstructionForV2IfNeeded() {
        let flag = "com.voiceflow.desktop.instructionMigrated_v2"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        var settings = loadSettings()
        let old = settings.instructionPrivate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty else { return }
        defaults.set(old, forKey: Self.legacyInstructionKey)
        settings.instructionPrivate = ""
        try? saveSettings(settings)
        NSLog("[VF-Settings] 2.0: parked the 1.x Dictate instruction (%d chars) under %@", old.count, Self.legacyInstructionKey)
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
