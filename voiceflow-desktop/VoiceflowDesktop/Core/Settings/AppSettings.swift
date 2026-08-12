import Foundation

/// The full set of user-configurable settings. Persisted locally in UserDefaults.
///
/// Decoding is tolerant: every field falls back to its default when missing, so
/// settings survive app updates that add new fields (and the 0.3.x rename of
/// the third mode from "calm" to "random").
struct AppSettings: Codable, Equatable {

    // MARK: - Shortcuts (display strings; bindings live in KeyboardShortcuts)

    var shortcutPrivate:  String = ""
    var shortcutBusiness: String = ""
    var shortcutRandom:   String = ""

    // MARK: - Per-mode custom instructions
    // Free-text personalisation appended to the mode's system prompt.

    var instructionPrivate:  String = ""
    var instructionBusiness: String = ""
    var instructionRandom:   String = ""

    // MARK: - Models

    /// Transcription model ID (see TranscribeModel for the catalogue).
    var transcribeModel: String = TranscribeModel.recommended.id
    /// Text model ID for tone-of-voice rewriting (see TextModel).
    var textModel: String = TextModel.recommended.id

    // MARK: - Recognition vocabulary
    // User-supplied names / brands / project & domain terms. Appended to the
    // transcription prompt so the model spells them correctly instead of guessing
    // phonetically (the "learns your words" idea, but explicit and user-controlled).

    var customVocabulary: String = ""

    // MARK: - Language

    var autoDetectLanguage: Bool = true
    var manualLanguageOverride: SupportedLanguage = .german

    // MARK: - Output

    var outputMode: OutputMode = .insertIntoField

    // MARK: - Microphone

    /// nil = system default input device.
    var microphoneDevice: String? = nil

    // MARK: - Privacy

    /// When false, dictations are not written to the local history file.
    var historyEnabled: Bool = true

    // MARK: - Derived

    var language: LanguageSelection {
        autoDetectLanguage ? .autoDetect : .manual(manualLanguageOverride)
    }

    /// Custom instruction for a given mode.
    func instruction(for mode: ProcessingMode) -> String {
        switch mode {
        case .private:  return instructionPrivate
        case .business: return instructionBusiness
        case .random:   return instructionRandom
        }
    }

    // MARK: - Validation

    var shortcutsAreValid: Bool {
        let nonEmpty = [shortcutPrivate, shortcutBusiness, shortcutRandom]
            .filter { !$0.isEmpty }
        return nonEmpty.count == Set(nonEmpty).count
    }

    var shortcutValidationError: String? {
        shortcutsAreValid ? nil : "Zwei oder mehr Shortcuts sind identisch. Jeder muss eindeutig sein."
    }

    var shortcutsAreAllEmpty: Bool {
        shortcutPrivate.isEmpty && shortcutBusiness.isEmpty && shortcutRandom.isEmpty
    }

    // MARK: - Tolerant decoding

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortcutPrivate  = try c.decodeIfPresent(String.self, forKey: .shortcutPrivate)  ?? ""
        shortcutBusiness = try c.decodeIfPresent(String.self, forKey: .shortcutBusiness) ?? ""
        // 0.3.x migration: the third mode was renamed calm → random.
        shortcutRandom = try c.decodeIfPresent(String.self, forKey: .shortcutRandom)
            ?? (try? Self.legacyCalmShortcut(decoder)) ?? ""
        instructionPrivate  = try c.decodeIfPresent(String.self, forKey: .instructionPrivate)  ?? ""
        instructionBusiness = try c.decodeIfPresent(String.self, forKey: .instructionBusiness) ?? ""
        instructionRandom   = try c.decodeIfPresent(String.self, forKey: .instructionRandom)   ?? ""
        transcribeModel = try c.decodeIfPresent(String.self, forKey: .transcribeModel) ?? TranscribeModel.recommended.id
        textModel       = try c.decodeIfPresent(String.self, forKey: .textModel)       ?? TextModel.recommended.id
        customVocabulary = try c.decodeIfPresent(String.self, forKey: .customVocabulary) ?? ""
        autoDetectLanguage = try c.decodeIfPresent(Bool.self, forKey: .autoDetectLanguage) ?? true
        manualLanguageOverride = try c.decodeIfPresent(SupportedLanguage.self, forKey: .manualLanguageOverride) ?? .german
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .insertIntoField
        microphoneDevice = try c.decodeIfPresent(String.self, forKey: .microphoneDevice)
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
    }

    private static func legacyCalmShortcut(_ decoder: Decoder) throws -> String {
        struct Legacy: Decodable { let shortcutCalm: String? }
        return try Legacy(from: decoder).shortcutCalm ?? ""
    }
}

// MARK: - Model catalogues (shown in Settings with guidance)

/// Transcription models the user can choose from, with plain-language guidance.
struct TranscribeModel: Identifiable, Equatable {
    let id: String
    let name: String
    /// One-line recommendation shown under the picker.
    let guidance: String

    static let all: [TranscribeModel] = [
        TranscribeModel(
            id: "gpt-4o-transcribe",
            name: "GPT-4o Transcribe — empfohlen",
            guidance: "Beste Genauigkeit (≈ 22 % weniger Fehler als die anderen, ≈ 0.6 Rp./Min). Erkennt Namen, Fachbegriffe und Komposita zuverlässiger — die richtige Wahl für saubere Ergebnisse."
        ),
        TranscribeModel(
            id: "gpt-4o-mini-transcribe",
            name: "GPT-4o mini Transcribe — am günstigsten",
            guidance: "Am schnellsten und halb so teuer (≈ 0.3 Rp./Min), aber etwas fehleranfälliger bei selteneren Wörtern. Für einfache, klare Diktate ok."
        ),
        TranscribeModel(
            id: "whisper-1",
            name: "Whisper — breiteste Sprachabdeckung",
            guidance: "Der bewährte Klassiker mit 98 unterstützten Sprachen (≈ 0.6 Rp./Min) — die beste Wahl für seltenere Sprachen."
        )
    ]

    static let recommended = all[0]   // gpt-4o-transcribe

    static func byID(_ id: String) -> TranscribeModel {
        all.first { $0.id == id } ?? recommended
    }
}

/// Text models for the tone-of-voice rewrite step.
struct TextModel: Identifiable, Equatable {
    let id: String
    let name: String
    let guidance: String

    static let all: [TextModel] = [
        TextModel(
            id: "gpt-4o",
            name: "GPT-4o — empfohlen",
            guidance: "Höchste Texttreue: verschluckt keine Wörter und tauscht keine Begriffe aus. Der Standard seit 1.1.2."
        ),
        TextModel(
            id: "gpt-4o-mini",
            name: "GPT-4o mini — am günstigsten",
            guidance: "Sehr schnell und günstig, neigt aber bei der Bereinigung zu kleinen Umformulierungen."
        )
    ]

    static let recommended = all[0]   // gpt-4o

    static func byID(_ id: String) -> TextModel {
        all.first { $0.id == id } ?? recommended
    }
}

// MARK: - Language

enum SupportedLanguage: String, Codable, CaseIterable, Identifiable {
    case german     = "de"
    case english    = "en"
    case swissGerman = "gsw"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .german:      return "Schweizer Hochdeutsch"
        case .english:     return "Englisch"
        case .swissGerman: return "Schweizerdeutsch (Dialekt)"
        }
    }

    /// ISO 639-1 code passed to the transcription API.
    /// Swiss German dialect is transcribed under "de".
    var whisperCode: String {
        switch self {
        case .german:      return "de"
        case .english:     return "en"
        case .swissGerman: return "de"
        }
    }
}

enum LanguageSelection: Equatable {
    case autoDetect
    case manual(SupportedLanguage)
}

// MARK: - OutputMode

enum OutputMode: String, Codable, CaseIterable, Identifiable {
    /// Insert text into the active field via Accessibility API. Falls back to clipboard.
    case insertIntoField = "insert_into_field"
    /// Always copy to clipboard only.
    case clipboardOnly   = "clipboard_only"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .insertIntoField: return "In aktives Textfeld einfügen"
        case .clipboardOnly:   return "Nur in die Zwischenablage"
        }
    }
}
