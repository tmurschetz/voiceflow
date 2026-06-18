import Foundation

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
        onRetry: (@MainActor @Sendable (PipelineRetryEvent) async -> Void)? = nil
    ) async throws -> TranscriptionResult {
        guard let apiKey = KeychainStore.apiKey else {
            throw OpenAIError.missingAPIKey
        }

        let audioData = try Data(contentsOf: audio.fileURL)
        let fileExt = audio.fileURL.pathExtension.lowercased()

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

        var lastError: Error = OpenAIError.invalidResponse
        for attempt in 1...Self.maxAttempts {
            do {
                let result = try await client.transcribe(
                    audioData: audioData,
                    fileExt: fileExt,
                    languageCode: languageCode,
                    model: model,
                    apiKey: apiKey
                )
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranscriptionError.emptyTranscript
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
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Keine Sprache erkannt. Bitte erneut versuchen."
        }
    }
}
