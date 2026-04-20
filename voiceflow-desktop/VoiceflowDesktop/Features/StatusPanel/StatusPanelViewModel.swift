import Foundation
import SwiftUI

// MARK: - BlockedReason
// Defined here so it's available to AppState, AuthService, and the views.

/// Reason why a user's account is blocked from using the app.
/// Mirrors the `profiles.status` enum values that prevent access.
enum BlockedReason: Equatable {
    case pending    // status = 'pending'   — waiting for admin approval
    case suspended  // status = 'suspended' — manually disabled by admin
    case rejected   // status = 'rejected'  — registration rejected

    var userMessage: String {
        switch self {
        case .pending:
            return "Your account is awaiting admin approval. You'll be notified when access is granted."
        case .suspended:
            return "Your account has been suspended. Please contact your administrator."
        case .rejected:
            return "Your account registration was rejected. Please contact your administrator."
        }
    }

    var title: String {
        switch self {
        case .pending:   return "Account Pending"
        case .suspended: return "Account Suspended"
        case .rejected:  return "Account Rejected"
        }
    }
}

// MARK: - AppState

/// All possible states of the app, used across the menu bar icon, status panel, and animations.
enum AppState: Equatable {
    case idle
    case recording(mode: ProcessingMode)
    case processing
    case success
    case error(String)
    case blocked(BlockedReason)

    var label: String {
        switch self {
        case .idle:                 return "Ready"
        case .recording(let mode): return "Recording — \(mode.displayName)"
        case .processing:          return "Processing…"
        case .success:             return "Done"
        case .error(let msg):      return "Error: \(msg)"
        case .blocked(let reason): return reason.title
        }
    }

    var color: Color {
        switch self {
        case .idle:       return .secondary
        case .recording:  return .red
        case .processing: return .orange
        case .success:    return .green
        case .error:      return .red
        case .blocked:    return .orange
        }
    }

    var sfSymbol: String {
        switch self {
        case .idle:       return "waveform"
        case .recording:  return "record.circle.fill"
        case .processing: return "ellipsis.circle"
        case .success:    return "checkmark.circle.fill"
        case .error:      return "exclamationmark.triangle.fill"
        case .blocked:    return "lock.circle.fill"
        }
    }

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):                    return true
        case (.recording(let a), .recording(let b)): return a == b
        case (.processing, .processing):        return true
        case (.success, .success):              return true
        case (.error(let a), .error(let b)):    return a == b
        case (.blocked(let a), .blocked(let b)): return a == b
        default:                                return false
        }
    }
}

// MARK: - ViewModel

/// Drives the compact status panel shown in the menu bar popover.
@MainActor
final class StatusPanelViewModel: ObservableObject {
    @Published var state: AppState = .idle
    @Published var profile: UserProfile?
    @Published var settings: AppSettings?
}
