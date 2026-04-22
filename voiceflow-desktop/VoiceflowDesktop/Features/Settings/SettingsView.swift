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
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                if viewModel.saveSuccess {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .transition(.opacity)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
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
                }
                Spacer()
                Button("Reset to Defaults") { viewModel.resetToDefaults() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Save") { Task { await viewModel.save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 500, height: 540)
    }
}

// MARK: - Section: Shortcuts

private struct ShortcutsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SectionHeader(title: "Keyboard Shortcuts", subtitle: "Press the same shortcut again to stop recording.")

        VStack(spacing: 12) {
            ShortcutRow(
                label: "Private Mode",
                description: "Minimal correction, original wording preserved",
                name: .dictatePrivate
            )
            ShortcutRow(
                label: "Business Mode",
                description: "Professional, customer-facing tone",
                name: .dictateBusiness
            )
            ShortcutRow(
                label: "Calm Mode",
                description: "De-escalated, respectful rewrite",
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
        SectionHeader(title: "Language", subtitle: "Auto-detect works well for German and English.")

        Toggle("Auto-detect language", isOn: $draft.autoDetectLanguage)

        if !draft.autoDetectLanguage {
            Picker("Language", selection: $draft.manualLanguageOverride) {
                ForEach(SupportedLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
    }
}

// MARK: - Section: Output

private struct OutputSection: View {
    @Binding var draft: AppSettings

    var body: some View {
        SectionHeader(
            title: "Output Mode",
            subtitle: "Insert into field requires Accessibility permission."
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
                        Text("Falls back to clipboard if Accessibility is not granted.")
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
        SectionHeader(title: "Microphone", subtitle: "Default uses the system input device.")

        Group {
            if devices.isEmpty {
                Text("No additional input devices found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Input device", selection: Binding(
                    get: { draft.microphoneDevice ?? "" },
                    set: { draft.microphoneDevice = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System default").tag("")
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
            title: "Permissions",
            subtitle: "Microphone is required. Accessibility enables direct text insertion."
        )

        VStack(spacing: 8) {
            PermissionRow(
                icon: "mic.fill",
                label: "Microphone",
                note: "Required — to record your speech",
                granted: hasMic,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
            PermissionRow(
                icon: "keyboard",
                label: "Accessibility",
                note: "Optional — enables direct text insertion (falls back to clipboard)",
                granted: hasAX,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
        .onAppear {
            refreshStatus()
            // Poll every 2 s — lets the status flip to ✅ as soon as the user
            // grants permission in System Settings and switches back here.
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
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Grant Access") {
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

