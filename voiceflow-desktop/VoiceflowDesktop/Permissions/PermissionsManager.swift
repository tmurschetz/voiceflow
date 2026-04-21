import AVFoundation
import ApplicationServices
import AppKit

/// Guides the user through granting the two required macOS permissions on first run:
///   1. Microphone     — to capture audio (required)
///   2. Accessibility  — to insert text into the active text field (optional, degrades to clipboard)
///
/// Speech Recognition is NOT requested — Voiceflow uses OpenAI Whisper (cloud API)
/// which does not require the macOS Speech Recognition entitlement.
final class PermissionsManager {

    // MARK: - Request All

    /// Call once on startup after the user is authenticated and active.
    func requestRequiredPermissions() async {
        await requestMicrophonePermission()
        checkAccessibilityPermission()
        // Speech Recognition removed — Whisper API does not use SFSpeechRecognizer
    }

    // MARK: - Status Properties

    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Microphone

    func requestMicrophonePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            await showPermissionAlert(
                title: "Microphone Access Required",
                message: """
                    Voiceflow needs microphone access to record your speech.

                    Enable it in:
                    System Settings → Privacy & Security → Microphone
                    """,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        @unknown default:
            break
        }
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }
        Task { @MainActor in
            await showPermissionAlert(
                title: "Accessibility Access (Optional)",
                message: """
                    Voiceflow can insert transcribed text directly into any text field.
                    Without this, text is pasted via the clipboard instead.

                    To enable:
                    System Settings → Privacy & Security → Accessibility
                    """,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
    }

    // MARK: - Alert Helper

    @MainActor
    private func showPermissionAlert(title: String, message: String, settingsURL: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: settingsURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
