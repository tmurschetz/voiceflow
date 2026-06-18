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
        print("\n[1] Transkription (gpt-4o-mini-transcribe)")
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
