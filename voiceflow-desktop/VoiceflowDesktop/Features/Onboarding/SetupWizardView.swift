import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

/// First-run setup wizard: walks a new user through everything needed to use
/// Voiceflow — API key, models, shortcuts, permissions — in clear steps, so they
/// don't have to discover Settings on their own. Shown once on first launch
/// (gated by the `hasCompletedSetup` flag); reopenable from the menu.
@MainActor
final class SetupWizardViewModel: ObservableObject {

    enum Step: Int, CaseIterable {
        case welcome, apiKey, shortcuts, permissions, done
    }

    @Published var step: Step = .welcome
    @Published var draft: AppSettings

    // API key
    @Published var apiKeyInput = ""
    @Published var isValidatingKey = false
    @Published var keyError: String?
    @Published var keyStored: Bool = KeychainStore.hasAPIKey

    private let settingsService: SettingsService
    var onComplete: () -> Void = {}

    static let completedFlag = "com.voiceflow.desktop.hasCompletedSetup"

    init(settingsService: SettingsService) {
        self.settingsService = settingsService
        self.draft = settingsService.currentSettings ?? settingsService.loadSettings()
    }

    var canLeaveKeyStep: Bool { keyStored }

    /// Validates the typed key against the OpenAI API and stores it in the Keychain.
    func validateAndStoreKey() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isValidatingKey = true
        keyError = nil
        defer { isValidatingKey = false }
        do {
            try await OpenAIClient.shared.validate(apiKey: key)
            KeychainStore.apiKey = key
            apiKeyInput = ""
            keyStored = true
        } catch {
            keyError = error.localizedDescription
        }
    }

    // MARK: - Navigation

    func next() {
        persist()
        if let s = Step(rawValue: step.rawValue + 1) { step = s }
    }

    func back() {
        if let s = Step(rawValue: step.rawValue - 1) { step = s }
    }

    func finish() {
        persist()
        UserDefaults.standard.set(true, forKey: Self.completedFlag)
        onComplete()
    }

    /// Saves the draft (models, shortcut strings) locally and re-binds shortcuts.
    private func persist() {
        syncShortcutsFromRecorder()
        try? settingsService.saveSettings(draft)
        ShortcutManager.shared.reattachHandlers()
    }

    private func syncShortcutsFromRecorder() {
        draft.shortcutPrivate  = KeyboardShortcuts.getShortcut(for: .dictatePrivate)?.description ?? draft.shortcutPrivate
        draft.shortcutBusiness = KeyboardShortcuts.getShortcut(for: .dictateBusiness)?.description ?? draft.shortcutBusiness
        draft.shortcutRandom   = KeyboardShortcuts.getShortcut(for: .dictateRandom)?.description ?? draft.shortcutRandom
    }
}

// MARK: - Wizard view

struct SetupWizardView: View {
    @ObservedObject var viewModel: SetupWizardViewModel

    private let indigo = Color(red: 0.24, green: 0.18, blue: 0.67)
    private let blue   = Color(red: 0.29, green: 0.56, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 30)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        switch viewModel.step {
        case .welcome, .done:
            ZStack {
                LinearGradient(colors: [indigo, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 12) {
                    if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 76, height: 76)
                            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    }
                    Text(viewModel.step == .welcome ? "Willkommen bei Voiceflow" : "Alles bereit! 🎉")
                        .font(.title.bold()).foregroundStyle(.white)
                    Text(viewModel.step == .welcome
                         ? "Diktieren in jeder App — in deinem Ton."
                         : "Drück deinen Shortcut, sprich los — fertig.")
                        .font(.callout).foregroundStyle(.white.opacity(0.9))
                }
                .padding(.vertical, 28)
            }
            .frame(height: 180)
        default:
            VStack(spacing: 10) {
                HStack {
                    Text(stepTitle).font(.title3.bold())
                    Spacer()
                    Text("Schritt \(viewModel.step.rawValue)/3").font(.caption).foregroundStyle(.secondary)
                }
                ProgressDots(current: viewModel.step.rawValue, total: 3)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var stepTitle: String {
        switch viewModel.step {
        case .apiKey:      return "OpenAI API-Key"
        case .shortcuts:   return "Shortcuts"
        case .permissions: return "Berechtigungen"
        default:           return ""
        }
    }

    // MARK: Content per step

    @ViewBuilder private var content: some View {
        switch viewModel.step {
        case .welcome:      WelcomeStep()
        case .apiKey:       APIKeyStep(viewModel: viewModel)
        case .shortcuts:    ShortcutsStep()
        case .permissions:  PermissionsStep()
        case .done:         DoneStep(draft: viewModel.draft)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack {
            if viewModel.step != .welcome && viewModel.step != .done {
                Button("Zurück") { viewModel.back() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            switch viewModel.step {
            case .welcome:
                Button { viewModel.next() } label: {
                    HStack(spacing: 6) { Text("Los geht's"); Image(systemName: "arrow.right") }.padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            case .apiKey:
                Button("Weiter") { viewModel.next() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!viewModel.canLeaveKeyStep)
            case .permissions:
                Button("Fertig") { viewModel.finish() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            case .done:
                Button("Schliessen") { viewModel.finish() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            default:
                Button("Weiter") { viewModel.next() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

// MARK: - Progress dots

private struct ProgressDots: View {
    let current: Int   // 1-based
    let total: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(1...total, id: \.self) { i in
                Circle()
                    .fill(i <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("In drei kurzen Schritten bist du startklar:")
                .font(.callout).foregroundStyle(.secondary)
            WizFeature(icon: "key.fill", color: .blue, title: "Dein OpenAI-Key",
                       text: "Bleibt im Schlüsselbund dieses Macs — kein Login, keine Cloud dazwischen.")
            WizFeature(icon: "command", color: .indigo, title: "Shortcuts festlegen",
                       text: "Drei Tasten für Privat, Business und Random.")
            WizFeature(icon: "checkmark.shield.fill", color: .green, title: "Berechtigungen",
                       text: "Mikrofon und (optional) direktes Einfügen.")
        }
    }
}

private struct APIKeyStep: View {
    @ObservedObject var viewModel: SetupWizardViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.keyStored {
                Label("Key ist hinterlegt (\(KeychainStore.maskedKey)).", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Du kannst weitergehen — oder unten einen anderen Key eintragen.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Voiceflow nutzt dein eigenes OpenAI-Konto. Der Key bleibt lokal im Schlüsselbund und geht ausschliesslich an api.openai.com.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Key erstellen auf platform.openai.com ↗") {
                    if let url = URL(string: Config.apiKeysURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
            }

            HStack(spacing: 8) {
                SecureField(text: $viewModel.apiKeyInput, prompt: Text("sk-…")) { EmptyView() }
                    .textFieldStyle(.roundedBorder).labelsHidden().font(.body.monospaced())
                    .onSubmit { Task { await viewModel.validateAndStoreKey() } }
                Button {
                    Task { await viewModel.validateAndStoreKey() }
                } label: {
                    if viewModel.isValidatingKey { ProgressView().controlSize(.small) }
                    else { Text(viewModel.keyStored ? "Ersetzen" : "Prüfen") }
                }
                .disabled(viewModel.apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isValidatingKey)
            }

            if let err = viewModel.keyError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Label("~0.3 Rappen pro Diktatminute, abgerechnet von OpenAI über deinen Key.", systemImage: "creditcard")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
        }
    }
}

private struct ShortcutsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Leg für jeden Modus eine Tastenkombination fest. Gleiche Kombination nochmals drücken stoppt die Aufnahme.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            WizShortcut(icon: "person.fill", color: .blue, label: "Privat",
                        sub: "Leichte Korrektur", name: .dictatePrivate)
            WizShortcut(icon: "briefcase.fill", color: .indigo, label: "Business",
                        sub: "Professioneller Ton", name: .dictateBusiness)
            WizShortcut(icon: "sparkles", color: .pink, label: "Random",
                        sub: "Macht, was deine Instruktion sagt", name: .dictateRandom)
            Text("Tipp: z. B. ⌥1, ⌥2, ⌥3.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct PermissionsStep: View {
    @State private var hasMic = false
    @State private var hasAX = false
    @State private var timer: Timer?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voiceflow braucht Zugriff aufs Mikrofon. Für direktes Einfügen in Textfelder hilft die Bedienungshilfen-Berechtigung (sonst landet der Text in der Zwischenablage).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            WizPermission(icon: "mic.fill", color: .red, label: "Mikrofon",
                          note: "Erforderlich — zeichnet deine Sprache auf", granted: hasMic,
                          url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            WizPermission(icon: "accessibility", color: .blue, label: "Bedienungshilfen",
                          note: "Optional — fügt Text direkt ein", granted: hasAX,
                          url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            Text("Du kannst das auch später erteilen — die App fragt beim ersten Diktat automatisch.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .onAppear {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in refresh() }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }
    private func refresh() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAX = AXIsProcessTrusted()
    }
}

private struct DoneStep: View {
    let draft: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("So benutzt du Voiceflow:")
                .font(.callout.weight(.medium))
            WizFeature(icon: "1.circle.fill", color: .blue, title: "Shortcut drücken",
                       text: "In jeder App, wo dein Cursor in einem Textfeld steht.")
            WizFeature(icon: "2.circle.fill", color: .indigo, title: "Sprechen",
                       text: "Reden wie dir der Schnabel gewachsen ist — Füllwörter sind ok.")
            WizFeature(icon: "3.circle.fill", color: .green, title: "Nochmal drücken",
                       text: "Der bereinigte Text erscheint direkt im Feld.")
            Text("Einstellungen, Verlauf und Modi findest du jederzeit über das Menüleisten-Icon.")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
        }
    }
}

// MARK: - Small reusable bits

private struct WizFeature: View {
    let icon: String; let color: Color; let title: String; let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WizShortcut: View {
    let icon: String; let color: Color; let label: String; let sub: String
    let name: KeyboardShortcuts.Name
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout.weight(.medium))
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

private struct WizPermission: View {
    let icon: String; let color: Color; let label: String; let note: String
    let granted: Bool; let url: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill((granted ? Color.green : color).gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout.weight(.medium))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Erteilt", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else {
                Button("Erlauben") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                    .controlSize(.small)
            }
        }
    }
}
