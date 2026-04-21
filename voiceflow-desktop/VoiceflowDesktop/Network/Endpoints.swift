import Foundation

/// All Supabase API endpoint paths used by Voiceflow Desktop.
/// Base URL: https://uvoxbqqxrsqjdcljhjvk.supabase.co
///
/// ## Schema verification summary (verified 2026-04-20 via PostgREST column probing)
///
/// Method: `GET /rest/v1/{table}?select={cols}&limit=0`
///   HTTP 200 → all specified columns confirmed present
///   HTTP 400 "does not exist" → column absent
///
/// Tables used by the desktop app
/// ────────────────────────────────────────────────────────────────
/// READ   profiles, user_roles, user_settings
/// WRITE  user_settings (PATCH / POST), transcription_sessions (POST)
/// FUTURE style_profiles (schema verified, no reads yet implemented)
/// ────────────────────────────────────────────────────────────────
enum Endpoints {

    // MARK: - Supabase Auth v2  (GoTrue — /auth/v1/)

    /// POST ?grant_type=password   — body: { email, password }
    /// POST ?grant_type=refresh_token — body: { refresh_token }   ← snake_case required by GoTrue
    static let signIn       = "/auth/v1/token"
    static let refreshToken = "/auth/v1/token"

    /// POST — revoke current session
    static let signOut      = "/auth/v1/logout"

    /// GET — validate token, get current auth user
    static let authUser     = "/auth/v1/user"

    // MARK: - PostgREST (public schema tables)

    // MARK: profiles
    //
    // Confirmed columns (verified 200):
    //   id           uuid  PK  (DB-generated)
    //   user_id      uuid  FK → auth.users.id   ← ALWAYS filter on this, NOT on id
    //   email        text  nullable
    //   first_name   text  nullable
    //   last_name    text  nullable
    //   status       enum  user_status: 'active' | 'pending' | 'suspended' | 'rejected'
    //   approved_at  timestamptz  nullable
    //   approved_by  uuid  nullable
    //   created_at   timestamptz  DEFAULT NOW()
    //   updated_at   timestamptz  nullable
    //
    // Swift mapping: UserProfile struct (Network/Models/UserProfile.swift)
    // Access control: profile.status must be 'active' to allow app usage
    static let profiles = "/rest/v1/profiles"

    // MARK: user_roles
    //
    // Confirmed columns (verified 200):
    //   id       uuid  PK
    //   user_id  uuid  FK → auth.users.id
    //   role     text  (values observed: 'pending_user' | 'active_user' | 'admin')
    //
    // Note: table has exactly 3 columns — no created_at, updated_at, or any timestamp.
    //
    // Swift mapping: UserRole struct (Network/Models/UserProfile.swift)
    // Usage: informational only; access control is based on profiles.status, not role
    static let userRoles = "/rest/v1/user_roles"

    // MARK: user_settings
    //
    // Confirmed columns (verified 200):
    //   id                       uuid   PK  (DB-generated)
    //   user_id                  uuid   FK → auth.users.id  (UNIQUE — one row per user)
    //   shortcut_private         text   default ''
    //   shortcut_business        text   default ''
    //   shortcut_calm            text   default ''
    //   auto_detect_language     bool   default true
    //   manual_language_override text   nullable  (values: 'de' | 'en' | 'gsw')
    //   output_mode              text   default 'replace'  (values: 'replace' | 'clipboard')
    //   microphone_device        text   nullable  (AVCaptureDevice.uniqueID)
    //   auto_insert              bool   default true
    //   default_language         text   default 'auto'
    //   default_mode             text   default 'clean'
    //   created_at               timestamptz  DEFAULT NOW()
    //   updated_at               timestamptz  nullable
    //
    // Swift mapping: SettingsRow / SettingsUpdateBody / SettingsInsertBody (Core/Settings/SettingsService.swift)
    // Save strategy: PATCH (row exists) or POST (first-time user), filtered by user_id
    static let userSettings = "/rest/v1/user_settings"

    // MARK: transcription_sessions
    //
    // Confirmed columns (verified 200):
    //   id                       uuid  PK  (DB-generated)
    //   user_id                  uuid  FK → auth.users.id
    //   mode                     text  'private' | 'business' | 'calm'
    //   detected_language        text  nullable  locale code, e.g. 'de-DE'
    //   output_mode              text  matches user_settings.output_mode values
    //   started_at               timestamptz  nullable
    //   finished_at              timestamptz  nullable
    //   audio_seconds            int   nullable
    //   success                  bool
    //   error_message            text  nullable
    //   transcription_provider   text  nullable  e.g. 'apple-sfspeech'
    //   processing_provider      text  nullable  e.g. 'openai-gpt4'
    //   raw_transcript           text  nullable
    //   final_text               text  nullable
    //   duration_seconds         int   wall-clock pipeline duration
    //   word_count               int
    //   character_count          int
    //   status                   text  'completed' | 'failed'
    //   created_at               timestamptz  DEFAULT NOW()
    //
    // Note: no updated_at column on this table.
    //
    // Swift mapping: TranscriptionSessionInsert (Network/Models/TranscriptionSession.swift)
    // Usage: append-only logging via POST; never read back by the desktop app
    static let transcriptionSessions = "/rest/v1/transcription_sessions"

    // MARK: style_profiles
    //
    // Confirmed columns (verified 200):
    //   id           uuid  PK
    //   user_id      uuid  FK → auth.users.id  (nullable? — may include global rows)
    //   name         text
    //   description  text  nullable
    //   is_default   bool
    //   active       bool
    //   created_at   timestamptz
    //   updated_at   timestamptz
    //
    // Columns confirmed ABSENT: mode, system_prompt, is_global, profile_name, language, tone
    //
    // Note: the column named 'mode' does NOT exist. The PostgREST WITHIN GROUP error
    // observed during probing indicates PostgreSQL interprets 'mode' as the ordered-set
    // aggregate function when no matching column is found — confirming the column is absent.
    //
    // Desktop app status: endpoint available, schema verified, no active reads yet.
    // The system prompts for Private / Business / Calm modes are defined in Swift
    // (ProcessingMode.systemPrompt) — not fetched from this table.
    static let styleProfiles = "/rest/v1/style_profiles"

    // MARK: - Edge Functions

    /// POST — AI processing of raw transcript.
    ///
    /// Request body (JSON):
    ///   {
    ///     "text":          String,   // raw transcript from SFSpeechRecognizer
    ///     "mode":          String,   // "private" | "business" | "calm"
    ///     "language":      String,   // locale used, e.g. "de-DE"
    ///     "system_prompt": String    // full prompt (defined in ProcessingMode.systemPrompt)
    ///   }
    ///
    /// Success response (200):
    ///   { "result": String }
    ///
    /// Error response:
    ///   { "error": String }
    ///
    /// 404 / 503 → ModeProcessor falls back to returning raw transcript unchanged.
    static let processTranscription = "/functions/v1/process-transcription"
}
