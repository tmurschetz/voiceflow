import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

/// Full settings screen — modern macOS System-Settings style:
/// grouped form, colored icon badges, instant auto-save (no Save button).
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                APIKeySection(viewModel: viewModel)
                GeneralSection(viewModel: viewModel)
                ShortcutsSection(viewModel: viewModel)
                LanguageSection(viewModel: viewModel)
                OutputSection(viewModel: viewModel)
                PermissionsSection()
            }
            .formStyle(.grouped)

            Divider()

            // Slim footer: version + auto-save indicator
            HStack(spacing: 8) {
                Text("Voiceflow \(AppInfo.displayString)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Build-Kennung — bitte bei Fehlermeldungen mit angeben.")
                Spacer()
                if let error = viewModel.validationError ?? viewModel.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if viewModel.savedFlash {
                    Label("Gespeichert", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Text("Änderungen werden automatisch gespeichert")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.savedFlash)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 640)
        .onChange(of: viewModel.draft) { _ in viewModel.autoSave() }
    }
}

// MARK: - Icon badge (System-Settings-style colored squircle)

private struct IconBadge: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.gradient)
            )
    }
}

// MARK: - Section: API Key

private struct APIKeySection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section {
            // Status row
            HStack(spacing: 10) {
                IconBadge(systemName: "key.fill", color: statusColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenAI API-Key")
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor == .green ? .green : .secondary)
                }
                Spacer()
                if case .missing = viewModel.apiKeyStatus {} else {
                    Button("Entfernen", role: .destructive) { viewModel.removeAPIKey() }
                        .controlSize(.small)
                }
            }

            // Entry row — empty label + prompt so the grouped Form doesn't
            // render a duplicate leading label next to the field.
            HStack(spacing: 8) {
                SecureField(text: $viewModel.apiKeyInput, prompt: Text("Neuen Key einfügen (sk-…)")) {
                    EmptyView()
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
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

            if case .invalid(let msg) = viewModel.apiKeyStatus {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            HStack(spacing: 4) {
                Text("Der Key bleibt im Schlüsselbund dieses Macs.")
                Button("Key erstellen ↗") {
                    if let url = URL(string: Config.apiKeysURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    private var statusText: String {
        switch viewModel.apiKeyStatus {
        case .missing:   return "Kein Key hinterlegt"
        case .stored:    return "Hinterlegt (\(viewModel.maskedKey))"
        case .validated: return "Geprüft & gespeichert (\(viewModel.maskedKey))"
        case .invalid:   return "Ungültig"
        }
    }

    private var statusColor: Color {
        switch viewModel.apiKeyStatus {
        case .missing:   return .orange
        case .stored:    return .blue
        case .validated: return .green
        case .invalid:   return .red
        }
    }
}

// MARK: - Section: General

private struct GeneralSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Allgemein") {
            HStack(spacing: 10) {
                IconBadge(systemName: "power", color: .gray)
                Toggle("Bei Anmeldung starten", isOn: $viewModel.launchAtLogin)
            }
        }
    }
}

// MARK: - Section: Shortcuts

private struct ShortcutsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section {
            ShortcutRow(
                icon: "person.fill", color: .blue,
                label: "Private",
                description: "Leichte Korrektur — dein Wortlaut bleibt",
                name: .dictatePrivate,
                onChange: { viewModel.autoSave() }
            )
            ShortcutRow(
                icon: "briefcase.fill", color: .indigo,
                label: "Business",
                description: "Professioneller, geschäftstauglicher Ton",
                name: .dictateBusiness,
                onChange: { viewModel.autoSave() }
            )
            ShortcutRow(
                icon: "leaf.fill", color: .teal,
                label: "Calm",
                description: "Deeskaliert — sachlich statt emotional",
                name: .dictateCalm,
                onChange: { viewModel.autoSave() }
            )
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Gleicher Shortcut nochmals drücken stoppt die Aufnahme.")
                .font(.caption)
        }
    }
}

private struct ShortcutRow: View {
    let icon: String
    let color: Color
    let label: String
    let description: String
    let name: KeyboardShortcuts.Name
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(systemName: icon, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            KeyboardShortcuts.Recorder(for: name) { _ in onChange() }
        }
    }
}

// MARK: - Section: Language

private struct LanguageSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section {
            HStack(spacing: 10) {
                IconBadge(systemName: "globe", color: .purple)
                Toggle("Sprache automatisch erkennen", isOn: $viewModel.draft.autoDetectLanguage)
            }

            if !viewModel.draft.autoDetectLanguage {
                Picker("Sprache", selection: $viewModel.draft.manualLanguageOverride) {
                    ForEach(SupportedLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text("Sprache")
        } footer: {
            Text("Auto-detect erkennt Deutsch, Schweizerdeutsch und Englisch automatisch.")
                .font(.caption)
        }
    }
}

// MARK: - Section: Output + Microphone

private struct OutputSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var devices: [(id: String, name: String)] = []

    var body: some View {
        Section {
            HStack(spacing: 10) {
                IconBadge(systemName: "text.cursor", color: .orange)
                Picker("Ausgabe", selection: $viewModel.draft.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 10) {
                IconBadge(systemName: "mic.fill", color: .pink)
                Picker("Mikrofon", selection: Binding(
                    get: { viewModel.draft.microphoneDevice ?? "" },
                    set: { viewModel.draft.microphoneDevice = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System-Standard").tag("")
                    ForEach(devices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text("Ausgabe & Eingabe")
        } footer: {
            Text("Direktes Einfügen fällt auf die Zwischenablage zurück, wenn die Bedienungshilfen-Berechtigung fehlt.")
                .font(.caption)
        }
        .onAppear { devices = RecordingService.availableInputDevices() }
    }
}

// MARK: - Section: Permissions

private struct PermissionsSection: View {
    @State private var hasMic = false
    @State private var hasAX  = false
    /// Polls every 2 s so grants made in System Settings appear without reopening.
    @State private var pollTimer: Timer? = nil

    var body: some View {
        Section("Berechtigungen") {
            PermissionRow(
                icon: "mic.fill", color: .red,
                label: "Mikrofon",
                note: "Erforderlich — zeichnet deine Sprache auf",
                granted: hasMic,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
            PermissionRow(
                icon: "accessibility", color: .blue,
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
    let color: Color
    let label: String
    let note: String
    let granted: Bool
    let settingsURL: String

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(systemName: icon, color: granted ? .green : color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Erteilt", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Erlauben") {
                    if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
        }
    }
}
