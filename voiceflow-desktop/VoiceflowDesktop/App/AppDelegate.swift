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

    // MARK: - Transcribe mode (calls)

    let callService = CallRecordingService()
    private let callTranscriber = CallTranscriber()
    private var callTimer: Timer?
    private var teamsTimer: Timer?
    private var teamsDebouncer = TeamsCallDetector.Debouncer()
    /// Set when the user stops a Teams call manually: no auto-restart until
    /// Teams has released the microphone (i.e. the call really ended).
    private var suppressTeamsAutoUntilIdle = false
    private var callStartTitles: Set<String> = []
    /// Windows that opened when the call began (the call window) — best participant source.
    private var callNewTitles: Set<String> = []
    /// Teams window titles while no call runs, refreshed every ~30 s.
    private var teamsIdleTitles: Set<String> = []
    private var teamsPollCount = 0
    /// A manually started recording that Teams then joined: stop it with the call.
    private var teamsSeenDuringCall = false
    private var lastTeamsActive = false
    /// True from the stop press until the dictation is pasted — further presses
    /// must not start a second recording.
    private var isProcessingDictation = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless UI-snapshot mode (--snapshot <dir>) — renders screens to PNG
        // asynchronously and terminates itself when done.
        if SnapshotMode.runIfRequested() {
            return
        }

        // Headless functional self-test (--selftest [audio]) — exercises the real
        // pipeline and exits with a pass/fail report.
        if SelfTest.runReprocessIfRequested() { return }
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
        settingsService.migrateTranscribeModelToGptTranscribeIfNeeded()
        settingsService.migrateTextModelIfNeeded()
        settingsService.migrateDictateInstructionForV2IfNeeded()

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

        // Transcribe mode: expire old call transcripts and watch Teams.
        let purged = CallStore.shared.purgeExpired()
        if purged > 0 { NSLog("[VF-Call] purged %d expired call transcripts", purged) }
        startTeamsMonitor()

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
        switch mode {
        case .dictate:
            Task { await runDictationPipeline(mode: mode) }
        case .transcribe:
            toggleCallTranscription()
        }
    }

    // MARK: - Transcribe mode (calls)

    /// Shortcut / menu / panel: start a call transcript, or stop the running one.
    private func toggleCallTranscription() {
        if callService.isRecording {
            if callService.session?.source == "teams-auto" || teamsSeenDuringCall { suppressTeamsAutoUntilIdle = true }
            Task { await stopCallAndProcess() }
        } else {
            startCall(source: "manual")
        }
    }

    private func startCall(source: String) {
        guard KeychainStore.hasAPIKey else { showOnboardingWindow(); return }
        guard !callService.isRecording else { return }
        do {
            try callService.start(folderBase: CallStore.shared.baseURL, source: source)
        } catch {
            NSLog("[VF-Call] start failed: %@", String(describing: error))
            showHUD("Call-Mitschrift konnte nicht starten", detail: error.localizedDescription)
            return
        }
        callStartTitles = Set(TeamsCallDetector.teamsWindowTitles())
        callNewTitles = teamsIdleTitles.isEmpty ? [] : callStartTitles.subtracting(teamsIdleTitles)
        callStartTitles.forEach { callService.noteParticipantHint($0) }
        teamsSeenDuringCall = source == "teams-auto"
        CallStore.shared.logEvent("call start source=\(source) newWindows=\(callNewTitles.count) systemAudio=\(!callService.systemAudioUnavailable)")
        publishCallStatus()
        callTimer?.invalidate()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.callService.elapsedSeconds % 60 == 0 {
                    TeamsCallDetector.teamsWindowTitles().forEach { self.callService.noteParticipantHint($0) }
                }
                self.publishCallStatus()
            }
        }
        showHUD(source == "teams-auto" ? "Teams-Call erkannt — Mitschrift läuft" : "Call-Mitschrift gestartet",
                detail: callService.systemAudioUnavailable
                    ? "Nur Mikrofon: Systemaudio-Berechtigung fehlt (Systemeinstellungen → Datenschutz → Bildschirm- & Systemaudio-Aufnahme)."
                    : "Beide Seiten werden aufgezeichnet. Stopp: Shortcut, Panel oder Menü.")
    }

    private func publishCallStatus() {
        guard let s = callService.session else { menuBarController?.setCall(nil); return }
        menuBarController?.setCall(CallStatus(
            phase: .recording,
            elapsedSeconds: callService.elapsedSeconds,
            source: s.source,
            participant: TeamsCallDetector.participantGuess(from: s.participantHints, newAtStart: callNewTitles),
            systemAudioMissing: callService.systemAudioUnavailable))
    }

    private func stopCallAndProcess() async {
        callTimer?.invalidate(); callTimer = nil
        guard let session = callService.stop() else { menuBarController?.setCall(nil); return }
        let settings = settingsService.currentSettings
        teamsSeenDuringCall = false
        let participant = TeamsCallDetector.participantGuess(from: session.participantHints, newAtStart: callNewTitles)
        var record = CallStore.Record(
            id: session.id, start: session.startedAt, end: Date(), source: session.source,
            participant: participant, hints: Array(session.participantHints).sorted(),
            status: "processing", systemAudioMissing: callService.systemAudioUnavailable)
        CallStore.shared.upsert(record)
        menuBarController?.setCall(CallStatus(phase: .processing(done: 0, total: 0),
                                              elapsedSeconds: record.durationSeconds, source: session.source,
                                              participant: participant,
                                              systemAudioMissing: record.systemAudioMissing))

        // Segment on a background thread (PCM decoding of two tracks), then transcribe.
        let micURL = session.micURL, sysURL = session.systemURL
        let workDir = session.folder.appendingPathComponent("chunks", isDirectory: true)
        // .utility: a long call must not spin the fans while you keep working.
        let (chunks, stats) = await Task.detached(priority: .utility) {
            CallSegmenter.makeChunksWithStats(micURL: micURL, systemURL: sysURL, workDir: workDir)
        }.value
        CallStore.shared.logEvent(String(format: "call stop %ds: %d chunks (me %d, other %d segments, %d trimmed, echo removed %.0fs)",
                                         record.durationSeconds, chunks.count, stats.micSegments,
                                         stats.systemSegments, stats.trimmed, stats.echoRemovedSeconds))

        let output = await callTranscriber.transcribe(
            chunks: chunks, vocabulary: settings?.customVocabulary ?? "",
            model: settings?.transcribeModel ?? TranscribeModel.recommended.id,
            progress: { [weak self] done, total in
                Task { @MainActor in
                    guard let self else { return }
                    self.menuBarController?.setCall(CallStatus(
                        phase: .processing(done: done, total: total),
                        elapsedSeconds: record.durationSeconds, source: session.source,
                        participant: participant, systemAudioMissing: record.systemAudioMissing))
                }
            })
        try? FileManager.default.removeItem(at: workDir)
        CallStore.shared.logEvent("transcribed: failed \(output.failedChunks)/\(output.chunkCount), echo sentences removed \(output.echoSentencesRemoved), phantom pieces removed \(output.phantomPiecesRemoved)")

        record.transcript = output.transcript
        record.languages = output.languages
        if output.transcript.isEmpty {
            record.status = "failed"
            record.errorMessage = chunks.isEmpty ? "Keine Sprache erkannt." : "Transkription fehlgeschlagen (\(output.failedChunks)/\(output.chunkCount) Abschnitte)."
        } else {
            record.status = "done"
        }
        CallStore.shared.upsert(record)
        menuBarController?.setCall(nil)

        let mins = max(1, record.durationSeconds / 60)
        if record.status == "done" {
            showHUD("Call-Transkript bereit (\(mins) Min)",
                    detail: (participant.map { "Mit \($0) · " } ?? "") + "Im Verlauf → Calls kopieren.")
        } else {
            showHUD("Call-Transkript unvollständig", detail: record.errorMessage ?? "")
        }
    }

    // MARK: Teams automation

    private func startTeamsMonitor() {
        teamsTimer?.invalidate()
        teamsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTeams() }
        }
    }

    private func pollTeams() {
        guard settingsService.currentSettings?.autoRecordTeamsCalls ?? true else { return }
        let inputs = TeamsCallDetector.teamsProcessesUsingMicrophone()
        let teamsActive = !inputs.isEmpty
        if teamsActive != lastTeamsActive {
            CallStore.shared.logEvent("teams mic \(teamsActive ? "ON" : "off") \(inputs.joined(separator: ","))")
            lastTeamsActive = teamsActive
        }
        if !teamsActive { suppressTeamsAutoUntilIdle = false }

        // Remember which Teams windows exist outside calls, so the window that
        // opens WITH the call can be told apart from a long-open calendar/chat.
        teamsPollCount += 1
        if !callService.isRecording, !teamsActive, teamsPollCount % 15 == 1, TeamsCallDetector.teamsApp() != nil {
            teamsIdleTitles = Set(TeamsCallDetector.teamsWindowTitles())
        }

        if callService.isRecording, teamsActive { teamsSeenDuringCall = true }
        // A recording is tied to Teams when Teams started it OR Teams joined a
        // manual one — either way it ends with the Teams call.
        let teamsBound = callService.isRecording && teamsSeenDuringCall
        switch teamsDebouncer.tick(callActive: teamsActive, recording: teamsBound) {
        case .start:
            guard !callService.isRecording, !suppressTeamsAutoUntilIdle else { return }
            showConsentReminderOnce()
            startCall(source: "teams-auto")
        case .stop:
            CallStore.shared.logEvent("teams call ended → stopping")
            Task { await stopCallAndProcess() }
        case .none:
            break
        }
    }

    private func showConsentReminderOnce() {
        let key = "com.voiceflow.desktop.callConsentNoticeShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Voiceflow schreibt ab jetzt deine Teams-Calls mit"
        alert.informativeText = "Erinnerung (einmalig): Sag deinen Gesprächspartnern zu Beginn, dass du eine Mitschrift machst — in der Schweiz ist das Aufzeichnen ohne Wissen der Beteiligten strafbar (Art. 179ter StGB). Die Automatik lässt sich in den Einstellungen unter «Calls» abschalten."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Verstanden")
        alert.runModal()
    }

    // MARK: HUD (non-blocking notice, top-right)

    private var hudWindow: NSPanel?

    private func showHUD(_ title: String, detail: String) {
        hudWindow?.orderOut(nil)
        let view = NSHostingView(rootView: HUDView(title: title, detail: detail))
        let size = view.fittingSize
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 16,
                             y: screen.visibleFrame.maxY - size.height - 16)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = view
        panel.orderFrontRegardless()
        hudWindow = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.hudWindow === panel { self?.hudWindow = nil }
        }
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
            isProcessingDictation = true
            defer { isProcessingDictation = false }
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
                isProcessingDictation = false   // pasted — the next press may start a new dictation

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

        } else if isProcessingDictation {
            // The previous dictation is still being transcribed/pasted. Starting
            // a new recording now produced a second, stray recording.
            NSSound.beep()
            return
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

    func menuBarDidRequestCallToggle() { toggleCallTranscription() }

    /// ✕ in the panel: drop the rescued recording the user doesn't want.
    func menuBarDidRequestRescueDiscard() {
        if let rescued = RescueStore.shared.latest {
            RescueStore.shared.delete(rescued)
        }
        menuBarController?.refreshRescueState()
    }

    func menuBarDidRequestRescueRetry() {
        Task { await retryRescuedDictation() }
    }
}


// MARK: - HUD view

private struct HUDView: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "phone.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.teal.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
