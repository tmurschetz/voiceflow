import Foundation
import SwiftUI

// MARK: - AppState

/// All possible states of the app, used across the menu bar icon, status panel, and animations.
enum AppState: Equatable {
    case idle
    /// No API key configured yet — dictation unavailable until onboarding completes.
    case needsAPIKey
    case recording(mode: ProcessingMode)
    case processing
    /// Server returned a transient error; we'll auto-retry shortly.
    /// `secondsRemaining` ticks down once per second so the UI can show a countdown.
    case retrying(attempt: Int, total: Int, secondsRemaining: Int)
    case success
    /// Dictation succeeded but text was delivered via clipboard (AX insertion unavailable).
    case successWithClipboard
    /// AI polish step was skipped (OpenAI unavailable after retries) — the raw
    /// transcript was inserted as a fallback so no audio is lost.
    case successWithRawFallback
    case error(String)

    var label: String {
        switch self {
        case .idle:                 return "Bereit"
        case .needsAPIKey:          return "API-Key fehlt — Einstellungen öffnen"
        case .recording(let mode):  return "Aufnahme — \(mode.displayName)"
        case .processing:           return "Verarbeite…"
        case .retrying(let a, let t, let s):
            return "Neuer Versuch \(a)/\(t) in \(s)s…"
        case .success:              return "Fertig"
        case .successWithClipboard: return "Aus Zwischenablage eingefügt"
        case .successWithRawFallback: return "Rohtext eingefügt (KI nicht erreichbar)"
        case .error(let msg):       return "Fehler: \(msg)"
        }
    }

    var color: Color {
        switch self {
        case .idle:                 return .secondary
        case .needsAPIKey:          return .orange
        case .recording:            return .red
        case .processing:           return .orange
        case .retrying:             return .orange
        case .success:              return .green
        case .successWithClipboard: return .green
        case .successWithRawFallback: return .yellow
        case .error:                return .red
        }
    }

    var sfSymbol: String {
        switch self {
        case .idle:                 return "waveform"
        case .needsAPIKey:          return "key.fill"
        case .recording:            return "record.circle.fill"
        case .processing:           return "ellipsis.circle"
        case .retrying:             return "arrow.clockwise.circle"
        case .success:              return "checkmark.circle.fill"
        case .successWithClipboard: return "doc.on.clipboard.fill"
        case .successWithRawFallback: return "exclamationmark.bubble.fill"
        case .error:                return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - ViewModel

/// Drives the compact status panel shown in the menu bar popover.
@MainActor
final class StatusPanelViewModel: ObservableObject {
    @Published var state: AppState = .idle
    @Published var settings: AppSettings?
    /// Elapsed recording seconds, updated every second by a timer in AppDelegate.
    @Published var recordingSeconds: Int = 0
    /// Most recent dictation result — shown in the panel with a copy button.
    @Published var lastDictation: String?
    /// Description of a rescued (failed) recording awaiting retry, e.g.
    /// "Business · 14:32" — nil when there is nothing to retry.
    @Published var rescuedDescription: String?
}
