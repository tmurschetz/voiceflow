import SwiftUI

/// Compact status panel shown in the menu bar popover.
/// Displays current state and quick-action links.
struct StatusPanelView: View {
    @ObservedObject var viewModel: StatusPanelViewModel
    var onSettings: () -> Void
    var onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header — shows app name + logged-in user + build version
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Voiceflow")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(AppInfo.displayString)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let name = viewModel.profile?.displayName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // State indicator (with recording timer)
            StateRow(state: viewModel.state, recordingSeconds: viewModel.recordingSeconds)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // Shortcuts hint (shown in idle state only)
            if case .idle = viewModel.state {
                ShortcutsHintView(settings: viewModel.settings, onSettings: onSettings)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }

            // Blocked state information
            if case .blocked(let reason) = viewModel.state {
                BlockedView(reason: reason)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }

            // Footer actions
            HStack {
                Button("Settings") { onSettings() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Sign Out") { onSignOut() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 260)
        .background(.background)
    }
}

// MARK: - Sub-views

private struct StateRow: View {
    let state: AppState
    let recordingSeconds: Int
    @State private var animating = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(state.color.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .scaleEffect(animating && isActive ? 1.2 : 1.0)
                    .animation(
                        isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                        value: animating
                    )

                Image(systemName: state.sfSymbol)
                    .font(.system(size: 16))
                    .foregroundStyle(state.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(state.label)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                // Live timer during recording
                if case .recording = state {
                    Text(String(format: "⏺ %d:%02d", recordingSeconds / 60, recordingSeconds % 60))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            Spacer()
        }
        .onAppear { animating = true }
    }

    private var isActive: Bool {
        if case .recording = state { return true }
        if case .processing = state { return true }
        return false
    }
}

private struct ShortcutsHintView: View {
    let settings: AppSettings?
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shortcuts")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            if let s = settings {
                if s.shortcutsAreAllEmpty {
                    // First-run CTA — no shortcuts configured yet
                    Button(action: onSettings) {
                        Label("Open Settings to configure shortcuts", systemImage: "arrow.right.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                } else {
                    ShortcutLine(label: "Private",  combo: s.shortcutPrivate)
                    ShortcutLine(label: "Business", combo: s.shortcutBusiness)
                    ShortcutLine(label: "Calm",     combo: s.shortcutCalm)
                }
            } else {
                Text("Configure shortcuts in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShortcutLine: View {
    let label: String
    let combo: String   // plain string from DB, e.g. "⌘⌥P" or ""

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(combo.isEmpty ? "Not set" : combo)
                .font(.caption.monospaced())
                .foregroundStyle(combo.isEmpty ? .tertiary : .primary)
        }
    }
}

private struct BlockedView: View {
    let reason: BlockedReason

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reason.title)
                .font(.callout.bold())
                .foregroundStyle(reason == .suspended || reason == .rejected ? Color.red : Color.orange)
            Text(reason.userMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
