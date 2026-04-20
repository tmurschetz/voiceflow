import Foundation
import Speech

// MARK: - TranscriptionResult

/// The output of a transcription pass.
struct TranscriptionResult {
    /// The raw transcript text.
    let transcript: String

    /// The locale identifier that was actually used (e.g. "de-DE").
    /// This is not true language *detection* — SFSpeechRecognizer requires a pre-specified
    /// locale. For auto-detect we infer from the system locale.
    let usedLocale: String

    /// Convenience: whether the transcript is non-empty.
    var isEmpty: Bool { transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - TranscriptionService

/// Transcribes recorded audio to text using Apple's on-device SFSpeechRecognizer.
///
/// Language support:
///   German      → de-DE
///   English     → en-US
///   Swiss German → de-CH  (SFSpeechRecognizer has no gsw locale; de-CH is the closest)
///   Auto-detect  → infers from system locale; falls back to en-US
///
/// On-device recognition (no data leaves the device) is used when:
///   - The mode is `.private`
///   - Or `requiresOnDevice` is explicitly set to true in AppSettings (future)
///
/// Fallback: if SFSpeechRecognizer is unavailable for the chosen locale, the service
/// retries with en-US before throwing.
final class TranscriptionService {

    // MARK: - Public Entry Point

    func transcribe(
        audio: RecordedAudio,
        language: LanguageSelection,
        mode: ProcessingMode,
        session: SupabaseSession
    ) async throws -> TranscriptionResult {

        // Step 1: Request speech recognition permission
        try await ensurePermission()

        // Step 2: Resolve target locale
        let targetLocale = resolveLocale(for: language)

        // Step 3: Attempt recognition with target locale
        do {
            let transcript = try await recognizeFile(
                url: audio.fileURL,
                locale: targetLocale,
                onDevice: mode == .private   // Private mode → stay on-device
            )
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptionError.emptyTranscript
            }
            return TranscriptionResult(transcript: transcript, usedLocale: targetLocale.identifier)

        } catch TranscriptionError.recognizerUnavailable where targetLocale.identifier != "en-US" {
            // Recognizer not available for target locale → retry with en-US
            #if DEBUG
            print("[TranscriptionService] \(targetLocale.identifier) unavailable, falling back to en-US")
            #endif
            let transcript = try await recognizeFile(
                url: audio.fileURL,
                locale: Locale(identifier: "en-US"),
                onDevice: mode == .private
            )
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptionError.emptyTranscript
            }
            return TranscriptionResult(transcript: transcript, usedLocale: "en-US")
        }
    }

    // MARK: - Locale Resolution

    /// Maps a `LanguageSelection` to a concrete `Locale` for SFSpeechRecognizer.
    private func resolveLocale(for selection: LanguageSelection) -> Locale {
        switch selection {
        case .autoDetect:
            // Infer from the system's primary language
            let langCode = Locale.current.language.languageCode?.identifier ?? "en"
            switch langCode {
            case "de":          return Locale(identifier: "de-DE")
            case "gsw", "als":  return Locale(identifier: "de-CH")
            default:            return Locale(identifier: "en-US")
            }
        case .manual(.german):      return Locale(identifier: "de-DE")
        case .manual(.english):     return Locale(identifier: "en-US")
        case .manual(.swissGerman): return Locale(identifier: "de-CH")
        // Note: de-CH in SFSpeechRecognizer recognizes Standard German as spoken
        // in Switzerland. True Swiss German dialects (Zurich German, etc.) are not
        // supported natively — they will be partially transcribed.
        }
    }

    // MARK: - SFSpeechRecognizer Core

    private func recognizeFile(url: URL, locale: Locale, onDevice: Bool) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        // On-device recognition keeps audio off Apple's servers.
        // Available on macOS 12+; silently ignored on earlier versions.
        if onDevice {
            if #available(macOS 12, *) {
                request.requiresOnDeviceRecognition = true
            }
        }

        // SFSpeechRecognizer uses a callback-based API. Wrap it in async/await.
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }

                if let error = error {
                    resumed = true
                    continuation.resume(throwing: TranscriptionError.recognitionFailed(error))
                    return
                }
                if let result = result, result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString
                    continuation.resume(returning: text)
                }
            }
        }
    }

    // MARK: - Permission

    private func ensurePermission() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            if !granted { throw TranscriptionError.permissionDenied }
        case .denied, .restricted:
            throw TranscriptionError.permissionDenied
        @unknown default:
            throw TranscriptionError.permissionDenied
        }
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case recognitionFailed(Error)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition access denied. Enable it in System Settings → Privacy → Speech Recognition."
        case .recognizerUnavailable:
            return "Speech recognizer not available for the selected language."
        case .recognitionFailed(let e):
            return "Recognition failed: \(e.localizedDescription)"
        case .emptyTranscript:
            return "No speech detected. Please try again."
        }
    }
}
