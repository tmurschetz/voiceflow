import AppKit
import AVFoundation

/// In-app functional test that exercises the REAL production pipeline —
/// the same TranscriptionService, ModeProcessor, prompts and wrapDictation
/// logic the app uses live. Run headlessly:
///
///   Voiceflow --selftest [path/to/german-audio.m4a]
///
/// It verifies the v1.0.1 baseline (transcription + Privat/Business cleanup)
/// PLUS the new behaviour (Swiss-German dialect in mode Random) and the
/// conversation guardrails (question/command dictations are rewritten, not
/// answered). Prints a PASS/FAIL report and exits non-zero on any failure.
@MainActor
enum SelfTest {

    /// Re-runs a stored call through the current segmentation + transcription
    /// pipeline (diagnostics; the stored record is NOT modified):
    ///   Voiceflow --reprocess-call <call folder> [--dry] [--out <file>]
    /// --dry: analysis only, no upload (prints chunk statistics).
    static func runReprocessIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--reprocess-call"), args.indices.contains(i + 1) else { return false }
        let folder = URL(fileURLWithPath: args[i + 1])
        let dry = args.contains("--dry")
        let out = args.firstIndex(of: "--out").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        Task { @MainActor in
            let mic = folder.appendingPathComponent("mic.m4a"), sys = folder.appendingPathComponent("system.m4a")
            let t0 = Date()
            if dry {
                let planned = await Task.detached(priority: .utility) { () -> ([(speaker: CallSegmenter.Speaker, start: TimeInterval, end: TimeInterval)], CallSegmenter.Stats) in
                    let r = CallSegmenter.plan(micURL: mic, systemURL: sys); return (r.ranges, r.stats)
                }.value
                let (ranges, st) = planned
                let me = ranges.filter { $0.speaker == .me }.count
                print(String(format: "analysis %.1fs: %d chunks (me %d / other %d) from %d+%d segments, %d trimmed, echo removed %.0fs",
                             Date().timeIntervalSince(t0), ranges.count, me, ranges.count - me,
                             st.micSegments, st.systemSegments, st.trimmed, st.echoRemovedSeconds))
                exit(0)
            }
            let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vf-reprocess-\(UUID().uuidString)")
            let made = await Task.detached(priority: .utility) { () -> ([CallSegmenter.Chunk], CallSegmenter.Stats) in
                let r = CallSegmenter.makeChunksWithStats(micURL: mic, systemURL: sys, workDir: work); return (r.chunks, r.stats)
            }.value
            let (chunks, st) = made
            let tSeg = Date().timeIntervalSince(t0)
            let settings = SettingsService().loadSettings()
            let result = await CallTranscriber().transcribe(chunks: chunks, vocabulary: settings.customVocabulary,
                                                            model: settings.transcribeModel)
            try? FileManager.default.removeItem(at: work)
            print(String(format: "segmentation+export %.1fs, total %.1fs: %d chunks, %d failed, langs %@, echo sentences removed %d, phantoms %d, trimmed %d, echo audio %.0fs",
                         tSeg, Date().timeIntervalSince(t0), result.chunkCount, result.failedChunks,
                         result.languages.joined(separator: ","), result.echoSentencesRemoved,
                         result.phantomPiecesRemoved, st.trimmed, st.echoRemovedSeconds))
            if let out { try? result.transcript.write(toFile: out, atomically: true, encoding: .utf8) }
            else { print(result.transcript) }
            exit(result.transcript.isEmpty ? 1 : 0)
        }
        return true
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest") else { return false }
        let audioPath = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--")
            ? args[i + 1] : nil
        Task { @MainActor in
            let ok = await run(audioPath: audioPath)
            exit(ok ? 0 : 1)
        }
        return true
    }

    // MARK: - Report helpers

    private static var passed = 0
    private static var failed = 0

    private static func check(_ name: String, _ condition: Bool, detail: String = "") {
        if condition { passed += 1; print("  ✅ \(name)") }
        else { failed += 1; print("  ❌ \(name)  \(detail)") }
    }

    /// Swiss-German dialect markers — output containing several of these is
    /// genuine Mundart, not Hochdeutsch.
    private static let dialectMarkers = [
        "wott", "wett", "chum", "chunt", "gah", "goh", " go ", "ufem", " uf ",
        "nöd", "hoi", "zäme", " mer ", "gseh", "händ", "isch", " au ", "abhole",
        " cho ", "büro", "morn", "hüt", " eu ", "säg", "wäg", "scho", " e "
    ]
    private static func dialectScore(_ s: String) -> Int {
        let l = " " + s.lowercased() + " "
        return dialectMarkers.filter { l.contains($0) }.count
    }

    // MARK: - Run

    static func run(audioPath: String?) async -> Bool {
        passed = 0; failed = 0
        print("\n========== Voiceflow Selbsttest  (v\(AppInfo.version) build \(AppInfo.build)) ==========\n")

        // 0. Prerequisite: API key. A freshly built ad-hoc test binary may be
        // denied by the Keychain ACL in headless runs — fall back to the
        // security CLI (in-memory only; the stored item is never touched).
        print("[0] Voraussetzungen")
        if !KeychainStore.hasAPIKey {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", "com.voiceflow.desktop",
                           "-a", "openai_api_key", "-w"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let key = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty { KeychainStore.testOverrideAPIKey = key }
        }
        guard KeychainStore.hasAPIKey else {
            print("  ❌ Kein API-Key im Schlüsselbund — Selbsttest kann nicht laufen.")
            return false
        }
        print("  ✅ API-Key vorhanden (\(KeychainStore.maskedKey))")

        let transcriber = TranscriptionService()
        let processor = ModeProcessor()
        let transcribeModel = TranscribeModel.recommended.id
        let textModel = TextModel.recommended.id

        // 1. Transcription (v1.0.1 baseline) — only if an audio file was given
        print("\n[1] Transkription (\(transcribeModel))")
        if let audioPath, FileManager.default.fileExists(atPath: audioPath) {
            let audio = RecordedAudio(fileURL: URL(fileURLWithPath: audioPath))
            let audioSecs = Int(TranscriptionService.audioDuration(url: audio.fileURL) ?? 0)
            do {
                let started = Date()
                let r = try await transcriber.transcribe(audio: audio, language: .autoDetect, model: transcribeModel)
                let secs = Date().timeIntervalSince(started)
                let preview = r.transcript.count > 300
                    ? String(r.transcript.prefix(300)) + "… [\(r.transcript.count) Zeichen]"
                    : r.transcript
                print("  → \"\(preview)\"  (\(String(format: "%.2f", secs))s für \(audioSecs)s Audio)")
                check("Transkript nicht leer", !r.transcript.trimmingCharacters(in: .whitespaces).isEmpty)
                // Long audio legitimately takes longer — scale the expectation.
                let budget = max(20.0, Double(audioSecs) * 0.5)
                check("Antwortzeit < \(Int(budget))s", secs < budget, detail: "war \(String(format: "%.1f", secs))s")
            } catch {
                check("Transkription erfolgreich", false, detail: "\(error.localizedDescription)")
            }
        } else {
            print("  ⏭  Kein Audio übergeben — Transkription übersprungen (Text-Pipeline wird trotzdem geprüft).")
        }

        // 2. Dictate — ChatGPT-style light cleanup
        print("\n[2] Dictate — leichte Korrektur")
        if let out = await process(processor, "also ähm ich wollte nur kurz sagen dass das projekt äh gut läuft",
                                   mode: .dictate, instruction: "", textModel: textModel) {
            check("Füllwörter entfernt (kein 'ähm'/'äh')", !out.lowercased().contains("ähm") && !out.lowercased().contains(" äh "))
            check("Inhalt erhalten ('Projekt')", out.lowercased().contains("projekt"))
            check("Hochdeutsch (kein Dialekt)", dialectScore(out) <= 1, detail: "score \(dialectScore(out))")
        }

        // 2b. Restraint (2.0): casual real words stay, only hesitation sounds go.
        if let out = await process(processor, "das ist halt quasi ähm so ein bisschen schwierig geworden ehrlich gesagt",
                                   mode: .dictate, instruction: "", textModel: textModel) {
            let low = " " + out.lowercased() + " "
            check("Dezent: 'halt' und 'quasi' bleiben (nur 'ähm' raus)",
                  low.contains(" halt ") && low.contains(" quasi ") && !low.contains("ähm"),
                  detail: "Output: \(out)")
            check("Dezent: 'ehrlich gesagt' bleibt", low.contains("ehrlich gesagt"), detail: "Output: \(out)")
        }

        // 3. Dictate must NEVER change the form of address (1.1 fix).
        print("\n[3] Dictate — Anrede bleibt wie gesprochen")
        if let out = await process(processor, "kannst du mir bitte die unterlagen bis morgen mittag schicken danke dir",
                                   mode: .dictate, instruction: "", textModel: textModel) {
            let low = " " + out.lowercased() + " "
            let keptDu = low.contains(" du ") || low.contains(" dir") || low.contains(" dich")
            let forcedSie = low.contains("ihnen") || low.contains("können sie") || low.contains("könnten sie")
            check("'du' bleibt 'du' (keine Sie-Form)", keptDu && !forcedSie, detail: "Output: \(out)")
            check("Kein 'ß' (Schweizer Schreibweise)", !out.contains("ß"))
        }

        // 4. Guardrail — a QUESTION must be cleaned up, not answered (v1.0.4 fix)
        print("\n[4] Schutzregel — Frage wird bereinigt, nicht beantwortet")
        if let out = await process(processor, "wie spät ist es eigentlich gerade",
                                   mode: .dictate, instruction: "", textModel: textModel) {
            check("Bleibt eine Frage (enthält '?')", out.contains("?"))
            check("Enthält noch 'spät' (nicht beantwortet)", out.lowercased().contains("spät"),
                  detail: "Output: \(out)")
        }

        // 5. Guardrail — a COMMAND must be cleaned up, not executed (v1.0.4 fix)
        print("\n[5] Schutzregel — Befehl wird bereinigt, nicht ausgeführt")
        if let out = await process(processor, "mach mir eine liste mit drei punkten für das meeting",
                                   mode: .dictate, instruction: "", textModel: textModel) {
            let looksLikeList = out.contains("\n1.") || out.contains("\n- ") || out.contains("•") || out.contains("\n2.")
            check("Keine generierte Liste", !looksLikeList, detail: "Output: \(out.replacingOccurrences(of: "\n", with: "⏎"))")
            check("Enthält noch 'Liste' (Wortlaut erhalten)", out.lowercased().contains("liste"))
        }

        // 6. Dictate with a custom instruction still transforms (never answers).
        print("\n[6] Dictate — eigene Instruktion wird befolgt")
        if let out = await process(processor, "bitte schick mir die unterlagen bis morgen mittag",
                                   mode: .dictate, instruction: "Translate the text to English.", textModel: textModel) {
            let looksEnglish = out.lowercased().contains("the ") || out.lowercased().contains("please") || out.lowercased().contains("documents")
            check("Instruktion angewendet (Englisch)", looksEnglish, detail: "Output: \(out)")
        }

        // 11. Empty-recording guard — must be detected locally, before any upload.
        print("\n[11] Leere/zu kurze Aufnahme wird lokal erkannt (kein Upload, keine Rettung)")
        check("Leere Daten (500 B) → als leer erkannt",
              TranscriptionService.isEmptyRecording(data: Data(count: 500),
                                                    url: URL(fileURLWithPath: "/dev/null")))
        if let audioPath, let realData = try? Data(contentsOf: URL(fileURLWithPath: audioPath)) {
            check("Echte Aufnahme → NICHT als leer erkannt",
                  !TranscriptionService.isEmptyRecording(data: realData,
                                                        url: URL(fileURLWithPath: audioPath)))
        }

        // 12. v1.1 quality: default model + recognition-prompt / vocabulary logic.
        print("\n[12] Standardmodell & Erkennungs-Prompt (v1.1)")
        check("Standard-Transkriptionsmodell = gpt-transcribe",
              TranscribeModel.recommended.id == "gpt-transcribe",
              detail: "ist \(TranscribeModel.recommended.id)")
        check("Wörterbuch → keywords-Zeile (eine Zeile, ohne < >)",
              TranscriptionService.keywordsLine("Murschetz\n<b>RLS</b>\r\nVelafrica") == "Murschetz, bRLS/b, Velafrica")

        let pDE = TranscriptionService.recognitionPrompt(for: .manual(.german), vocabulary: "")
        check("Deutsch-Prompt enthält Formatierungshinweis", pDE.contains("Interpunktion"))

        let pAuto = TranscriptionService.recognitionPrompt(for: .autoDetect, vocabulary: "")
        check("Auto-Erkennung ohne Vokabular → kein Prompt (kein Sprach-Bias)",
              pAuto.isEmpty, detail: "war \"\(pAuto)\"")

        let pVocab = TranscriptionService.recognitionPrompt(for: .manual(.german),
                                                            vocabulary: "Murschetz\nVoiceflow")
        check("Vokabular eingebettet & Zeilen→Kommas",
              pVocab.contains("Murschetz, Voiceflow"), detail: pVocab)

        let pAutoVocab = TranscriptionService.recognitionPrompt(for: .autoDetect, vocabulary: "Zürich")
        check("Auto-Erkennung mit Vokabular → nur Begriffe", pAutoVocab == "Zürich",
              detail: "war \"\(pAutoVocab)\"")

        let pCap = TranscriptionService.recognitionPrompt(for: .manual(.german),
                                                          vocabulary: String(repeating: "x", count: 1000))
        check("Vokabular auf ~480 Zeichen gekappt",
              pCap.filter { $0 == "x" }.count <= 480,
              detail: "\(pCap.filter { $0 == "x" }.count) x-Zeichen")

        // 13. Auto-update version comparison (v1.1, GitHub-releases updater).
        print("\n[13] Auto-Update — Versionsvergleich")
        check("1.1.0 > 1.0.6", UpdateService.compareVersions("1.1.0", "1.0.6") == 1)
        check("v-Präfix toleriert (v1.2.0 > 1.1.0)", UpdateService.compareVersions("v1.2.0", "1.1.0") == 1)
        check("Gleiche Version → 0", UpdateService.compareVersions("1.1.0", "1.1.0") == 0)
        check("Ältere erkannt (1.0.6 < 1.1.0)", UpdateService.compareVersions("1.0.6", "1.1.0") == -1)

        // 14. Managed accounts — pure logic (network paths are covered by the
        // separate --accounttest E2E against a local service).
        print("\n[14] Verwalteter Zugang — Logik")
        let t1 = AccountService.generateDeviceToken()
        let t2 = AccountService.generateDeviceToken()
        check("Gerätetoken = 64 Hex-Zeichen",
              t1.count == 64 && t1.allSatisfy { "0123456789abcdef".contains($0) })
        check("Gerätetokens einzigartig", t1 != t2)

        let fixture = #"{"status":"approved","apiKey":"sk-test-abc"}"#.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(AccountService.StatusResponse.self, from: fixture)
        check("Status-Antwort dekodierbar", decoded?.apiKey == "sk-test-abc")

        let machine = await MainActor.run { () -> [Bool] in
            var memToken: String? = "x"
            var memKey: String?
            let store = AccountService.Store(
                getDeviceToken: { memToken }, setDeviceToken: { memToken = $0 },
                installAPIKey: { memKey = $0 }, removeAPIKey: { memKey = nil },
                hasAPIKey: { memKey != nil })
            let d = UserDefaults.standard
            let m0 = d.bool(forKey: AccountService.managedFlagKey)
            let p0 = d.bool(forKey: AccountService.pendingFlagKey)
            defer {
                d.set(m0, forKey: AccountService.managedFlagKey)
                d.set(p0, forKey: AccountService.pendingFlagKey)
            }
            let s = AccountService(store: store, baseURL: { "http://invalid.local" })
            s.apply(.init(status: "pending", apiKey: nil))
            let r1 = s.phase == .pending
            s.apply(.init(status: "approved", apiKey: "sk-test-xyz"))
            let r2 = s.phase == .active && memKey == "sk-test-xyz"
            s.apply(.init(status: "revoked", apiKey: nil))
            let r3 = s.phase == .revoked && memKey == nil
            return [r1, r2, r3]
        }
        check("pending → wartend", machine[0])
        check("approved + Key → aktiv, Key installiert", machine[1])
        check("revoked → Key lokal entfernt (Kill-Switch)", machine[2])

        // 15. Recorder settings must be encoder-valid (the v1.1 pre-release bug:
        // 24 kHz + 96 kbps was outside Apple's allowed AAC range, so recording
        // never started). prepareToRecord() validates without touching the mic.
        print("\n[15] Aufnahme-Einstellungen vom Encoder akzeptiert")
        func recorderPrepares(_ settings: [String: Any], file: String, label: String) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "selftest-\(file).m4a")
            let prepared = (try? AVAudioRecorder(url: url, settings: settings))?.prepareToRecord() ?? false
            try? FileManager.default.removeItem(at: url)
            check("\(label) gültig", prepared)
        }
        recorderPrepares(RecordingService.preferredRecorderSettings,
                         file: "preferred", label: "Bevorzugt (32 kHz, 96 kbps)")
        recorderPrepares(RecordingService.fallbackRecorderSettings,
                         file: "fallback", label: "Rückfall (16 kHz, 32 kbps)")

        // 16. Long-recording support (v1.1.1) — timeouts scale, models route,
        // truncation is caught. Pure logic; the network path is exercised by
        // running --selftest with a long audio file.
        print("\n[16] Lange Aufnahmen — Timeouts, Routing, Kürzungs-Schutz")
        check("Kurzes Audio → knackiges Timeout (30s)",
              OpenAIClient.transcribeTimeout(forAudioSeconds: 10) == 30)
        check("20-Min-Audio → grosszügiges Timeout (600s)",
              OpenAIClient.transcribeTimeout(forAudioSeconds: 1200) == 600)
        check("Chat-Timeout skaliert mit Textlänge",
              OpenAIClient.chatTimeout(forInputChars: 100) == 30
              && OpenAIClient.chatTimeout(forInputChars: 20_000) == 300)
        check("≤23 Min bleibt gpt-4o-transcribe",
              TranscriptionService.effectiveModel(requested: "gpt-4o-transcribe", audioSeconds: 1200) == "gpt-4o-transcribe")
        check(">23 Min → whisper-1 (4o-Limit ist 25 Min)",
              TranscriptionService.effectiveModel(requested: "gpt-4o-transcribe", audioSeconds: 1500) == "whisper-1")
        check("Dauer-Fehlermeldung löst Whisper-Fallback aus",
              OpenAIClient.isModelOrDurationIssue("audio duration 1560 seconds is longer than 1500 seconds maximum")
              && !OpenAIClient.isModelOrDurationIssue("invalid api key"))
        check("Langtext-Veredelung wechselt auf gpt-4o",
              ModeProcessor.effectiveTextModel(requested: "gpt-4o-mini", inputChars: 9_000) == "gpt-4o"
              && ModeProcessor.effectiveTextModel(requested: "gpt-4o-mini", inputChars: 500) == "gpt-4o-mini")
        let longRaw = String(repeating: "wort ", count: 600)   // 3000 Zeichen
        check("Kürzung erkannt (3000→1200 Zeichen bei Privat)",
              ModeProcessor.looksTruncated(raw: longRaw, polished: String(longRaw.prefix(1200)),
                                           mode: .dictate, instruction: ""))
        check("Normale Bereinigung nicht als Kürzung gewertet",
              !ModeProcessor.looksTruncated(raw: longRaw, polished: String(longRaw.prefix(2400)),
                                            mode: .dictate, instruction: ""))
        check("Kurze Diktate nie als Kürzung gewertet",
              !ModeProcessor.looksTruncated(raw: "kurzer satz", polished: "Satz.",
                                            mode: .dictate, instruction: ""))

        // 17. Faithful cleanup (v1.1.2): gpt-4o default, qualifiers survive,
        // mishearings get fixed via context + dictionary, and the
        // voice-processing bitrates are encoder-valid for every plausible rate.
        print("\n[17] Treue-Politur & Sprachverarbeitung (v1.1.2)")
        check("Standard-Textmodell = gpt-4o", TextModel.recommended.id == "gpt-4o",
              detail: "ist \(TextModel.recommended.id)")

        if let out = await process(processor, "ich bin weiterhin eigentlich fast zufrieden mit dem stand vom projekt",
                                   mode: .dictate, instruction: "", textModel: textModel) {
            let low = out.lowercased()
            check("Qualifizierer überleben (weiterhin/eigentlich/fast)",
                  low.contains("weiterhin") && low.contains("eigentlich") && low.contains("fast"),
                  detail: "Output: \(out)")
        }

        if let out = await process(processor, "das protokoll geht an thomas mörschetz und das birgley meeting ist morgen",
                                   mode: .dictate, instruction: "", textModel: textModel,
                                   vocabulary: "Murschetz, Budget-Meeting, Voiceflow") {
            check("Verhörer via Wörterbuch korrigiert (Mörschetz → Murschetz)",
                  out.contains("Murschetz"), detail: "Output: \(out)")
        }

        // ß → ss (v1.1.2): whisper emits Germany orthography; the strict
        // letter-fidelity rules blocked the model from converting, so the
        // conversion is deterministic in code now. Real-world fixture "weißt".
        if let out = await process(processor, "du weißt dass das Projekt groß ist und so heißt",
                                   mode: .dictate, instruction: "", textModel: textModel) {
            check("ß wird zu ss (weißt→weisst, groß→gross)",
                  !out.contains("ß") && out.lowercased().contains("weisst") && out.lowercased().contains("gross"),
                  detail: "Output: \(out)")
        }
        check("swissNormalize deterministisch",
              ModeProcessor.swissNormalize("Du weißt, es ist groß.", mode: .dictate, instruction: "")
                  == "Du weisst, es ist gross.")
        check("Instruktion mit ß deaktiviert die Umwandlung",
              ModeProcessor.swissNormalize("groß", mode: .dictate, instruction: "bitte mit ß schreiben")
                  == "groß")

        // Prompt-echo guard — real-world fixture from 2026-08-13: silent audio
        // made the recogniser "transcribe" the user's dictionary verbatim.
        let vocabFixture = "isolutions, RLS, Row Level Security, SCD, Slowly Changing Dimensions, RACI Matrix, Velafrica"
        check("Wörterbuch-Echo wird abgefangen",
              TranscriptionService.looksLikePromptEcho(
                  transcript: "isolutions, RLS, Row Level Security, SCD, Slowly Changing Dimensions, RACI Matrix, Velafrica",
                  vocabulary: vocabFixture))
        check("»context:« wird abgefangen",
              TranscriptionService.looksLikePromptEcho(transcript: "context:", vocabulary: vocabFixture))
        check("Echter Satz MIT Wörterbuch-Begriffen passiert",
              !TranscriptionService.looksLikePromptEcho(
                  transcript: "Bitte prüfe die RACI Matrix für das Projekt mit isolutions und melde dich bei mir, danke.",
                  vocabulary: vocabFixture))
        check("Kurzes normales Diktat passiert",
              !TranscriptionService.looksLikePromptEcho(transcript: "Danke, passt für mich.", vocabulary: vocabFixture))

        var vpAllValid = true
        for rate in [48_000.0, 44_100.0, 32_000.0, 24_000.0, 16_000.0] {
            let s: [String: Any] = [
                AVFormatIDKey:         Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey:       rate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey:   RecordingService.vpBitrate(forSampleRate: rate)
            ]
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "selftest-vp-\(Int(rate)).m4a")
            let ok = (try? AVAudioRecorder(url: url, settings: s))?.prepareToRecord() ?? false
            try? FileManager.default.removeItem(at: url)
            if !ok { vpAllValid = false }
        }
        check("VP-Bitraten für alle Sample-Raten encoder-gültig", vpAllValid)

        // 18. Transcribe mode (2.0) — pure logic: speaker segmentation on
        // synthetic two-track audio, Teams debounce, participant guess, export text.
        print("\n[18] Transcribe — Sprecher-Trennung, Teams-Erkennung, Export")
        do {
            // Synthetic call: me 0–2 s and 6–8 s, other side 3–5 s (tone bursts at 16 kHz).
            func tone(seconds: Double, bursts: [(Double, Double)], url: URL) throws {
                let rate = 16_000.0
                let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
                let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: rate,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let n = AVAudioFrameCount(seconds * rate)
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
                buf.frameLength = n
                for i in 0..<Int(n) {
                    let t = Double(i) / rate
                    let active = bursts.contains { t >= $0.0 && t < $0.1 }
                    buf.floatChannelData![0][i] = active ? Float(sin(2 * .pi * 220 * t)) * 0.3 : 0
                }
                try file.write(from: buf)
            }
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vf-segtest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let mic = dir.appendingPathComponent("mic.m4a"), sys = dir.appendingPathComponent("system.m4a")
            try tone(seconds: 9, bursts: [(0, 2), (6, 8)], url: mic)
            try tone(seconds: 9, bursts: [(3, 5)], url: sys)
            let chunks = CallSegmenter.makeChunks(micURL: mic, systemURL: sys, workDir: dir.appendingPathComponent("chunks"))
            let pattern = chunks.map { $0.speaker == .me ? "me" : "other" }.joined(separator: ",")
            check("Zwei Spuren → drei Sprecherwechsel in Reihenfolge (me,other,me)", pattern == "me,other,me",
                  detail: "war \(pattern) (\(chunks.count) Chunks)")
            if chunks.count == 3 {
                check("Zeitstempel plausibel (Gegenseite startet ≈3 s)", abs(chunks[1].start - 3.0) < 0.6,
                      detail: String(format: "start %.2f", chunks[1].start))
                let exported = chunks.allSatisfy { ((try? Data(contentsOf: $0.fileURL))?.count ?? 0) > 1200 }
                check("Chunk-Dateien exportiert", exported)
            }
            // Echo: the far side (220 Hz) leaks into the mic at 60 %, 100 ms late;
            // own speech (330 Hz) at 0–2 s and 6–8 s. Echo must not become "Du".
            func track(seconds: Double, parts: [(Double, Double, Float, Double)], url: URL) throws {
                let rate = 16_000.0
                let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
                let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: rate,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let n = AVAudioFrameCount(seconds * rate)
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
                buf.frameLength = n
                for i in 0..<Int(n) {
                    let t = Double(i) / rate
                    var v: Float = 0
                    for p in parts where t >= p.0 && t < p.1 { v += p.2 * Float(sin(2 * .pi * p.3 * t)) }
                    buf.floatChannelData![0][i] = v
                }
                try file.write(from: buf)
            }
            let echoMic = dir.appendingPathComponent("echo-mic.m4a"), echoSys = dir.appendingPathComponent("echo-sys.m4a")
            try track(seconds: 16, parts: [(0, 2, 0.3, 330), (6, 8, 0.3, 330), (3.1, 5.1, 0.18, 220), (10.1, 14.1, 0.18, 220)], url: echoMic)
            try track(seconds: 16, parts: [(3, 5, 0.3, 220), (10, 14, 0.3, 220)], url: echoSys)
            let plan = CallSegmenter.plan(micURL: echoMic, systemURL: echoSys)
            let echoPattern = plan.ranges.map { $0.speaker == .me ? "me" : "other" }.joined(separator: ",")
            check("Echo der Gegenseite im Mikrofon wird nicht «Du» (me,other,me,other)",
                  echoPattern == "me,other,me,other", detail: "war \(echoPattern)")
            try? FileManager.default.removeItem(at: dir)
        } catch {
            check("Synthetisches Call-Audio erzeugt", false, detail: error.localizedDescription)
        }

        var deb = TeamsCallDetector.Debouncer(startAfter: 3, stopAfter: 4)
        var fired: [TeamsCallDetector.Debouncer.Decision] = []
        for active in [true, true, true, true] { fired.append(deb.tick(callActive: active, recording: false)) }
        check("Teams-Start nach 3 stabilen Polls, nicht früher, nicht doppelt",
              fired == [.none, .none, .start, .none])
        var stopDeb = TeamsCallDetector.Debouncer(startAfter: 3, stopAfter: 4)
        var stops: [TeamsCallDetector.Debouncer.Decision] = []
        for active in [false, true, false, false, false, false] { stops.append(stopDeb.tick(callActive: active, recording: true)) }
        check("Teams-Stop erst nach 4 ruhigen Polls (ein Aussetzer stoppt nicht)",
              stops == [.none, .none, .none, .none, .none, .stop])
        check("Teilnehmer-Erkennung aus Teams-Fenstertiteln (altes Format)",
              TeamsCallDetector.participantGuess(from: ["Chat | Microsoft Teams", "Thomas Boli | Microsoft Teams", "Kalender | Microsoft Teams"]) == "Thomas Boli")

        // Build 34: new Teams title format "Area | Name | Tenant | account" (real titles).
        let acct = " | ISOLUTIONS AG | someone@example.ch"
        let realTitles: Set<String> = [
            "Calendar" + acct, "Chat | Nicolas Durville" + acct, "CX Circle - November edition" + acct,
            "Meeting compact view | Bi-Weekly TST Mentoring || NDU - TMU" + acct,
            "Bi-Weekly TST Mentoring || NDU - TMU" + acct, "Sharing control bar" + acct + " | Pinned window"]
        let guess = TeamsCallDetector.participantGuess(from: realTitles)
        check("Teilnehmer: Meeting-Fenster statt «Calendar» (neues Teams-Format)",
              guess == "Bi-Weekly TST Mentoring || NDU - TMU", detail: "war \(guess ?? "nil")")
        let oneToOne = TeamsCallDetector.participantGuess(
            from: ["CX Circle - November edition" + acct, "Thomas F. x Tom" + acct, "Calendar" + acct],
            newAtStart: ["Thomas F. x Tom" + acct])
        check("Teilnehmer: beim Call-Start neu geöffnetes Fenster gewinnt", oneToOne == "Thomas F. x Tom",
              detail: "war \(oneToOne ?? "nil")")
        check("Nur generische Fenster → kein Teilnehmer",
              TeamsCallDetector.participantGuess(from: ["Calendar" + acct, "Activity" + acct]) == nil)
        check("Teams-Hilfsprozesse zählen für die Call-Erkennung",
              TeamsCallDetector.isTeamsBundle("com.microsoft.teams2.helper")
              && TeamsCallDetector.isTeamsBundle("com.microsoft.teams2.modulehost")
              && !TeamsCallDetector.isTeamsBundle("com.microsoft.edgemac"))

        // Segmentation logic on plain segments.
        typealias Seg = CallSegmenter.Segment
        let sys = [Seg(speaker: .other, start: 100, end: 200)]
        let micSegs = [Seg(speaker: .me, start: 10, end: 20), Seg(speaker: .me, start: 90, end: 95),
                       Seg(speaker: .me, start: 250, end: 260)]
        let trimmed = CallSegmenter.trimToCall(mic: micSegs, system: sys)
        check("Vor/nach dem Call: nur Mikrofon → abgeschnitten (Rand 20 s bleibt)",
              trimmed.count == 1 && trimmed[0].start == 90, detail: "war \(trimmed.map(\.start))")
        let turns = CallSegmenter.chunkRanges([Seg(speaker: .me, start: 0, end: 10),
                                               Seg(speaker: .other, start: 10.5, end: 11.2),
                                               Seg(speaker: .me, start: 11.5, end: 20)])
        check("Kurzer Einwurf («ja») teilt den Redebeitrag nicht",
              turns.count == 1 && turns[0].speaker == .me && turns[0].end == 20, detail: "war \(turns.count) Chunks")

        // Text safety nets.
        let echoed = [
            CallTranscriber.Piece(speaker: .other, start: 10, end: 20,
                                  text: "Ja, ich denke mehr, weisst du auch in deiner Rolle als AM natürlich, dass du einfach unterwegs bist."),
            CallTranscriber.Piece(speaker: .me, start: 12, end: 25,
                                  text: "Ja, ich denke mehr auch in deiner Rolle als AM natürlich, dass du einfach unterwegs bist. Ich habe cool gefunden, dass mich die Leute schon gefragt haben.")]
        let (dedup, removedEcho) = CallTranscriber.removeEchoSentences(echoed)
        let mine = dedup.first { $0.speaker == .me }?.text ?? ""
        check("Echo-Satz auf deiner Seite entfernt, eigener Satz bleibt",
              removedEcho == 1 && mine.hasPrefix("Ich habe cool gefunden"), detail: "Du: \(mine)")
        check("Phantom-Zeilen erkannt («ChatGPT.», «Yo, I'll be outside.»), echte bleiben",
              CallTranscriber.isPhantom("ChatGPT.") && CallTranscriber.isPhantom("Yo, I'll be outside.")
              && !CallTranscriber.isPhantom("Ja, genau.") && !CallTranscriber.isPhantom("Thank you."))
        check("Auto-Spracherkennung auf Deutsch/Englisch begrenzt",
              TranscriptionService.autoDetectLanguages == ["de", "en"])
        let rec = CallStore.Record(id: "t", start: Date(timeIntervalSince1970: 1_700_000_000),
                                   end: Date(timeIntervalSince1970: 1_700_000_240), source: "manual",
                                   participant: "Reto Muster", languages: ["de"], status: "done",
                                   transcript: "[00:00] Du:\nHallo.")
        let export = CallStore.exportText(rec)
        check("Export-Text mit Kopfzeile (Datum, Zeit, Teilnehmer)",
              export.contains("Teilnehmer: Reto Muster") && export.contains("(4 Min)") && export.hasSuffix("Hallo."))
        check("Zeitstempel-Format", CallTranscriber.stamp(65) == "01:05" && CallTranscriber.stamp(3725) == "1:02:05")

        // Summary
        print("\n========== Ergebnis: \(passed) bestanden, \(failed) fehlgeschlagen ==========\n")
        return failed == 0
    }

    /// Runs one ModeProcessor pass and prints the output; returns the text or nil on error.
    private static func process(_ processor: ModeProcessor, _ input: String,
                                mode: ProcessingMode, instruction: String, textModel: String,
                                vocabulary: String = "") async -> String? {
        do {
            let r = try await processor.process(text: input, mode: mode,
                                                userInstruction: instruction, textModel: textModel,
                                                vocabulary: vocabulary)
            print("  in : \"\(input)\"")
            print("  out: \"\(r.text)\"")
            if r.usedFallback { print("  ⚠️  Fallback auf Rohtext (KI nicht erreichbar)") }
            return r.text
        } catch {
            check("\(mode.displayName) verarbeitet", false, detail: error.localizedDescription)
            return nil
        }
    }
}
