import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

/// Full settings screen, opened from the menu bar.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Title bar area
            HStack {
                Text("Einstellungen")
                    .font(.title2.bold())
                Spacer()
                if viewModel.saveSuccess {
                    Label("Gespeichert", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .transition(.opacity)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    APIKeySection(viewModel: viewModel)
                    Divider()
                    ShortcutsSection(viewModel: viewModel)
                    Divider()
                    LanguageSection(draft: $viewModel.draft)
                    Divider()
                    OutputSection(draft: $viewModel.draft)
                    Divider()
                    MicrophoneSection(draft: $viewModel.draft)
                    Divider()
                    PermissionsSection()
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                if let error = viewModel.validationError ?? viewModel.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(2)
                } else {
                    Text("Voiceflow \(AppInfo.displayString)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Build-Kennung — bitte bei Fehlermeldungen mit angeben.")
                }
                Spacer()
                Button("Zurücksetzen") { viewModel.resetToDefaults() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Speichern") { viewModel.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 600)
    }
}

// MARK: - Section: API Key

private struct APIKeySection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SectionHeader(
            title: "OpenAI API-Key",
            subtitle: "Dein Key bleibt im Schlüsselbund dieses Macs und wird nur für OpenAI-Anfragen verwendet."
        )

        VStack(alignment: .leading, spacing: 8) {
            // Current status row
            HStack(spacing: 8) {
                switch viewModel.apiKeyStatus {
                case .missing:
                    Label("Kein Key hinterlegt", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                        .font(.callout)
                case .stored:
                    Label("Key hinterlegt (\(viewModel.maskedKey))", systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                case .validated:
                    Label("Key geprüft & gespeichert (\(viewModel.maskedKey))", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                case .invalid(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(2)
                }
                Spacer()
                if case .missing = viewModel.apiKeyStatus {} else {
                    Button("Entfernen") { viewModel.removeAPIKey() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            // New key entry
            HStack(spacing: 8) {
                SecureField("Neuen Key einfügen (sk-…)", text: $viewModel.apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button {
                    Task { await viewModel.saveAPIKey() }
                } label: {
                    if viewModel.isValidatingKey {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Prüfen & speichern")
                    }
                }
                .disabled(viewModel.apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isValidatingKey)
            }

            Button("Key auf platform.openai.com erstellen") {
                if let url = URL(string: Config.apiKeysURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

// MARK: - Section: Shortcuts

private struct ShortcutsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SectionHeader(title: "Shortcuts", subtitle: "Gleicher Shortcut nochmals drücken stoppt die Aufnahme.")

        VStack(spacing: 12) {
            ShortcutRow(
                label: "Private",
                description: "Leichte Korrektur — Wortlaut bleibt erhalten",
                name: .dictatePrivate
            )
            ShortcutRow(
                label: "Business",
                description: "Professioneller, geschäftstauglicher Ton",
                name: .dictateBusiness
            )
            ShortcutRow(
                label: "Calm",
                description: "Deeskaliert — sachlich statt emotional",
                name: .dictateCalm
            )
        }

        if let error = viewModel.validationError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct ShortcutRow: View {
    let label: String
    let description: String
    let name: KeyboardShortcuts.Name

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

// MARK: - Section: Language

private struct LanguageSection: View {
    @Binding var draft: AppSettings

    var body: some View {
        SectionHeader(title: "Sprache", subtitle: "Auto-detect erkennt Deutsch, Schweizerdeutsch und Englisch automatisch.")

        Toggle("Sprache automatisch erkennen", isOn: $draft.autoDetectLanguage)

        if !draft.autoDetectLanguage {
            Picker("Sprache", selection: $draft.manualLanguageOverride) {
                ForEach(SupportedLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
    }
}

// MARK: - Section: Output

private struct OutputSection: View {
    @Binding var draft: AppSettings

    var body: some View {
        SectionHeader(
            title: "Ausgabe",
            subtitle: "Direktes Einfügen benötigt die Bedienungshilfen-Berechtigung."
        )

        ForEach(OutputMode.allCases) { mode in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: draft.outputMode == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(draft.outputMode == mode ? Color.accentColor : .secondary)
                    .font(.system(size: 16))
                    .onTapGesture { draft.outputMode = mode }

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.callout)
                    if mode == .insertIntoField {
                        Text("Fällt auf die Zwischenablage zurück, wenn Bedienungshilfen fehlen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Section: Microphone

private struct MicrophoneSection: View {
    @Binding var draft: AppSettings
    @State private var devices: [(id: String, name: String)] = []

    var body: some View {
        SectionHeader(title: "Mikrofon", subtitle: "Standard verwendet das System-Eingabegerät.")

        Group {
            if devices.isEmpty {
                Text("Keine zusätzlichen Eingabegeräte gefunden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Eingabegerät", selection: Binding(
                    get: { draft.microphoneDevice ?? "" },
                    set: { draft.microphoneDevice = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System-Standard").tag("")
                    ForEach(devices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
            }
        }
        .onAppear { devices = RecordingService.availableInputDevices() }
    }
}

// MARK: - Section: Permissions

private struct PermissionsSection: View {
    @State private var hasMic = false
    @State private var hasAX  = false
    /// Polls permission status every 2 s while Settings is open so the UI
    /// reflects grants made in System Settings without reopening the window.
    @State private var pollTimer: Timer? = nil

    var body: some View {
        SectionHeader(
            title: "Berechtigungen",
            subtitle: "Mikrofon ist erforderlich. Bedienungshilfen ermöglichen direktes Einfügen."
        )

        VStack(spacing: 8) {
            PermissionRow(
                icon: "mic.fill",
                label: "Mikrofon",
                note: "Erforderlich — zeichnet deine Sprache auf",
                granted: hasMic,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
            PermissionRow(
                icon: "keyboard",
                label: "Bedienungshilfen",
                note: "Optional — fügt Text direkt ein (sonst Zwischenablage)",
                granted: hasAX,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
        .onAppear {
            refreshStatus()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                refreshStatus()
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func refreshStatus() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAX  = AXIsProcessTrusted()
    }
}

private struct PermissionRow: View {
    let icon: String
    let label: String
    let note: String
    let granted: Bool
    let settingsURL: String

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if granted {
                Label("Erteilt", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Erlauben") {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Reusable Section Header

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.bold())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
