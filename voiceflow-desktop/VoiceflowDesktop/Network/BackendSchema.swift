/// BackendSchema.swift
/// Canonical reference for every Supabase table used by Voiceflow Desktop.
///
/// ─── Verification method ────────────────────────────────────────────────────
/// All columns were confirmed by probing the live PostgREST API with the anon key:
///
///   GET /rest/v1/{table}?select={cols}&limit=0
///     HTTP 200              → every listed column exists
///     HTTP 400 "does not exist" → column absent
///     HTTP 400 "WITHIN GROUP"   → name shadows a PostgreSQL aggregate (column absent)
///
/// Verified: 2026-04-20
/// Backend:  https://uvoxbqqxrsqjdcljhjvk.supabase.co
///
/// ─── Tables used by the desktop app ─────────────────────────────────────────
///
///  Table                  Desktop access
///  ─────────────────────  ───────────────────────────────────────────────────
///  profiles               READ (startup: fetch profile by user_id)
///  user_roles             READ (startup: fetch role — informational only)
///  user_settings          READ + WRITE (load on startup, save on user action)
///  transcription_sessions WRITE (append-only log after each dictation)
///  style_profiles         NONE YET (schema verified; future: read user styles)
///
/// ─── Auth endpoints (GoTrue — not PostgREST) ─────────────────────────────────
///   POST /auth/v1/token?grant_type=password       Sign in with email+password
///   POST /auth/v1/token?grant_type=refresh_token  Refresh an existing session
///   POST /auth/v1/logout                          Revoke session
///   GET  /auth/v1/user                            Validate token / get auth user
///
/// ─── Edge function ────────────────────────────────────────────────────────────
///   POST /functions/v1/process-transcription      AI mode processing
///
// =============================================================================
// No executable code — this file is documentation only.
// =============================================================================

/*

════════════════════════════════════════════════════════════════════════════════
TABLE: profiles
════════════════════════════════════════════════════════════════════════════════
Column        Type          Notes
────────────  ────────────  ────────────────────────────────────────────────────
id            uuid          PK — the table's own PK, NOT the auth user id
user_id       uuid          FK → auth.users.id  ← always filter on this column
email         text          nullable
first_name    text          nullable
last_name     text          nullable
status        user_status   ENUM: 'active' | 'pending' | 'suspended' | 'rejected'
approved_at   timestamptz   nullable
approved_by   uuid          nullable
created_at    timestamptz   DEFAULT NOW()
updated_at    timestamptz   nullable

Swift model:  UserProfile  (Network/Models/UserProfile.swift)
Query filter: user_id=eq.<auth.user.id>   (NOT id=eq.)
Access logic: profile.status must equal 'active'; all other values block the app.
Absent cols:  full_name, role, avatar_url, display_name, company — confirmed absent


════════════════════════════════════════════════════════════════════════════════
TABLE: user_roles
════════════════════════════════════════════════════════════════════════════════
Column        Type    Notes
────────────  ──────  ─────────────────────────────────────────────────────────
id            uuid    PK
user_id       uuid    FK → auth.users.id
role          text    'pending_user' | 'active_user' | 'admin'

Swift model:  UserRole  (Network/Models/UserProfile.swift)
Total cols:   3 — no created_at, updated_at, or any timestamp column.
Usage:        Informational only; access control uses profiles.status, not role.
Absent cols:  created_at, updated_at, assigned_at, expires_at — confirmed absent


════════════════════════════════════════════════════════════════════════════════
TABLE: user_settings
════════════════════════════════════════════════════════════════════════════════
Column                    Type    Notes
────────────────────────  ──────  ───────────────────────────────────────────────
id                        uuid    PK (DB-generated)
user_id                   uuid    FK → auth.users.id  UNIQUE — one row per user
shortcut_private          text    default ''  — human-readable e.g. "⌘⌥P"
shortcut_business         text    default ''
shortcut_calm             text    default ''
auto_detect_language      bool    default true
manual_language_override  text    nullable — 'de' | 'en' | 'gsw'
output_mode               text    default 'replace' — 'replace' | 'clipboard'
microphone_device         text    nullable — AVCaptureDevice.uniqueID
auto_insert               bool    default true
default_language          text    default 'auto'
default_mode              text    default 'clean'
created_at                timestamptz  DEFAULT NOW()
updated_at                timestamptz  nullable

Swift models: SettingsRow (read), SettingsUpdateBody (PATCH), SettingsInsertBody (POST)
              All in Core/Settings/SettingsService.swift
Save strategy: PATCH when row exists; POST for first-time users.
              Identified by settingsRowExists flag set during loadSettings().
Note on output_mode: column is text, not an enum. The app stores 'replace' or
              'clipboard'. fromDBValue() maps legacy aliases ('insert', 'replace',
              'insert_into_field') → .insertIntoField for forward compatibility.
Absent cols:  system_prompt, preferred_language, keyboard_shortcut_* — confirmed absent


════════════════════════════════════════════════════════════════════════════════
TABLE: transcription_sessions
════════════════════════════════════════════════════════════════════════════════
Column                  Type          Notes
──────────────────────  ────────────  ─────────────────────────────────────────
id                      uuid          PK (DB-generated)
user_id                 uuid          FK → auth.users.id
mode                    text          'private' | 'business' | 'calm'
detected_language       text          nullable — locale code e.g. 'de-DE'
output_mode             text          matches user_settings.output_mode values
started_at              timestamptz   nullable — when recording began
finished_at             timestamptz   nullable — when pipeline completed
audio_seconds           int           nullable — recording duration
success                 bool
error_message           text          nullable
transcription_provider  text          nullable — e.g. 'apple-sfspeech'
processing_provider     text          nullable — e.g. 'openai-gpt4'
raw_transcript          text          nullable — verbatim SFSpeechRecognizer output
final_text              text          nullable — post-processing result
duration_seconds        int           wall-clock pipeline duration
word_count              int
character_count         int
status                  text          'completed' | 'failed'
created_at              timestamptz   DEFAULT NOW()

Swift model:  TranscriptionSessionInsert  (Network/Models/TranscriptionSession.swift)
Usage:        Append-only. Inserted after every dictation attempt (success or failure).
              Desktop app never reads this table.
Note:         no updated_at column — confirmed absent.
Absent cols:  updated_at, model, provider, app_version, locale, title — confirmed absent


════════════════════════════════════════════════════════════════════════════════
TABLE: style_profiles
════════════════════════════════════════════════════════════════════════════════
Column       Type          Notes
───────────  ────────────  ─────────────────────────────────────────────────────
id           uuid          PK
user_id      uuid          FK → auth.users.id (nullable rows = global profiles)
name         text
description  text          nullable
is_default   bool
active       bool
created_at   timestamptz
updated_at   timestamptz

Desktop app status: NOT YET READ.
                    Endpoint defined (Endpoints.styleProfiles) for future use.
System prompts:     Hardcoded in Swift — ProcessingMode.systemPrompt.
                    NOT stored in this table.
Absent cols:        mode, system_prompt, is_global, profile_name, language, tone,
                    type, content, prompt — all confirmed absent.

Note on 'mode' column:  A column named 'mode' does NOT exist in style_profiles.
                    The PostgREST "WITHIN GROUP is required for ordered-set aggregate
                    mode" error (observed during probing) occurs when no column named
                    'mode' exists and PostgreSQL falls back to interpreting 'mode' as
                    its built-in ordered-set aggregate function.
                    Contrast: transcription_sessions.mode returns HTTP 200 because
                    a real column with that name exists there.

*/
