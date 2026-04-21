import AppKit
import SwiftUI

/// Central coordinator: owns the menu bar item, orchestrates startup checks,
/// and wires together all services.
///
/// Startup sequence:
///   1. Show menu bar icon (placeholder while loading)
///   2. Restore session from Keychain + refresh token against backend
///   3. If no valid session → show login window
///   4. Fetch profiles row (filter: user_id = auth.user.id)
///   5. Check profile.status: must be 'active'; otherwise show blocked state
///   6. Load user_settings (PATCH on save, POST on first insert)
///   7. Register global shortcuts
///   8. Request microphone + Accessibility permissions
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Services

    let authService        = AuthService()
    let settingsService    = SettingsService()
    let recordingService   = RecordingService()
    let transcriptionService = TranscriptionService()
    let modeProcessor      = ModeProcessor()
    let outputService      = OutputService()
    let sessionLogger      = SessionLogger()
    let permissionsManager = PermissionsManager()

    // MARK: - UI

    private var menuBarController:        MenuBarController?
    private var loginWindowController:    NSWindowController?
    private var settingsWindowController: NSWindowController?

    // MARK: - Recording timer

    private var recordingTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(delegate: self)
        Task { await performStartupChecks() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController = nil
    }

    // MARK: - Startup

    private func performStartupChecks() async {
        do {
            // Step 1: Restore + refresh stored session
            guard let session = try await authService.validateStoredSession() else {
                await showLoginWindow()
                return
            }

            // Step 2: Fetch profile (filter on user_id, not profiles.id)
            let profile = try await authService.fetchUserProfile(session: session)

            // Step 3: Enforce access — only 'active' users may proceed
            if !profile.status.isAllowedAccess {
                if let reason = profile.status.blockedReason {
                    await updateMenuBarState(.blocked(reason))
                }
                return
            }

            // Step 4: Fetch role (informational, non-blocking on error)
            _ = try? await authService.fetchUserRole(session: session)

            // Step 5: Load settings
            let settings = try await settingsService.loadSettings(session: session)

            // Step 6: Register shortcuts
            ShortcutManager.shared.register(settings: settings) { [weak self] mode in
                self?.handleShortcutTriggered(mode: mode)
            }

            // Step 7: Request permissions (non-blocking)
            await permissionsManager.requestRequiredPermissions()

            // Ready
            menuBarController?.update(state: .idle, profile: profile, settings: settings)

        } catch {
            menuBarController?.update(
                state: .error(error.localizedDescription),
                profile: nil,
                settings: nil
            )
        }
    }

    // MARK: - Dictation Pipeline

    func handleShortcutTriggered(mode: ProcessingMode) {
        Task { await runDictationPipeline(mode: mode) }
    }

    private func runDictationPipeline(mode: ProcessingMode) async {
        guard let session = authService.currentSession else { return }
        let settings = settingsService.currentSettings
        let outputMode = settings?.outputMode ?? .insertIntoField

        if recordingService.isRecording {
            // Second press: stop → transcribe → process → output → log
            let startedAt = recordingService.recordingStartedAt ?? Date()
            let audioSeconds = Int(recordingService.currentDurationSeconds)
            var audio: RecordedAudio?

            do {
                stopRecordingTimer()
                audio = try await recordingService.stopRecording()
                guard let audio else { return }
                await updateMenuBarState(.processing)

                // Transcribe
                let transcriptionResult = try await transcriptionService.transcribe(
                    audio: audio,
                    language: settings?.language ?? .autoDetect,
                    mode: mode,
                    session: session
                )

                // Mode processing (passes detected locale for context)
                let processed = try await modeProcessor.process(
                    text: transcriptionResult.transcript,
                    mode: mode,
                    language: transcriptionResult.usedLocale,
                    session: session
                )

                // Output — returns true if clipboard was used instead of AX insertion
                let usedClipboard = try await outputService.output(text: processed, mode: outputMode)

                // Log success
                await sessionLogger.logCompleted(
                    session: session,
                    mode: mode,
                    rawTranscript: transcriptionResult.transcript,
                    finalText: processed,
                    detectedLanguage: transcriptionResult.usedLocale,
                    outputMode: outputMode,
                    startedAt: startedAt,
                    audioSeconds: audioSeconds
                )

                // Show clipboard indicator if direct insertion was unavailable
                let successState: AppState = (usedClipboard && outputMode == .insertIntoField)
                    ? .successWithClipboard
                    : .success
                await updateMenuBarState(successState)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await updateMenuBarState(.idle)

            } catch {
                stopRecordingTimer()
                await sessionLogger.logFailed(
                    session: session,
                    mode: mode,
                    errorMessage: error.localizedDescription,
                    outputMode: outputMode,
                    startedAt: startedAt
                )
                await updateMenuBarState(.error(error.localizedDescription))
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await updateMenuBarState(.idle)
            }

            // Always clean up temp audio file
            audio?.cleanup()

        } else {
            // First press: start recording
            do {
                try await recordingService.startRecording(deviceID: settings?.microphoneDevice)
                await updateMenuBarState(.recording(mode: mode))
                startRecordingTimer()
            } catch {
                await updateMenuBarState(.error(error.localizedDescription))
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await updateMenuBarState(.idle)
            }
        }
    }

    // MARK: - Windows

    func showLoginWindow() async {
        guard loginWindowController == nil else {
            loginWindowController?.window?.makeKeyAndOrderFront(nil)
            return
        }
        let vm = LoginViewModel(authService: authService) { [weak self] in
            self?.loginWindowController?.close()
            self?.loginWindowController = nil
            Task { await self?.performStartupChecks() }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voiceflow — Sign In"
        window.center()
        window.contentView = NSHostingView(rootView: LoginView(viewModel: vm))
        window.isReleasedWhenClosed = false
        loginWindowController = NSWindowController(window: window)
        loginWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        guard let session = authService.currentSession else { return }
        if settingsWindowController == nil {
            let vm = SettingsViewModel(settingsService: settingsService, session: session)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Voiceflow — Settings"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(viewModel: vm))
            window.isReleasedWhenClosed = false
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Recording Timer

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.menuBarController?.incrementRecordingSeconds()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Helpers

    private func updateMenuBarState(_ state: AppState) async {
        menuBarController?.update(state: state, profile: nil, settings: nil)
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarDidRequestSettings() { showSettingsWindow() }

    func menuBarDidRequestSignOut() {
        Task {
            await authService.signOut()
            ShortcutManager.shared.unregisterAll()
            settingsWindowController?.close()
            settingsWindowController = nil
            await showLoginWindow()
        }
    }

    func menuBarDidRequestCheckForUpdates() {
        // Sparkle not active in ad-hoc beta build — updates are distributed via DMG.
        // Phase 2 (Developer ID + notarization) will re-enable this.
        let alert = NSAlert()
        alert.messageText = "Updates coming soon"
        alert.informativeText = "Auto-updates are not yet enabled in this beta. Download the latest version from your administrator."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func menuBarDidRequestQuit() { NSApp.terminate(nil) }
}
