import Foundation

// MARK: - profiles table

/// Maps to the `profiles` table.
///
/// Verified schema (2026-04-20) — all columns present, no extra columns:
///   id           uuid  PK  (the table's own primary key — NOT the auth user id)
///   user_id      uuid  FK → auth.users.id   ← FILTER ON THIS, not on id
///   email        text  nullable
///   first_name   text  nullable
///   last_name    text  nullable
///   status       enum  user_status: 'active'|'pending'|'suspended'|'rejected'
///   approved_at  timestamptz  nullable
///   approved_by  uuid  nullable
///   created_at   timestamptz
///   updated_at   timestamptz  nullable
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
/// Verified schema (2026-04-20):
///   id       uuid  PK
///   user_id  uuid  FK → auth.users.id
///   role     text  'pending_user' | 'active_user' | 'admin'
///
/// The table has exactly 3 columns.
/// created_at, updated_at and any timestamp columns do NOT exist on this table.
///
/// Usage in the desktop app: informational only — access control is enforced via
/// profiles.status ('active' check), not via the role value.
struct UserRole: Codable {
    let id: UUID
    let userId: UUID   // decoded via JSONDecoder.supabase convertFromSnakeCase
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
///
/// No explicit CodingKeys — JSONDecoder.supabase uses convertFromSnakeCase
/// which maps JSON "access_token" → Swift "accessToken" automatically.
/// Mixing explicit snake_case CodingKeys with convertFromSnakeCase breaks
/// decoding because the strategy converts the JSON key to camelCase before
/// matching against the CodingKey's rawValue, which is still snake_case.
struct SupabaseSession: Codable {
    let accessToken: String     // JSON: "access_token"
    let refreshToken: String    // JSON: "refresh_token"
    let expiresIn: Int?         // JSON: "expires_in" — optional: absent in some Supabase versions
    let tokenType: String?      // JSON: "token_type" — optional for robustness
    let user: AuthUser          // JSON: "user"
}
