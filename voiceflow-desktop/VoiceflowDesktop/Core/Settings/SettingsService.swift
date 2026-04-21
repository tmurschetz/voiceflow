import Foundation

/// Loads and saves user settings against the `user_settings` table.
///
/// Save strategy:
///   - On load, we note whether a settings row exists for this user.
///   - On save: PATCH if row exists; POST if no row (first-time user with no web-app session).
///   - The row is identified by `user_id` (unique column), not by `id` (PK).
///
/// Column mapping (DB → AppSettings):
///   shortcut_private        ↔ shortcutPrivate
///   shortcut_business       ↔ shortcutBusiness
///   shortcut_calm           ↔ shortcutCalm
///   auto_detect_language    ↔ autoDetectLanguage
///   manual_language_override ↔ manualLanguageOverride
///   output_mode             ↔ outputMode (via OutputMode.fromDBValue / .dbValue)
///   microphone_device       ↔ microphoneDevice   [NOT microphone_device_id]
///   auto_insert             ↔ autoInsert
///   default_language        ↔ defaultLanguage
///   default_mode            ↔ defaultMode
@MainActor
final class SettingsService: ObservableObject {

    @Published private(set) var currentSettings: AppSettings?

    private let api = APIClient.shared
    private let cacheKey = "com.voiceflow.desktop.settings_v2"

    /// Tracks whether a `user_settings` row already exists for the current user.
    /// Determines whether save uses PATCH or POST.
    private var settingsRowExists = false

    // MARK: - Load

    /// Fetches settings from the backend. Falls back to local cache then defaults on failure.
    func loadSettings(session: SupabaseSession) async throws -> AppSettings {
        // Serve cached settings immediately while the network call is in flight
        if let cached = loadFromCache() {
            currentSettings = cached
        }

        let req = try api.request(
            path: Endpoints.userSettings,
            method: "GET",
            authToken: session.accessToken,
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(session.user.id.uuidString)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )

        do {
            let rows = try await api.perform(req, as: [SettingsRow].self)
            settingsRowExists = !rows.isEmpty
            let settings = rows.first.map { $0.toAppSettings() } ?? AppSettings()
            currentSettings = settings
            saveToCache(settings)
            return settings
        } catch {
            // Network failed — fall back to cache or defaults, but don't throw
            #if DEBUG
            print("[SettingsService] Load failed: \(error). Using cache/defaults.")
            #endif
            let fallback = currentSettings ?? AppSettings()
            currentSettings = fallback
            return fallback
        }
    }

    // MARK: - Save

    /// Persists settings to the backend. Validates shortcut uniqueness first.
    func saveSettings(_ settings: AppSettings, session: SupabaseSession) async throws {
        guard settings.shortcutsAreValid else {
            throw SettingsError.shortcutsNotUnique
        }

        if settingsRowExists {
            try await patchSettings(settings, session: session)
        } else {
            try await insertSettings(settings, session: session)
            settingsRowExists = true
        }

        currentSettings = settings
        saveToCache(settings)
    }

    // MARK: - PATCH (update existing row)

    private func patchSettings(_ settings: AppSettings, session: SupabaseSession) async throws {
        let body = SettingsUpdateBody(from: settings)
        let req = try api.request(
            path: Endpoints.userSettings,
            method: "PATCH",
            body: body,
            authToken: session.accessToken,
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(session.user.id.uuidString)")
            ],
            extraHeaders: ["Prefer": "return=minimal"]
        )
        try await api.perform(req)
    }

    // MARK: - POST/upsert (insert or update — safe even if row already exists)

    private func insertSettings(_ settings: AppSettings, session: SupabaseSession) async throws {
        let body = SettingsInsertBody(from: settings, userID: session.user.id)
        let req = try api.request(
            path: Endpoints.userSettings,
            method: "POST",
            body: body,
            authToken: session.accessToken,
            // resolution=merge-duplicates → upsert: INSERT if absent, UPDATE if present.
            // Prevents HTTP 409 (unique_violation) when a row already exists.
            extraHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
        try await api.perform(req)
    }

    // MARK: - Cache

    private func saveToCache(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func loadFromCache() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return nil }
        return settings
    }
}

// MARK: - DB Row types

/// Used when reading a settings row from Supabase (includes id, created_at, etc.)
///
/// No explicit CodingKeys — JSONDecoder.supabase uses convertFromSnakeCase which
/// maps "user_id" → userId, "shortcut_private" → shortcutPrivate, etc. automatically.
/// Mixing explicit snake_case CodingKeys with convertFromSnakeCase breaks decoding.
private struct SettingsRow: Decodable {
    var id: UUID?
    var userId: UUID?               // optional so a partial row doesn't crash decoding
    var shortcutPrivate: String?
    var shortcutBusiness: String?
    var shortcutCalm: String?
    var autoDetectLanguage: Bool?
    var manualLanguageOverride: String?
    var outputMode: String?
    var microphoneDevice: String?
    var autoInsert: Bool?
    var defaultLanguage: String?
    var defaultMode: String?
    // createdAt, updatedAt intentionally ignored (not in select)

    func toAppSettings() -> AppSettings {
        var s = AppSettings()
        s.shortcutPrivate  = shortcutPrivate  ?? ""
        s.shortcutBusiness = shortcutBusiness ?? ""
        s.shortcutCalm     = shortcutCalm     ?? ""
        s.autoDetectLanguage = autoDetectLanguage ?? true
        if let lang = manualLanguageOverride.flatMap({ SupportedLanguage(rawValue: $0) }) {
            s.manualLanguageOverride = lang
        }
        s.outputMode       = OutputMode.fromDBValue(outputMode ?? "replace")
        s.microphoneDevice = microphoneDevice
        s.autoInsert       = autoInsert ?? true
        s.defaultLanguage  = defaultLanguage ?? "auto"
        s.defaultMode      = defaultMode ?? "clean"
        return s
    }
}

/// Used for PATCH — only the editable fields, no id/user_id/timestamps.
private struct SettingsUpdateBody: Encodable {
    let shortcutPrivate:        String
    let shortcutBusiness:       String
    let shortcutCalm:           String
    let autoDetectLanguage:     Bool
    let manualLanguageOverride: String?
    let outputMode:             String
    let microphoneDevice:       String?
    let autoInsert:             Bool
    let defaultLanguage:        String
    let defaultMode:            String

    enum CodingKeys: String, CodingKey {
        case shortcutPrivate        = "shortcut_private"
        case shortcutBusiness       = "shortcut_business"
        case shortcutCalm           = "shortcut_calm"
        case autoDetectLanguage     = "auto_detect_language"
        case manualLanguageOverride = "manual_language_override"
        case outputMode             = "output_mode"
        case microphoneDevice       = "microphone_device"
        case autoInsert             = "auto_insert"
        case defaultLanguage        = "default_language"
        case defaultMode            = "default_mode"
    }

    init(from s: AppSettings) {
        self.shortcutPrivate        = s.shortcutPrivate
        self.shortcutBusiness       = s.shortcutBusiness
        self.shortcutCalm           = s.shortcutCalm
        self.autoDetectLanguage     = s.autoDetectLanguage
        self.manualLanguageOverride = s.autoDetectLanguage ? nil : s.manualLanguageOverride.rawValue
        self.outputMode             = s.outputMode.dbValue
        self.microphoneDevice       = s.microphoneDevice
        self.autoInsert             = s.autoInsert
        self.defaultLanguage        = s.defaultLanguage
        self.defaultMode            = s.defaultMode
    }
}

/// Used for POST (insert) — includes user_id but not id (DB generates it).
private struct SettingsInsertBody: Encodable {
    let userId:                 UUID
    let shortcutPrivate:        String
    let shortcutBusiness:       String
    let shortcutCalm:           String
    let autoDetectLanguage:     Bool
    let manualLanguageOverride: String?
    let outputMode:             String
    let microphoneDevice:       String?
    let autoInsert:             Bool
    let defaultLanguage:        String
    let defaultMode:            String

    enum CodingKeys: String, CodingKey {
        case userId                 = "user_id"
        case shortcutPrivate        = "shortcut_private"
        case shortcutBusiness       = "shortcut_business"
        case shortcutCalm           = "shortcut_calm"
        case autoDetectLanguage     = "auto_detect_language"
        case manualLanguageOverride = "manual_language_override"
        case outputMode             = "output_mode"
        case microphoneDevice       = "microphone_device"
        case autoInsert             = "auto_insert"
        case defaultLanguage        = "default_language"
        case defaultMode            = "default_mode"
    }

    init(from s: AppSettings, userID: UUID) {
        self.userId                 = userID
        self.shortcutPrivate        = s.shortcutPrivate
        self.shortcutBusiness       = s.shortcutBusiness
        self.shortcutCalm           = s.shortcutCalm
        self.autoDetectLanguage     = s.autoDetectLanguage
        self.manualLanguageOverride = s.autoDetectLanguage ? nil : s.manualLanguageOverride.rawValue
        self.outputMode             = s.outputMode.dbValue
        self.microphoneDevice       = s.microphoneDevice
        self.autoInsert             = s.autoInsert
        self.defaultLanguage        = s.defaultLanguage
        self.defaultMode            = s.defaultMode
    }
}

// MARK: - Errors

enum SettingsError: LocalizedError {
    case shortcutsNotUnique

    var errorDescription: String? {
        switch self {
        case .shortcutsNotUnique:
            return "Two or more shortcuts are identical. Each shortcut must be unique."
        }
    }
}
