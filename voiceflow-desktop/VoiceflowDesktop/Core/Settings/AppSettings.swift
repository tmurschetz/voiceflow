import Foundation

/// The full set of user-configurable settings.
/// Persisted in `user_settings` table; cached locally in UserDefaults for fast startup.
///
/// Schema: user_settings (confirmed columns)
///   shortcut_private (text, default '')
///   shortcut_business (text, default '')
///   shortcut_calm (text, default '')
///   auto_detect_language (boolean, default true)
///   manual_language_override (text, nullable)
///   output_mode (text, default 'replace')   ← DB uses 'replace', not 'insert_into_field'
///   microphone_device (text, nullable)       ← NOT microphone_device_id
///   auto_insert (boolean, default true)
///   default_language (text, default 'auto')
///   default_mode (text, default 'clean')
struct AppSettings: Codable, Equatable {

    // MARK: - Shortcuts
    // Empty string means "not configured". Stored as-is in the DB.

    var shortcutPrivate:  String = ""
    var shortcutBusiness: String = ""
    var shortcutCalm:     String = ""

    // MARK: - Language

    var autoDetectLanguage: Bool = true
    var manualLanguageOverride: SupportedLanguage = .german
    /// DB column: default_language. Fallback/hint language stored in DB.
    var defaultLanguage: String = "auto"

    // MARK: - Output

    /// Maps to output_mode in DB. Use .dbValue to get the DB string.
    var outputMode: OutputMode = .insertIntoField
    /// DB column: auto_insert. Whether to auto-insert without confirmation.
    var autoInsert: Bool = true

    // MARK: - Mode

    /// DB column: default_mode. Default processing mode (e.g. 'clean').
    /// Kept as raw string to round-trip DB values faithfully.
    var defaultMode: String = "clean"

    // MARK: - Microphone

    /// DB column: microphone_device (nullable). nil = system default.
    var microphoneDevice: String? = nil

    // MARK: - Derived

    var language: LanguageSelection {
        autoDetectLanguage ? .autoDetect : .manual(manualLanguageOverride)
    }

    // MARK: - Validation

    /// Validates that no two non-empty shortcuts have the same value.
    /// Empty strings are valid (means "not configured").
    var shortcutsAreValid: Bool {
        let nonEmpty = [shortcutPrivate, shortcutBusiness, shortcutCalm]
            .filter { !$0.isEmpty }
        return nonEmpty.count == Set(nonEmpty).count
    }

    /// Human-readable description of the validation error, if any.
    var shortcutValidationError: String? {
        shortcutsAreValid ? nil : "Two or more shortcuts are identical. Each must be unique."
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
        case .german:      return "German"
        case .english:     return "English"
        case .swissGerman: return "Swiss German"
        }
    }
}

enum LanguageSelection: Equatable {
    case autoDetect
    case manual(SupportedLanguage)

    var apiValue: String {
        switch self {
        case .autoDetect:       return "auto"
        case .manual(let lang): return lang.rawValue
        }
    }
}

// MARK: - OutputMode

/// The output behaviour after processing.
///
/// DB ↔ App mapping (output_mode column):
///   'replace'   ↔ .insertIntoField   (default)
///   'clipboard' ↔ .clipboardOnly
///   Any unknown value → .insertIntoField (safe default)
enum OutputMode: String, Codable, CaseIterable, Identifiable {
    /// Insert text into the active field via Accessibility API. Falls back to clipboard.
    case insertIntoField = "insert_into_field"
    /// Always copy to clipboard only.
    case clipboardOnly   = "clipboard_only"

    var id: String { rawValue }

    /// The value stored in the DB output_mode column.
    var dbValue: String {
        switch self {
        case .insertIntoField: return "replace"
        case .clipboardOnly:   return "clipboard"
        }
    }

    var displayName: String {
        switch self {
        case .insertIntoField: return "Insert into active text field"
        case .clipboardOnly:   return "Copy to clipboard only"
        }
    }

    /// Parse from a DB output_mode string.
    static func fromDBValue(_ raw: String) -> OutputMode {
        switch raw.lowercased() {
        case "replace", "insert", "insert_into_field": return .insertIntoField
        case "clipboard", "clipboard_only":            return .clipboardOnly
        default:                                       return .insertIntoField
        }
    }
}

// MARK: - KeyComboRecord (for KeyboardShortcuts integration)

/// Lightweight record of a key combination string stored in the DB.
struct KeyComboRecord: Codable, Equatable, Hashable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}
