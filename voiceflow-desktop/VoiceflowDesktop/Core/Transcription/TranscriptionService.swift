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

    func transcribe(audio: RecordedAudio, language: LanguageSelection, model: String) async throws -> TranscriptionResult {
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
