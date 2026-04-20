import Foundation

// MARK: - profiles table

/// Maps to the `profiles` table.
///
/// Schema note: `user_id` is the FK to `auth.users.id` — this is NOT the same as `id`
/// (the table's own PK). Queries must filter on `user_id=eq.<auth.user.id>`.
///
/// Exact columns used:
///   id, user_id, email, first_name, last_name, status, approved_at, approved_by,
///   created_at, updated_at
struct UserProfile: Codable, Identifiable {
    let id: UUID                  // profiles table PK (not the auth user id)
    let userId: UUID              // FK → auth.users.id  [FILTER COLUMN]
    let email: String?
    let firstName: String?
    let lastName: String?
    let status: UserStatus
    let approvedAt: Date?
    let approvedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    /// Display-friendly full name derived from first + last.
    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? (email ?? "User") : parts.joined(separator: " ")
    }
}

// MARK: - UserStatus

/// Mirrors the `status` enum on the `profiles` table.
/// Values: 'pending' | 'active' | 'suspended' | 'rejected'
enum UserStatus: String, Codable {
    case active
    case pending
    case suspended
    case rejected

    /// Whether the user may use the app.
    var isAllowedAccess: Bool { self == .active }

    /// Human-readable block reason shown in the status panel.
    var blockedReason: BlockedReason? {
        switch self {
        case .active:    return nil
        case .pending:   return .pending
        case .suspended: return .suspended
        case .rejected:  return .rejected
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UserStatus(rawValue: raw.lowercased()) ?? .pending
    }
}

// MARK: - user_roles table

/// Maps to a single row in the `user_roles` table.
///
/// Exact columns: id, user_id, role
/// Values: 'pending_user' | 'active_user' | 'admin'
struct UserRole: Codable {
    let id: UUID
    let userId: UUID
    let role: RoleValue

    enum RoleValue: String, Codable {
        case pendingUser = "pending_user"
        case activeUser  = "active_user"
        case admin

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = RoleValue(rawValue: raw) ?? .pendingUser
        }
    }
}

// MARK: - Supabase Auth types

struct AuthUser: Codable {
    let id: UUID
    let email: String?

    // Supabase Auth also returns `role` (DB role, e.g. "authenticated") — ignore it.
    // Our app role comes from user_roles table, not auth.users.
}

/// Session returned by Supabase Auth on sign-in or token refresh.
struct SupabaseSession: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    let user: AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
        case user
    }
}
