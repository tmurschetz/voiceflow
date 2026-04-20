import AVFoundation
import ApplicationServices
import AppKit
import Speech

/// Guides the user through granting the three required macOS permissions on first run:
///   1. Microphone            — to capture audio
///   2. Speech Recognition    — for SFSpeechRecognizer (on-device transcription)
///   3. Accessibility         — to insert text into the active text field
///
/// Only Microphone and Speech Recognition are requested proactively.
/// Accessibility shows an informational alert (the user must navigate there manually).
final class PermissionsManager {

    // MARK: - Request All

    /// Call once on startup after the user is authenticated and active.
    func requestRequiredPermissions() async {
        await requestMicrophonePermission()
        await requestSpeechPermission()
        checkAccessibilityPermission()
    }

    // MARK: - Status Properties

    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasSpeechPermission: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
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

    // MARK: - Speech Recognition

    func requestSpeechPermission() async {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume(returning: ())
                }
            }
        case .denied, .restricted:
            await showPermissionAlert(
                title: "Speech Recognition Required",
                message: """
                    Voiceflow uses on-device speech recognition to transcribe your voice.

                    Enable it in:
                    System Settings → Privacy & Security → Speech Recognition
                    """,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
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
                    Without this, text is copied to the clipboard instead.

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
