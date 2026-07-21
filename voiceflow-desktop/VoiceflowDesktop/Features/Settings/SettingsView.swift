import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

/// Full settings screen — modern macOS System-Settings style:
/// grouped form, colored icon badges, instant auto-save (no Save button).
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// Window height — overridable so the snapshot harness can render the
    /// whole form unscrolled for design review.
    var height: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            Form {
                APIKeySection(viewModel: viewModel)
                GeneralSection(viewModel: viewModel)
                ModesSection(viewModel: viewModel)
                VocabularySection(viewModel: viewModel)
                LanguageSection(viewModel: viewModel)
                OutputSection(viewModel: viewModel)
                PermissionsSection()
                DataSection(viewModel: viewModel)
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
        .frame(width: 580, height: height)
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
                Text("Der Key bleibt im Schlüsselbund dieses Macs und geht ausschliesslich an api.openai.com.")
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
    @AppStorage(UpdateService.autoUpdateKey) private var autoUpdate = false

    var body: some View {
        Section("Allgemein") {
            HStack(spacing: 10) {
                IconBadge(systemName: "power", color: .gray)
                Toggle("Bei Anmeldung starten", isOn: $viewModel.launchAtLogin)
            }
            HStack(spacing: 10) {
                IconBadge(systemName: "arrow.triangle.2.circlepath", color: .green)
                Toggle("Updates automatisch installieren", isOn: $autoUpdate)
            }
        }
    }
}

// MARK: - Section: Modes (shortcut + custom instruction per mode)

private struct ModesSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section {
            ModeRow(
                mode: .private, color: .blue,
                name: .dictatePrivate,
                instruction: $viewModel.draft.instructionPrivate,
                placeholder: "z. B. «Behalte Anglizismen bei, schreibe Zahlen immer als Ziffern»",
                onShortcutChange: { viewModel.autoSave() }
            )
            ModeRow(
                mode: .business, color: .indigo,
                name: .dictateBusiness,
                instruction: $viewModel.draft.instructionBusiness,
                placeholder: "z. B. «Unterschreibe nie, verwende unser Wording: Kundinnen und Kunden»",
                onShortcutChange: { viewModel.autoSave() }
            )
            ModeRow(
                mode: .random, color: .pink,
                name: .dictateRandom,
                instruction: $viewModel.draft.instructionRandom,
                placeholder: "z. B. «Übersetze alles auf Englisch» oder «Formatiere als Bullet-Liste»",
                onShortcutChange: { viewModel.autoSave() }
            )
        } header: {
            Text("Modi")
        } footer: {
            Text("Gleicher Shortcut nochmals drücken stoppt die Aufnahme. Die Instruktion personalisiert den Output des jeweiligen Modus — sie wird der KI bei jedem Diktat mitgegeben.")
                .font(.caption)
        }
    }
}

private struct ModeRow: View {
    let mode: ProcessingMode
    let color: Color
    let name: KeyboardShortcuts.Name
    @Binding var instruction: String
    let placeholder: String
    let onShortcutChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IconBadge(systemName: mode.sfSymbol, color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.displayName)
                    Text(mode.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KeyboardShortcuts.Recorder(for: name) { _ in onShortcutChange() }
            }

            TextField(text: $instruction, prompt: Text(placeholder), axis: .vertical) {
                EmptyView()
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .font(.caption)
            .lineLimit(2...4)
            .padding(.leading, 34)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Section: Dictionary (custom vocabulary)

private struct VocabularySection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    IconBadge(systemName: "character.book.closed.fill", color: .teal)
                    Text("Eigene Begriffe")
                    Spacer()
                }
                TextField(
                    text: $viewModel.draft.customVocabulary,
                    prompt: Text("z. B. Murschetz, Voiceflow, Zürich, Projektnamen, Fachbegriffe …"),
                    axis: .vertical
                ) {
                    EmptyView()
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.caption)
                .lineLimit(2...4)
                .padding(.leading, 34)
                Text("Namen, Marken und Fachbegriffe, die korrekt geschrieben werden sollen — sie werden der Transkription bei jedem Diktat als Hinweis mitgegeben.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Wörterbuch")
        } footer: {
            Text("Voiceflow nutzt automatisch das genaueste Transkriptionsmodell — du musst nichts auswählen.")
                .font(.caption)
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
            Text("Auto-detect erkennt die gesprochene Sprache automatisch. Manuell festlegen lohnt sich nur, wenn die Erkennung danebenliegt.")
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

// MARK: - Section: Data & Uninstall

private struct DataSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var historyCleared = false

    var body: some View {
        Section {
            HStack(spacing: 10) {
                IconBadge(systemName: "clock.arrow.circlepath", color: .teal)
                Toggle("Diktat-Verlauf lokal speichern", isOn: $viewModel.draft.historyEnabled)
            }

            HStack(spacing: 10) {
                IconBadge(systemName: "trash", color: .gray)
                Text("Verlauf löschen")
                Spacer()
                if historyCleared {
                    Label("Gelöscht", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Löschen") {
                        HistoryStore.shared.clear()
                        historyCleared = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { historyCleared = false }
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                IconBadge(systemName: "xmark.bin.fill", color: .red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("App vollständig entfernen")
                    Text("Key, Einstellungen, Verlauf, Berechtigungen und die App selbst — ohne Spuren.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Entfernen…", role: .destructive) {
                    Uninstaller.requestUninstall()
                }
                .controlSize(.small)
            }
        } header: {
            Text("Daten & Deinstallation")
        } footer: {
            Text("Der Verlauf liegt ausschliesslich lokal unter ~/Library/Application Support/Voiceflow/ und verlässt deinen Mac nie.")
                .font(.caption)
        }
    }
}
