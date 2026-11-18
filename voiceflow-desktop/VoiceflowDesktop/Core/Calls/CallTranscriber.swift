import Foundation

/// Transcribes the speaker-labelled chunks of a call (CallSegmenter) with the
/// regular TranscriptionService — gpt-transcribe restricted to German/English,
/// dictionary as keywords — and assembles a readable, time-stamped transcript.
/// No rewrite/cleanup step: call transcripts stay verbatim.
///
/// Safety nets after transcription (build 34):
/// - phantom lines that the recogniser invents on near-silence are dropped;
/// - sentences on YOUR side that repeat what the other side said at the same
///   moment are dropped — echo the per-window audio filter let through.
final class CallTranscriber {

    struct Output {
        let transcript: String
        let languages: [String]
        let chunkCount: Int
        let failedChunks: Int
        var echoSentencesRemoved = 0
        var phantomPiecesRemoved = 0
    }

    private let service = TranscriptionService()
    private let maxParallel = 4

    func transcribe(chunks: [CallSegmenter.Chunk], vocabulary: String,
                    model: String = TranscribeModel.recommended.id,
                    progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Output {
        var texts: [Int: (text: String, locale: String)] = [:]
        var failed = 0
        var done = 0

        // Bounded concurrency: `maxParallel` requests in flight.
        var iterator = chunks.enumerated().makeIterator()
        await withTaskGroup(of: (Int, String?, String?).self) { group in
            func addNext() {
                guard let (i, chunk) = iterator.next() else { return }
                group.addTask(priority: .utility) { [service] in
                    do {
                        let r = try await service.transcribe(audio: RecordedAudio(fileURL: chunk.fileURL),
                                                             language: .autoDetect, model: model,
                                                             vocabulary: vocabulary)
                        return (i, r.transcript, r.usedLocale)
                    } catch {
                        // No speech in this chunk (breathing, keyboard) is normal — skip quietly.
                        if case TranscriptionError.noSpeech = error { return (i, "", nil) }
                        if case TranscriptionError.emptyTranscript = error { return (i, "", nil) }
                        NSLog("[VF-Call] chunk %d failed: %@", i, String(describing: error))
                        return (i, nil, nil)
                    }
                }
            }
            for _ in 0..<maxParallel { addNext() }
            for await (i, text, locale) in group {
                done += 1
                progress?(done, chunks.count)
                if let text { texts[i] = (text.trimmingCharacters(in: .whitespacesAndNewlines), locale ?? "") }
                else { failed += 1 }
                addNext()
            }
        }

        var pieces: [Piece] = chunks.indices.compactMap { i in
            guard let t = texts[i], !t.text.isEmpty else { return nil }
            return Piece(speaker: chunks[i].speaker, start: chunks[i].start, end: chunks[i].end,
                         text: t.text, locale: t.locale)
        }
        let before = pieces.count
        pieces.removeAll { Self.isPhantom($0.text) }
        let phantoms = before - pieces.count
        let (deduped, echoRemoved) = Self.removeEchoSentences(pieces)

        let langs = Array(Set(deduped.flatMap { $0.locale.split(separator: "+").map(String.init) }
            .filter { !$0.isEmpty && $0 != "auto" })).sorted()
        var out = Output(transcript: Self.assemble(deduped), languages: langs,
                         chunkCount: chunks.count, failedChunks: failed)
        out.echoSentencesRemoved = echoRemoved
        out.phantomPiecesRemoved = phantoms
        return out
    }

    // MARK: - Assembly

    struct Piece {
        let speaker: CallSegmenter.Speaker
        let start: TimeInterval
        let end: TimeInterval
        var text: String
        var locale: String = ""
    }

    static func assemble(_ pieces: [Piece]) -> String {
        var lines: [String] = []
        var lastSpeaker: CallSegmenter.Speaker? = nil
        for p in pieces.sorted(by: { $0.start < $1.start }) where !p.text.isEmpty {
            if p.speaker != lastSpeaker {
                lines.append("")
                lines.append("[\(stamp(p.start))] \(p.speaker.rawValue):")
                lastSpeaker = p.speaker
            }
            lines.append(p.text)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - Phantom lines

    /// Text the recogniser produces on silence/noise rather than speech.
    static func isPhantom(_ text: String) -> Bool {
        let norm = normalized(text)
        if norm.isEmpty { return true }
        let exact: Set<String> = [
            "chatgpt", "bones", "yo ill be outside", "you",
            "thank you for watching", "thanks for watching", "subtitles by the amara org community",
            "vielen dank fürs zuschauen", "vielen dank für ihre aufmerksamkeit",
            "untertitel im auftrag des zdf", "untertitelung im auftrag des zdf"
        ]
        if exact.contains(norm) { return true }
        let contains = ["amara org", "untertitel im auftrag", "untertitelung", "thanks for watching",
                        "thank you for watching", "subtitles by", "copyright"]
        return contains.contains { norm.contains($0) } && norm.split(separator: " ").count <= 10
    }

    // MARK: - Echo sentences

    static func normalized(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] {
        normalized(s).split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?…".contains(ch) {
                out.append(current); current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Drops sentences from YOUR pieces when ≥ 70 % of their words occur in what
    /// the other side said within ±8 s — the far side leaking through the
    /// speakers into your microphone. Sentences under 4 words are kept (too
    /// little evidence; "Ja." is usually yours).
    static func removeEchoSentences(_ pieces: [Piece]) -> ([Piece], Int) {
        let others = pieces.filter { $0.speaker == .other }
        var removed = 0
        var result: [Piece] = []
        for var p in pieces {
            guard p.speaker == .me else { result.append(p); continue }
            let nearby = others.filter { $0.start <= p.end + 8 && $0.end >= p.start - 8 }
            guard !nearby.isEmpty else { result.append(p); continue }
            let pool = Set(nearby.flatMap { tokens($0.text) })
            let kept = sentences(p.text).filter { sentence in
                let t = tokens(sentence)
                guard t.count >= 4 else { return true }
                let hits = t.filter { pool.contains($0) }.count
                if Double(hits) / Double(t.count) >= 0.7 { removed += 1; return false }
                return true
            }
            p.text = kept.joined(separator: " ")
            if !p.text.isEmpty { result.append(p) }
        }
        return (result, removed)
    }
}
