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
            // Hero
            VStack(spacing: 10) {
                if let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 76, height: 76)
                }
                Text("Willkommen bei Voiceflow")
                    .font(.title2.bold())
                Text("Diktieren in jeder App — mit deinem eigenen OpenAI-Konto.\nKein Login, keine Cloud dazwischen: dein Key bleibt im Schlüsselbund dieses Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)
            .padding(.bottom, 22)

            Divider()

            // Key entry
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenAI API-Key")
                    .font(.callout.bold())

                SecureField("sk-…", text: $viewModel.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { Task { await viewModel.submit() } }

                HStack(spacing: 4) {
                    Text("Noch keinen Key?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Auf platform.openai.com erstellen") {
                        if let url = URL(string: Config.apiKeysURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            // Footer
            HStack {
                Text("Kosten: ~0.3 Rappen pro Diktatminute")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    if viewModel.isValidating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Prüfe…")
                        }
                    } else {
                        Text("Key prüfen & loslegen")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmit)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
    }
}
