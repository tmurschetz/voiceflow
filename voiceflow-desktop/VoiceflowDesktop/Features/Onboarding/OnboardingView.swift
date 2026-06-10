import SwiftUI
import AppKit

/// First-run window: the user pastes their OpenAI API key, we validate it
/// against the API and store it in the Keychain. That's the entire setup.
@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var isValidating = false
    @Published var errorMessage: String?

    /// Called after the key has been validated and stored.
    var onComplete: () -> Void = {}

    var canSubmit: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidating
    }

    func submit() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isValidating = true
        errorMessage = nil
        defer { isValidating = false }

        do {
            try await OpenAIClient.shared.validate(apiKey: key)
            KeychainStore.apiKey = key
            onComplete()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Gradient hero — matches the app icon's indigo→blue
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.24, green: 0.18, blue: 0.67),
                             Color(red: 0.29, green: 0.56, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 12) {
                    if let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 84, height: 84)
                            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    }
                    Text("Willkommen bei Voiceflow")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text("Diktieren in jeder App — schnell, in deinem Ton.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.vertical, 36)
            }
            .frame(height: 220)

            // Steps + key entry
            VStack(alignment: .leading, spacing: 18) {
                StepRow(number: "1", title: "OpenAI API-Key erstellen",
                        subtitle: "Einmalig auf platform.openai.com — dauert eine Minute.") {
                    Button("Key erstellen ↗") {
                        if let url = URL(string: Config.apiKeysURL) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }

                StepRow(number: "2", title: "Key hier einfügen",
                        subtitle: "Bleibt im Schlüsselbund dieses Macs — kein Login, keine Cloud dazwischen.") {
                    HStack(spacing: 8) {
                        SecureField("sk-…", text: $viewModel.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .onSubmit { Task { await viewModel.submit() } }
                    }
                }

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 34)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)

            Spacer(minLength: 0)

            Divider()

            // Footer
            HStack {
                Label("~0.3 Rappen pro Diktatminute", systemImage: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isValidating {
                            ProgressView().controlSize(.small)
                            Text("Prüfe…")
                        } else {
                            Text("Loslegen")
                            Image(systemName: "arrow.right")
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canSubmit)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Step row

private struct StepRow<Content: View>: View {
    let number: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.gradient))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
        }
    }
}
