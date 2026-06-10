import SwiftUI
import AppKit

/// Compact status panel shown in the menu bar popover.
/// Modern design: hero state area with live animation, keycap-styled shortcuts,
/// last-dictation card with copy button.
struct StatusPanelView: View {
    @ObservedObject var viewModel: StatusPanelViewModel
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Hero state area
            HeroStateView(state: viewModel.state, recordingSeconds: viewModel.recordingSeconds)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)

            // API key missing → prominent CTA
            if case .needsAPIKey = viewModel.state {
                Button(action: onSettings) {
                    Label("OpenAI API-Key eintragen", systemImage: "key.fill")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            Divider().padding(.horizontal, 12)

            // Shortcuts as keycap rows (idle only)
            if case .idle = viewModel.state {
                ShortcutsHintView(settings: viewModel.settings, onSettings: onSettings)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider().padding(.horizontal, 12)
            }

            // Last dictation card
            if let last = viewModel.lastDictation, !last.isEmpty {
                LastDictationView(text: last)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider().padding(.horizontal, 12)
            }

            // Footer
            HStack {
                Button(action: onSettings) {
                    Label("Einstellungen", systemImage: "gearshape")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Text(AppInfo.displayString)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)

                Spacer()

                Button(action: onQuit) {
                    Label("Beenden", systemImage: "power")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 300)
        .background(.regularMaterial)
    }
}

// MARK: - Hero state

private struct HeroStateView: View {
    let state: AppState
    let recordingSeconds: Int

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // Pulsing ring while active
                if isActive {
                    PulsingRing(color: state.color)
                }
                Circle()
                    .fill(state.color.opacity(0.14))
                    .frame(width: 56, height: 56)
                if case .recording = state {
                    AudioBars(color: .red)
                } else {
                    Image(systemName: state.sfSymbol)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(state.color)
                }
            }
            .frame(height: 64)

            VStack(spacing: 2) {
                Text(state.label)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 16)

                if case .recording = state {
                    Text(String(format: "%d:%02d", recordingSeconds / 60, recordingSeconds % 60))
                        .font(.title3.monospacedDigit().weight(.medium))
                        .foregroundStyle(.red)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    private var isActive: Bool {
        if case .recording = state { return true }
        if case .processing = state { return true }
        return false
    }
}

/// Soft expanding ring behind the state icon while recording/processing.
private struct PulsingRing: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.35), lineWidth: 2)
            .frame(width: 56, height: 56)
            .scaleEffect(animate ? 1.35 : 1.0)
            .opacity(animate ? 0 : 1)
            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: animate)
            .onAppear { animate = true }
    }
}

/// Five animated equaliser bars shown while recording.
private struct AudioBars: View {
    let color: Color
    @State private var animate = false
    private let heights: [CGFloat] = [14, 22, 28, 18, 12]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: animate ? heights[i] : 6)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.09),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// MARK: - Shortcuts (keycap style)

private struct ShortcutsHintView: View {
    let settings: AppSettings?
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = settings {
                if s.shortcutsAreAllEmpty {
                    Button(action: onSettings) {
                        Label("Shortcuts festlegen", systemImage: "arrow.right.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                } else {
                    ShortcutLine(icon: "person.fill",    color: .blue,   label: "Private",  combo: s.shortcutPrivate)
                    ShortcutLine(icon: "briefcase.fill", color: .indigo, label: "Business", combo: s.shortcutBusiness)
                    ShortcutLine(icon: "leaf.fill",      color: .teal,   label: "Calm",     combo: s.shortcutCalm)
                }
            } else {
                Text("Shortcuts in den Einstellungen festlegen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShortcutLine: View {
    let icon: String
    let color: Color
    let label: String
    let combo: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(color.gradient))
            Text(label)
                .font(.callout)
            Spacer()
            if combo.isEmpty {
                Text("Nicht gesetzt")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Keycap(text: combo)
            }
        }
    }
}

/// Keyboard-key styled badge for shortcut combos.
private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

// MARK: - Last dictation

private struct LastDictationView: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Letztes Diktat")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Kopiert" : "Kopieren",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                )
        }
    }
}
