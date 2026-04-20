import Foundation

/// All Supabase API endpoint paths.
/// Base URL: https://uvoxbqqxrsqjdcljhjvk.supabase.co
enum Endpoints {

    // MARK: - Supabase Auth v2

    /// POST — sign in with email+password: ?grant_type=password
    /// POST — refresh token: ?grant_type=refresh_token
    static let signIn       = "/auth/v1/token"
    static let refreshToken = "/auth/v1/token"

    /// POST — revoke current session
    static let signOut      = "/auth/v1/logout"

    /// GET — get current auth user (for token validation)
    static let authUser     = "/auth/v1/user"

    // MARK: - PostgREST (public schema tables)

    /// Table: profiles
    /// Filter: ?user_id=eq.<auth.user.id>  [NOT id — user_id is the FK to auth.users]
    static let profiles     = "/rest/v1/profiles"

    /// Table: user_roles
    /// Filter: ?user_id=eq.<auth.user.id>
    static let userRoles    = "/rest/v1/user_roles"

    /// Table: user_settings
    /// Filter: ?user_id=eq.<auth.user.id>
    static let userSettings = "/rest/v1/user_settings"

    /// Table: transcription_sessions
    /// POST to insert new session log records
    static let transcriptionSessions = "/rest/v1/transcription_sessions"

    /// Table: style_profiles (global + user-specific, read-only for desktop)
    static let styleProfiles = "/rest/v1/style_profiles"

    // MARK: - Edge Functions (AI processing — to be wired)
    // Assumption: edge function named "process-transcription" accepts
    // { text, mode, language } and returns { result, detected_language }
    static let processTranscription = "/functions/v1/process-transcription"
}
