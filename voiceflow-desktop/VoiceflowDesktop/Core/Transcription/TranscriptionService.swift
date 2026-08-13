import Foundation
import AVFoundation

// MARK: - TranscriptionResult

/// The output of a transcription pass.
struct TranscriptionResult {
    /// The raw transcript text.
    let transcript: String

    /// The locale that was requested ("de", "en") or "auto" when auto-detect was on.
    /// The tone-of-voice step mirrors the input language anyway, so we don't need
    /// the model's own language detection metadata.
    let usedLocale: String

    var isEmpty: Bool { transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - TranscriptionService

/// Transcribes recorded audio to text via the OpenAI API using the user's own key.
///
/// Speed: gpt-4o-mini-transcribe (primary) is noticeably faster than whisper-1
/// and costs half as much. OpenAIClient handles the model fallback transparently.
///
/// Language handling:
///   autoDetect   → no language param; the model detects German/Swiss German/English
///   .german      → "de"
///   .english     → "en"
///   .swissGerman → "de"  (dialect audio is transcribed under the German code)
final class TranscriptionService {

    private let client = OpenAIClient.shared

    /// Retry policy: like the rewrite stage — 1 initial attempt + 1 retry with a
    /// visible 5-second countdown. Previously this stage had NO retry, so a
    /// single timeout/429 threw straight to the error state and the recording
    /// was discarded.
    private static let maxAttempts = 2
    /// Short delay: a stalled request is best retried quickly on a fresh
    /// connection. (The longer 5 s wait made sense only for a full server
    /// outage, which the raw-transcript fallback already covers.)
    private static let retryDelaySeconds = 2

    func transcribe(
        audio: RecordedAudio,
        language: LanguageSelection,
        model: String,
        vocabulary: String = "",
        onRetry: (@MainActor @Sendable (PipelineRetryEvent) async -> Void)? = nil
    ) async throws -> TranscriptionResult {
        guard let apiKey = KeychainStore.apiKey else {
            throw OpenAIError.missingAPIKey
        }

        let audioData = try Data(contentsOf: audio.fileURL)
        let fileExt = audio.fileURL.pathExtension.lowercased()

        // Guard against an empty/too-short recording — typically an accidental
        // double-press of the shortcut (start+stop with nothing in between).
        // Uploading it returns an opaque OpenAI 400 ("Audio file might be
        // corrupted or unsupported") and gets stuck in the retry/rescue loop.
        // Catch it up front and surface a friendly, non-retryable error.
        if Self.isEmptyRecording(data: audioData, url: audio.fileURL) {
            NSLog("[VF-Transcribe] Empty/too-short recording (%d bytes) — not uploading", audioData.count)
            throw TranscriptionError.noSpeech
        }

        let languageCode: String?
        let usedLocale: String
        switch language {
        case .autoDetect:
            languageCode = nil
            usedLocale = "auto"
        case .manual(let lang):
            languageCode = lang.whisperCode
            usedLocale = lang.rawValue
        }

        let prompt = Self.recognitionPrompt(for: language, vocabulary: vocabulary)

        // Long-recording support (up to ~30 min): the upload size guard catches
        // files beyond the API's 25 MB cap, and recordings longer than
        // gpt-4o-transcribe's 25-minute duration limit are routed to whisper-1
        // (no duration cap) instead of failing with an opaque 400.
        let audioSeconds = Int(Self.audioDuration(url: audio.fileURL) ?? 0)
        if audioData.count > Self.maxUploadBytes {
            throw TranscriptionError.tooLong
        }
        let effectiveModel = Self.effectiveModel(requested: model, audioSeconds: audioSeconds)
        if effectiveModel != model {
            NSLog("[VF-Transcribe] %ds audio exceeds %@'s limit — using whisper-1", audioSeconds, model)
        }

        var lastError: Error = OpenAIError.invalidResponse
        for attempt in 1...Self.maxAttempts {
            do {
                let result = try await client.transcribe(
                    audioData: audioData,
                    fileExt: fileExt,
                    languageCode: languageCode,
                    model: effectiveModel,
                    apiKey: apiKey,
                    prompt: prompt,
                    audioSeconds: audioSeconds
                )
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranscriptionError.emptyTranscript
                }
                // Silent/near-silent audio makes the recogniser hallucinate its
                // own prompt — i.e. the user's dictionary gets "transcribed" and
                // pasted. Catch prompt echoes and junk before they reach output.
                if Self.looksLikePromptEcho(transcript: result.text, vocabulary: vocabulary) {
                    NSLog("[VF-Transcribe] Transcript is a prompt echo/junk — treating as no speech")
                    throw TranscriptionError.noSpeech
                }
                return TranscriptionResult(transcript: result.text, usedLocale: usedLocale)

            } catch {
                lastError = error
                let retryable = OpenAIRetry.isRetryable(error)
                NSLog("[VF-Transcribe] Attempt %d failed: %@ (retryable=%@)",
                      attempt, String(describing: error), retryable ? "YES" : "NO")
                guard retryable, attempt < Self.maxAttempts else { throw error }

                if let onRetry {
                    for sec in stride(from: Self.retryDelaySeconds, through: 1, by: -1) {
                        await onRetry(.willRetryIn(seconds: sec, attempt: attempt, total: Self.maxAttempts))
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    await onRetry(.retrying(attempt: attempt + 1, total: Self.maxAttempts))
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryDelaySeconds) * 1_000_000_000)
                }
            }
        }
        throw lastError
    }

    /// OpenAI's transcription upload cap is 25 MB — leave headroom. At the
    /// app's 96 kbps capture this is ~34 minutes of audio.
    static let maxUploadBytes = 24_500_000

    /// gpt-4o-transcribe models reject audio longer than 25 minutes (1500 s).
    /// Above this (with margin) we transparently use whisper-1, which has no
    /// duration cap — the user asked for reliable dictation up to ~30 minutes.
    static let gpt4oDurationCapSeconds = 1_380   // 23 min, safety margin

    static func effectiveModel(requested: String, audioSeconds: Int) -> String {
        if requested.hasPrefix("gpt-4o") && audioSeconds > gpt4oDurationCapSeconds {
            return "whisper-1"
        }
        return requested
    }

    /// Decoded duration in seconds, or nil if unreadable.
    static func audioDuration(url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url),
              file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Detects transcripts that are NOT speech but an artefact of silent audio:
    /// the recogniser, fed silence plus our recognition prompt, tends to
    /// "transcribe" the prompt itself — i.e. the user's dictionary list — or
    /// emit short junk like "context:". Real dictations contain verbs/fillers
    /// beyond the dictionary, so they never trip this.
    static func looksLikePromptEcho(transcript: String, vocabulary: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Known junk emissions on silent audio.
        let lowered = trimmed.lowercased()
        if lowered == "context:" || lowered == "kontext:" { return true }
        // A lone word ending in a colon is not a dictation.
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if words.count == 1 && trimmed.hasSuffix(":") { return true }

        // Echo of the dictionary: almost every transcript token appears in the
        // vocabulary and the transcript is no longer than the vocabulary itself.
        func tokens(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 }
        }
        let vocabTokens = Set(tokens(vocabulary))
        guard !vocabTokens.isEmpty else { return false }
        let transcriptTokens = tokens(trimmed)
        guard !transcriptTokens.isEmpty,
              transcriptTokens.count <= vocabTokens.count + 3 else { return false }
        let matching = transcriptTokens.filter { vocabTokens.contains($0) }.count
        return Double(matching) >= Double(transcriptTokens.count) * 0.7
    }

    /// True when the recording contains essentially no audio. An empty AAC/m4a
    /// container is ~557 bytes; the shortest real utterance is several KB. The
    /// byte floor catches the common case fast; the decoded-duration check is a
    /// format-agnostic backstop (also covers the .caf path for a chosen device).
    static func isEmptyRecording(data: Data, url: URL) -> Bool {
        if data.count < 1200 { return true }
        if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            if seconds < 0.35 { return true }
        }
        return false
    }

    /// Builds the OpenAI transcription `prompt` — a short bias string that nudges
    /// the model toward clean spelling/punctuation and feeds the user's custom
    /// vocabulary (names, brands, project terms) so they're written correctly
    /// instead of guessed phonetically.
    ///
    /// On auto-detect we deliberately omit a language-specific carrier sentence:
    /// a German/English prompt on the "wrong" audio can skew detection, so only
    /// the (largely language-neutral) vocabulary is passed. Selecting a concrete
    /// language unlocks the full formatting hint.
    static func recognitionPrompt(for language: LanguageSelection, vocabulary: String) -> String {
        let base: String
        switch language {
        case .manual(.english):
            base = "Clean English with proper capitalisation and punctuation."
        case .manual(.german), .manual(.swissGerman):
            base = "Schweizer Hochdeutsch. Saubere Gross-/Kleinschreibung und Interpunktion. "
                 + "Zahlen, Daten und Uhrzeiten korrekt (z. B. 14:00 Uhr, 13. März)."
        case .autoDetect:
            base = ""
        }

        // Normalise the vocabulary (one term per line or comma-separated) and cap
        // it — OpenAI only honours ~224 prompt tokens.
        let vocab = vocabulary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let cappedVocab = String(vocab.prefix(480))

        switch (base.isEmpty, cappedVocab.isEmpty) {
        case (true, true):   return ""
        case (true, false):  return cappedVocab
        case (false, true):  return base
        case (false, false): return base + " Eigennamen und Begriffe korrekt schreiben: \(cappedVocab)."
        }
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError, Equatable {
    case emptyTranscript
    /// The recording had no audio (e.g. accidental double-press). Not retryable.
    case noSpeech
    /// The file exceeds the API upload cap (~34 min at current quality).
    case tooLong

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Keine Sprache erkannt. Bitte erneut versuchen."
        case .noSpeech:
            return "Keine Sprache aufgenommen. Shortcut drücken, sprechen, dann nochmals drücken."
        case .tooLong:
            return "Die Aufnahme ist zu lang für eine Übertragung (max. ~30 Minuten). Bitte in kürzeren Abschnitten diktieren."
        }
    }
}
