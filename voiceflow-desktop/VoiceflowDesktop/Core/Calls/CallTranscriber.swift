import Foundation

/// Transcribes the speaker-labelled chunks of a call (CallSegmenter) with the
/// regular TranscriptionService — gpt-transcribe, auto language detection,
/// dictionary as keywords — and assembles a readable, time-stamped transcript.
/// No rewrite/cleanup step: call transcripts stay verbatim.
final class CallTranscriber {

    struct Output {
        let transcript: String
        let languages: [String]
        let chunkCount: Int
        let failedChunks: Int
    }

    private let service = TranscriptionService()
    private let maxParallel = 3

    func transcribe(chunks: [CallSegmenter.Chunk], vocabulary: String,
                    model: String = TranscribeModel.recommended.id,
                    progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Output {
        struct Piece { let index: Int; let text: String; let locale: String }
        var pieces: [Piece] = []
        var failed = 0
        var done = 0

        // Bounded concurrency: `maxParallel` requests in flight.
        var iterator = chunks.enumerated().makeIterator()
        await withTaskGroup(of: (Int, String?, String?).self) { group in
            func addNext() {
                guard let (i, chunk) = iterator.next() else { return }
                group.addTask { [service] in
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
                if let text { pieces.append(Piece(index: i, text: text, locale: locale ?? "")) }
                else { failed += 1 }
                addNext()
            }
        }

        let ordered = pieces.sorted { $0.index < $1.index }
        var lines: [String] = []
        var lastSpeaker: CallSegmenter.Speaker? = nil
        for p in ordered where !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let chunk = chunks[p.index]
            let stamp = Self.stamp(chunk.start)
            if chunk.speaker != lastSpeaker {
                lines.append("")
                lines.append("[\(stamp)] \(chunk.speaker.rawValue):")
                lastSpeaker = chunk.speaker
            }
            lines.append(p.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let langs = Array(Set(ordered.map(\.locale).filter { !$0.isEmpty && $0 != "auto" })).sorted()
        return Output(transcript: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                      languages: langs, chunkCount: chunks.count, failedChunks: failed)
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
