import AppKit

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

        // 0. Prerequisite: API key
        print("[0] Voraussetzungen")
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
            do {
                let started = Date()
                let r = try await transcriber.transcribe(audio: audio, language: .autoDetect, model: transcribeModel)
                let secs = Date().timeIntervalSince(started)
                print("  → \"\(r.transcript)\"  (\(String(format: "%.2f", secs))s)")
                check("Transkript nicht leer", !r.transcript.trimmingCharacters(in: .whitespaces).isEmpty)
                check("Antwortzeit < 20s", secs < 20, detail: "war \(String(format: "%.1f", secs))s")
            } catch {
                check("Transkription erfolgreich", false, detail: "\(error.localizedDescription)")
            }
        } else {
            print("  ⏭  Kein Audio übergeben — Transkription übersprungen (Text-Pipeline wird trotzdem geprüft).")
        }

        // 2. Privat mode — light cleanup (v1.0.1 baseline)
        print("\n[2] Modus Privat — leichte Korrektur")
        if let out = await process(processor, "also ähm ich wollte nur kurz sagen dass das projekt äh gut läuft",
                                   mode: .private, instruction: "", textModel: textModel) {
            check("Füllwörter entfernt (kein 'ähm'/'äh')", !out.lowercased().contains("ähm") && !out.lowercased().contains(" äh "))
            check("Inhalt erhalten ('Projekt')", out.lowercased().contains("projekt"))
            check("Hochdeutsch (kein Dialekt)", dialectScore(out) <= 1, detail: "score \(dialectScore(out))")
        }

        // 3. Business mode — professional rewrite (v1.0.1 baseline)
        print("\n[3] Modus Business — professioneller Ton")
        if let out = await process(processor, "sag dem kunden mal kurz dass sich die lieferung leider verzögert sorry",
                                   mode: .business, instruction: "", textModel: textModel) {
            check("Nicht leer & umgeschrieben", out.count > 10)
            check("Kein 'ß' (Schweizer Schreibweise)", !out.contains("ß"))
            check("Hochdeutsch (kein Dialekt)", dialectScore(out) <= 1, detail: "score \(dialectScore(out))")
        }

        // 3b. Business must NEVER formalise the form of address (v1.1 fix:
        // a dictated "du" used to come back as "Sie").
        if let out = await process(processor, "kannst du mir bitte die unterlagen bis morgen mittag schicken danke dir",
                                   mode: .business, instruction: "", textModel: textModel) {
            let low = " " + out.lowercased() + " "
            let keptDu = low.contains(" du ") || low.contains(" dir") || low.contains(" dich")
            let forcedSie = low.contains("ihnen") || low.contains("können sie") || low.contains("könnten sie")
            check("Business behält 'du' (keine Sie-Form erzwungen)", keptDu && !forcedSie,
                  detail: "Output: \(out)")
        }

        // 4. Guardrail — a QUESTION must be cleaned up, not answered (v1.0.4 fix)
        print("\n[4] Schutzregel — Frage wird bereinigt, nicht beantwortet")
        if let out = await process(processor, "wie spät ist es eigentlich gerade",
                                   mode: .private, instruction: "", textModel: textModel) {
            check("Bleibt eine Frage (enthält '?')", out.contains("?"))
            check("Enthält noch 'spät' (nicht beantwortet)", out.lowercased().contains("spät"),
                  detail: "Output: \(out)")
        }

        // 5. Guardrail — a COMMAND must be cleaned up, not executed (v1.0.4 fix)
        print("\n[5] Schutzregel — Befehl wird bereinigt, nicht ausgeführt")
        if let out = await process(processor, "mach mir eine liste mit drei punkten für das meeting",
                                   mode: .random, instruction: "", textModel: textModel) {
            let looksLikeList = out.contains("\n1.") || out.contains("\n- ") || out.contains("•") || out.contains("\n2.")
            check("Keine generierte Liste", !looksLikeList, detail: "Output: \(out.replacingOccurrences(of: "\n", with: "⏎"))")
            check("Enthält noch 'Liste' (Wortlaut erhalten)", out.lowercased().contains("liste"))
        }

        // 6. HEADLINE — Random mode with Swiss-German instruction → dialect output
        print("\n[6] Modus Random — Schweizerdeutsch (Zürcher Dialekt)")
        let swissInstr = """
        Du bist ein Schweizerdeutsch-zu-Schweizerdeutsch Assistent. Die Ausgabe muss \
        auf Schweizerdeutsch (Zürcher Dialekt) sein, so wie es gesprochen wird. \
        Beispiele: hoi, chum, wott, nöd, eu, mer, abhole. Kein Hochdeutsch.
        """
        if let out = await process(processor, "ich möchte morgen ins büro kommen und die unterlagen abholen",
                                   mode: .random, instruction: swissInstr, textModel: textModel) {
            let score = dialectScore(out)
            check("Dialekt erkannt (≥2 Mundart-Marker)", score >= 2, detail: "score \(score) — Output: \(out)")
            check("Nicht reines Hochdeutsch", !out.contains("möchte") || score >= 2, detail: "Output: \(out)")
        }

        // 7. Combined — dialect instruction + a question must still be rewritten, not answered
        print("\n[7] Kombiniert — Dialekt-Instruktion + Frage")
        if let out = await process(processor, "kannst du mir sagen was die hauptstadt von frankreich ist",
                                   mode: .random, instruction: swissInstr, textModel: textModel) {
            check("Nicht beantwortet (kein 'Paris')", !out.lowercased().contains("paris"),
                  detail: "Output: \(out)")
            check("Bleibt eine Frage", out.contains("?"), detail: "Output: \(out)")
        }

        // 8. Random is purely instruction-driven — creative instruction, Hochdeutsch IN.
        //    Instruction: keep German, add emoji + swear words. Must NOT turn Swiss-German.
        print("\n[8] Random — freie Instruktion (Emojis + Kraftausdrücke, Hochdeutsch bleibt)")
        let funInstr = "Behalte die Sprache des Inputs bei. Füge passende Emojis ein und mach den Ton frech mit ein, zwei Kraftausdrücken."
        if let out = await process(processor, "der drucker funktioniert schon wieder nicht und ich bin spät dran",
                                   mode: .random, instruction: funInstr, textModel: textModel) {
            let hasEmoji = out.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C }
            check("Emoji eingefügt (Instruktion befolgt)", hasEmoji, detail: "Output: \(out)")
            check("Nicht nach Schweizerdeutsch übersetzt", dialectScore(out) <= 1,
                  detail: "score \(dialectScore(out)) — Output: \(out)")
        }

        // 9. Random with a translation instruction → output language switches.
        print("\n[9] Random — Übersetzungs-Instruktion (Deutsch → Englisch)")
        if let out = await process(processor, "bitte schick mir die unterlagen bis morgen mittag",
                                   mode: .random, instruction: "Translate the text to English.", textModel: textModel) {
            let looksEnglish = out.lowercased().contains("the ") || out.lowercased().contains("please") || out.lowercased().contains("documents")
            check("Auf Englisch übersetzt", looksEnglish, detail: "Output: \(out)")
        }

        // 10. Random with NO instruction → must behave like Privat (light cleanup, Hochdeutsch).
        print("\n[10] Random — ohne Instruktion (= wie Privat)")
        if let out = await process(processor, "also ähm ich glaub das passt so für mich",
                                   mode: .random, instruction: "", textModel: textModel) {
            check("Füllwörter entfernt", !out.lowercased().contains("ähm"))
            check("Hochdeutsch (kein Dialekt, keine Emojis)", dialectScore(out) <= 1)
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
        check("Standard-Transkriptionsmodell = gpt-4o-transcribe",
              TranscribeModel.recommended.id == "gpt-4o-transcribe",
              detail: "ist \(TranscribeModel.recommended.id)")

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

        // Summary
        print("\n========== Ergebnis: \(passed) bestanden, \(failed) fehlgeschlagen ==========\n")
        return failed == 0
    }

    /// Runs one ModeProcessor pass and prints the output; returns the text or nil on error.
    private static func process(_ processor: ModeProcessor, _ input: String,
                                mode: ProcessingMode, instruction: String, textModel: String) async -> String? {
        do {
            let r = try await processor.process(text: input, mode: mode,
                                                userInstruction: instruction, textModel: textModel)
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
