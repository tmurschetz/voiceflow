import Foundation
import Security

/// Manages authentication against the Supabase backend.
///
/// Auth flow:
///   1. Sign in → POST /auth/v1/token?grant_type=password → SupabaseSession (stored in Keychain)
///   2. Startup → load from Keychain → POST /auth/v1/token?grant_type=refresh_token
///   3. Fetch profile → GET /rest/v1/profiles?user_id=eq.<auth.user.id>
///   4. Check profile.status → must be 'active' to allow usage
///   5. Fetch role → GET /rest/v1/user_roles?user_id=eq.<auth.user.id>  (informational)
///
/// Schema notes:
///   - profiles: filtered by user_id (FK to auth.users.id), NOT by profiles.id
///   - user_roles: separate table, role column: 'pending_user' | 'active_user' | 'admin'
@MainActor
final class AuthService: ObservableObject {

    @Published private(set) var currentSession: SupabaseSession?
    @Published private(set) var currentProfile: UserProfile?
    @Published private(set) var currentRole: UserRole.RoleValue?

    private let api = APIClient.shared
    private let keychainService = "com.voiceflow.desktop"
    private let keychainAccount = "supabase_session"

    // MARK: - Startup Session Validation

    /// Called on every app launch.
    /// Attempts to refresh a stored session. Returns nil if no stored session or refresh fails.
    func validateStoredSession() async throws -> SupabaseSession? {
        guard let stored = loadSessionFromKeychain() else { return nil }

        do {
            let refreshed = try await refreshSession(refreshToken: stored.refreshToken)
            currentSession = refreshed
            saveSessionToKeychain(refreshed)
            return refreshed
        } catch {
            // Refresh failed — token expired or revoked. Clear and require re-login.
            clearKeychain()
            currentSession = nil
            return nil
        }
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async throws -> SupabaseSession {
        struct Body: Encodable { let email: String; let password: String }
        let req = try api.request(
            path: Endpoints.signIn,
            method: "POST",
            body: Body(email: email, password: password),
            queryItems: [URLQueryItem(name: "grant_type", value: "password")]
        )
        let session = try await api.perform(req, as: SupabaseSession.self)
        currentSession = session
        saveSessionToKeychain(session)
        return session
    }

    // MARK: - Token Refresh

    private func refreshSession(refreshToken: String) async throws -> SupabaseSession {
        // GoTrue expects snake_case keys in the JSON body.
        // Without explicit CodingKeys the Swift encoder would emit "refreshToken" (camelCase),
        // which GoTrue does not recognise — causing every startup session restore to fail.
        struct Body: Encodable {
            let refreshToken: String
            enum CodingKeys: String, CodingKey {
                case refreshToken = "refresh_token"
            }
        }
        let req = try api.request(
            path: Endpoints.refreshToken,
            method: "POST",
            body: Body(refreshToken: refreshToken),
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")]
        )
        return try await api.perform(req, as: SupabaseSession.self)
    }

    // MARK: - Profile

    /// Fetches the user's profile row using the auth user ID.
    ///
    /// IMPORTANT: filter is on `user_id` (FK to auth.users), NOT on `id` (profiles PK).
    func fetchUserProfile(session: SupabaseSession) async throws -> UserProfile {
        let req = try api.request(
            path: Endpoints.profiles,
            method: "GET",
            authToken: session.accessToken,
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(session.user.id.uuidString)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        let profiles = try await api.perform(req, as: [UserProfile].self)
        guard let profile = profiles.first else {
            throw AuthError.profileNotFound
        }
        currentProfile = profile
        return profile
    }

    // MARK: - Role

    /// Fetches the user's role from the `user_roles` table.
    /// Role is informational in the desktop app — access control is done via profile.status.
    func fetchUserRole(session: SupabaseSession) async throws -> UserRole.RoleValue? {
        let req = try api.request(
            path: Endpoints.userRoles,
            method: "GET",
            authToken: session.accessToken,
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(session.user.id.uuidString)"),
                URLQueryItem(name: "select", value: "id,user_id,role"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
        let roles = try await api.perform(req, as: [UserRole].self)
        let roleValue = roles.first?.role
        currentRole = roleValue
        return roleValue
    }

    // MARK: - Sign Out

    func signOut() async {
        if let session = currentSession {
            let req = try? api.request(
                path: Endpoints.signOut,
                method: "POST",
                authToken: session.accessToken
            )
            if let req { try? await api.perform(req) }
        }
        currentSession = nil
        currentProfile = nil
        currentRole = nil
        clearKeychain()
    }

    // MARK: - Keychain (Secure Token Storage)

    private func saveSessionToKeychain(_ session: SupabaseSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadSessionFromKeychain() -> SupabaseSession? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  keychainService,
            kSecAttrAccount as String:  keychainAccount,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let session = try? JSONDecoder().decode(SupabaseSession.self, from: data)
        else { return nil }
        return session
    }

    private func clearKeychain() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case profileNotFound
    case notAuthenticated
    case accountBlocked(reason: BlockedReason)

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return "User profile not found. Contact your administrator."
        case .notAuthenticated:
            return "You are not signed in."
        case .accountBlocked(let reason):
            return reason.userMessage
        }
    }
}
