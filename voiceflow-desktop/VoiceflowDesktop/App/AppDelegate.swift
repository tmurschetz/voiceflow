import AppKit
import SwiftUI

/// Central coordinator: owns the menu bar item, orchestrates startup checks,
/// and wires together all services.
///
/// V2 architecture — fully local:
///   1. Show menu bar icon
///   2. Load settings (UserDefaults)
///   3. Register global shortcuts
///   4. If no OpenAI API key in Keychain → show onboarding window
///   5. Request microphone + Accessibility permissions
///
/// Dictation pipeline (toggle: press to start, press again to stop):
///   record → transcribe (OpenAI, user's key) → tone-of-voice rewrite (OpenAI)
///   → insert into active app (AX or clipboard+⌘V) → local history log
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Services

    let settingsService      = SettingsService()
    let recordingService     = RecordingService()
    let transcriptionService = TranscriptionService()
    let modeProcessor        = ModeProcessor()
    let outputService        = OutputService()
    let permissionsManager   = PermissionsManager()

    // MARK: - UI

    private var menuBarController:          MenuBarController?
    private var onboardingWindowController: NSWindowController?
    private var settingsWindowController:   NSWindowController?
    private var historyWindowController:    NSWindowController?

    // MARK: - Recording timer

    private var recordingTimer: Timer?

    // MARK: - Auto-update timer

    private var updateTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless UI-snapshot mode (--snapshot <dir>) — renders screens to PNG
        // asynchronously and terminates itself when done.
        if SnapshotMode.runIfRequested() {
            return
        }

        // Headless functional self-test (--selftest [audio]) — exercises the real
        // pipeline and exits with a pass/fail report.
        if SelfTest.runIfRequested() {
            return
        }

        // Headless E2E of the managed-account flow against a local accounts
        // service (--accounttest <url> <adminToken>) — in-memory store only.
        if AccountTest.runIfRequested() {
            return
        }

        menuBarController = MenuBarController(delegate: self)
        resetAXPromptIfNewBuild()

        // One-time: upgrade users still on the old, less accurate default model.
        settingsService.migrateTranscribeModelIfNeeded()
        settingsService.migrateTranscribeModelToWhisperIfNeeded()
        settingsService.migrateTextModelIfNeeded()

        // Load local settings + bind shortcuts immediately — no network needed.
        let settings = settingsService.loadSettings()
        ShortcutManager.shared.register(settings: settings) { [weak self] mode in
            self?.handleShortcutTriggered(mode: mode)
        }

        if KeychainStore.hasAPIKey {
            menuBarController?.update(state: .idle, settings: settings)
        } else {
            menuBarController?.update(state: .needsAPIKey, settings: settings)
            showOnboardingWindow()
        }

        // A rescued recording from a previous run survives the restart —
        // surface it in the panel so the user can still retry it.
        menuBarController?.refreshRescueState()

        Task { await permissionsManager.requestRequiredPermissions() }

        // Managed accounts: while an access request awaits approval, poll the
        // accounts service; once approved the key installs itself and the menu
        // bar flips to ready.
        AccountService.shared.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            let current = self.settingsService.currentSettings
            switch phase {
            case .active:
                self.menuBarController?.update(state: .idle, settings: current)
                self.showAccountActivatedAlert()
            case .revoked, .denied:
                if !KeychainStore.hasAPIKey {
                    self.menuBarController?.update(state: .needsAPIKey, settings: current)
                }
            default:
                break
            }
        }
        if AccountService.shared.isPending {
            AccountService.shared.startPolling()
        }

        // Auto-update: check shortly after launch, then periodically (internally
        // throttled to ~once a day). Updates come from the app's public GitHub
        // releases — see UpdateService.
        UpdateService.shared.checkInBackground()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateService.shared.checkInBackground() }
        }
    }

    /// Resets the "Accessibility already prompted" flag whenever a new binary is
    /// installed. Ad-hoc builds get a new signature per install, which revokes AX —
    /// this makes the hint dialog appear exactly once per build.
    private func resetAXPromptIfNewBuild() {
        let buildKey = "com.voiceflow.desktop.last_binary_date"
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return }
        let fingerprint = String(modDate.timeIntervalSince1970)
        let lastFingerprint = UserDefaults.standard.string(forKey: buildKey) ?? ""
        if fingerprint != lastFingerprint {
            UserDefaults.standard.set(fingerprint, forKey: buildKey)
            permissionsManager.resetAccessibilityPromptFlag()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController = nil
    }

    // MARK: - Dictation Pipeline

    func handleShortcutTriggered(mode: ProcessingMode) {
        Task { await runDictationPipeline(mode: mode) }
    }

    private func runDictationPipeline(mode: ProcessingMode) async {
        // No key → send the user to onboarding instead of failing mid-pipeline.
        guard KeychainStore.hasAPIKey else {
            await updateMenuBarState(.needsAPIKey)
            showOnboardingWindow()
            return
        }

        let settings = settingsService.currentSettings
        let outputMode = settings?.outputMode ?? .insertIntoField

        if recordingService.isRecording {
            // Second press: stop → transcribe → process → output → log
            // Capture the frontmost app PID NOW — before any async work —
            // so the paste keystroke targets the correct app even after
            // a few seconds of processing.
            let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let audioSeconds = Int(recordingService.currentDurationSeconds)
            var audio: RecordedAudio?

            do {
                stopRecordingTimer()
                audio = try await recordingService.stopRecording()
                guard let audio else { return }
                await updateMenuBarState(.processing)

                // Transcribe with the user-selected model — retries transient
                // failures with a visible countdown, like the rewrite stage.
                let transcriptionResult = try await transcriptionService.transcribe(
                    audio: audio,
                    language: settings?.language ?? .autoDetect,
                    model: settings?.transcribeModel ?? TranscribeModel.recommended.id,
                    vocabulary: settings?.customVocabulary ?? "",
                    onRetry: { [weak self] event in
                        self?.showRetryEvent(event)
                    }
                )

                // Tone-of-voice rewrite — retries transient failures and falls
                // back to the raw transcript so no dictation is ever lost.
                let processingResult = try await modeProcessor.process(
                    text: transcriptionResult.transcript,
                    mode: mode,
                    userInstruction: settings?.instruction(for: mode) ?? "",
                    textModel: settings?.textModel ?? TextModel.recommended.id,
                    vocabulary: settings?.customVocabulary ?? "",
                    onRetry: { [weak self] event in
                        self?.showRetryEvent(event)
                    }
                )
                let processed = processingResult.text

                // Output — returns true if clipboard was used instead of AX insertion
                let usedClipboard = try await outputService.output(
                    text: processed, mode: outputMode, targetPID: targetPID)

                // Local history (respects the privacy toggle) + last-dictation in the panel
                if settings?.historyEnabled ?? true {
                    let fileSeconds = TranscriptionService.audioDuration(url: audio.fileURL).map { Int($0) }
                    HistoryStore.shared.logCompleted(
                        mode: mode,
                        raw: transcriptionResult.transcript,
                        final: processed,
                        audioSeconds: audioSeconds,
                        usedFallback: processingResult.usedFallback,
                        fileSeconds: fileSeconds
                    )
                }
                menuBarController?.setLastDictation(processed)

                // Pick the most informative success state
                let successState: AppState
                if processingResult.usedFallback {
                    successState = .successWithRawFallback
                } else if usedClipboard && outputMode == .insertIntoField {
                    successState = .successWithClipboard
                } else {
                    successState = .success
                }
                await updateMenuBarState(successState)
                let dwellNanos: UInt64 = processingResult.usedFallback ? 4_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: dwellNanos)
                await updateMenuBarState(.idle)

            } catch {
                stopRecordingTimer()

                // An empty recording (no audio captured) is not a failure worth
                // rescuing — retrying it would just fail again. Show a friendly
                // hint and move on without logging a scary failure or rescuing it.
                let isEmptyRecording: Bool = {
                    if case TranscriptionError.noSpeech = error { return true }
                    return false
                }()

                if isEmptyRecording {
                    await updateMenuBarState(.error(error.localizedDescription))
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await updateMenuBarState(.idle)
                } else {
                    if settings?.historyEnabled ?? true {
                        HistoryStore.shared.logFailed(mode: mode, errorMessage: error.localizedDescription)
                    }
                    // RESCUE the recording instead of discarding it: move the audio
                    // into the rescue folder so the user can retry from the panel —
                    // a dictation must never be lost to a transient failure.
                    var message = error.localizedDescription
                    if let failedAudio = audio,
                       RescueStore.shared.save(fileURL: failedAudio.fileURL, mode: mode) != nil {
                        menuBarController?.refreshRescueState()
                        message += " — Aufnahme gerettet, im Panel «Erneut versuchen»."
                        audio = nil   // moved — nothing left to clean up
                    }
                    await updateMenuBarState(.error(message))
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await updateMenuBarState(.idle)
                }
            }

            // Clean up the temp audio file (no-op when it was rescued)
            audio?.cleanup()

        } else {
            // First press: start recording.
            // Warm up the TLS connection to api.openai.com in parallel — the
            // handshake (~300–600 ms) completes while the user is speaking, so
            // the transcription POST reuses the open connection.
            OpenAIClient.shared.warmUpConnection()
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

    // MARK: - Rescue retry

    private var isRetryingRescue = false

    /// Re-runs the pipeline for the most recent rescued (failed) recording.
    /// Delivery goes to the clipboard: at retry time the original target app /
    /// cursor position is long gone, so direct insertion would be guesswork.
    private func retryRescuedDictation() async {
        guard !isRetryingRescue, !recordingService.isRecording else { return }
        guard let rescued = RescueStore.shared.latest else { return }
        guard KeychainStore.hasAPIKey else {
            await updateMenuBarState(.needsAPIKey)
            showOnboardingWindow()
            return
        }
        isRetryingRescue = true
        defer { isRetryingRescue = false }

        let settings = settingsService.currentSettings
        await updateMenuBarState(.processing)

        do {
            let audio = RecordedAudio(fileURL: rescued.fileURL)
            let transcriptionResult = try await transcriptionService.transcribe(
                audio: audio,
                language: settings?.language ?? .autoDetect,
                model: settings?.transcribeModel ?? TranscribeModel.recommended.id,
                vocabulary: settings?.customVocabulary ?? "",
                onRetry: { [weak self] event in self?.showRetryEvent(event) }
            )
            let processingResult = try await modeProcessor.process(
                text: transcriptionResult.transcript,
                mode: rescued.mode,
                userInstruction: settings?.instruction(for: rescued.mode) ?? "",
                textModel: settings?.textModel ?? TextModel.recommended.id,
                vocabulary: settings?.customVocabulary ?? "",
                onRetry: { [weak self] event in self?.showRetryEvent(event) }
            )

            _ = try await outputService.output(text: processingResult.text, mode: .clipboardOnly)

            if settings?.historyEnabled ?? true {
                HistoryStore.shared.logCompleted(
                    mode: rescued.mode,
                    raw: transcriptionResult.transcript,
                    final: processingResult.text,
                    audioSeconds: nil,
                    usedFallback: processingResult.usedFallback,
                    fileSeconds: TranscriptionService.audioDuration(url: rescued.fileURL).map { Int($0) }
                )
            }
            menuBarController?.setLastDictation(processingResult.text)
            RescueStore.shared.delete(rescued)
            menuBarController?.refreshRescueState()

            await updateMenuBarState(.successWithClipboard)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await updateMenuBarState(.idle)

        } catch {
            // Recording stays in the rescue store for another attempt.
            await updateMenuBarState(.error(error.localizedDescription + " — Aufnahme bleibt gerettet."))
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await updateMenuBarState(.idle)
        }
    }

    /// Forwards retry countdowns from either pipeline stage to the menu bar.
    private func showRetryEvent(_ event: PipelineRetryEvent) {
        switch event {
        case .willRetryIn(let sec, let attempt, let total):
            menuBarController?.update(
                state: .retrying(attempt: attempt, total: total, secondsRemaining: sec))
        case .retrying:
            menuBarController?.update(state: .processing)
        }
    }

    // MARK: - Windows

    /// Shows the first-run setup wizard (API key → models → shortcuts →
    /// permissions). Also reopenable from the menu for users who want to revisit it.
    private func showOnboardingWindow() {
        if let existing = onboardingWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let vm = SetupWizardViewModel(settingsService: settingsService)
        vm.onComplete = { [weak self] in
            guard let self else { return }
            self.onboardingWindowController?.close()
            self.onboardingWindowController = nil
            let settings = self.settingsService.currentSettings
            let state: AppState = KeychainStore.hasAPIKey ? .idle : .needsAPIKey
            self.menuBarController?.update(state: state, settings: settings)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Voiceflow — Setup"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.contentView = NSHostingView(rootView: SetupWizardView(viewModel: vm))
        window.isReleasedWhenClosed = false
        onboardingWindowController = NSWindowController(window: window)
        onboardingWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        if settingsWindowController == nil {
            let vm = SettingsViewModel(settingsService: settingsService)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Voiceflow — Einstellungen"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(viewModel: vm))
            window.isReleasedWhenClosed = false
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One-time celebration when a managed access request gets approved.
    private func showAccountActivatedAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Voiceflow ist freigeschaltet 🎉"
        alert.informativeText = "Dein Zugang wurde eingerichtet. Drück deinen Shortcut, sprich los — fertig."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Los geht's")
        alert.runModal()
    }

    func showHistoryWindow() {
        // Recreate on every open so the list is always fresh (entries are loaded
        // in HistoryView.onAppear; a cached window would show a stale list).
        let enabled = settingsService.currentSettings?.historyEnabled ?? true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voiceflow — Verlauf"
        window.center()
        window.contentView = NSHostingView(rootView: HistoryView(historyEnabled: enabled))
        window.isReleasedWhenClosed = false
        historyWindowController = NSWindowController(window: window)
        historyWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Recording Timer

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.menuBarController?.incrementRecordingSeconds()
                // Keep the OpenAI connection alive during long recordings. The
                // connection warmed at record-start gets closed by the server
                // after ~60–90 s idle; without this, the transcription POST after
                // a long dictation hits a dead connection and stalls until the
                // timeout. Re-warming every 25 s keeps it fresh.
                let secs = self.menuBarController?.currentRecordingSeconds ?? 0
                if secs > 0 && secs % 25 == 0 {
                    OpenAIClient.shared.warmUpConnection()
                }
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Helpers

    private func updateMenuBarState(_ state: AppState) async {
        menuBarController?.update(state: state)
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarDidRequestSettings() { showSettingsWindow() }

    func menuBarDidRequestSetupWizard() { showOnboardingWindow() }

    func menuBarDidRequestHistory() {
        // In-app history window (v1.1) — "Im Finder zeigen" lives in its footer.
        showHistoryWindow()
    }

    func menuBarDidRequestCheckForUpdates() {
        UpdateService.shared.checkManually()
    }

    func menuBarDidRequestQuit() { NSApp.terminate(nil) }

    func menuBarDidRequestRescueRetry() {
        Task { await retryRescuedDictation() }
    }
}
