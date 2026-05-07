import Foundation

// MARK: - TranscriptionResult

/// The output of a transcription pass.
struct TranscriptionResult {
    /// The raw transcript text.
    let transcript: String

    /// The locale identifier that was actually used (e.g. "de", "en").
    /// Whisper returns the detected language code when auto-detect is active.
    let usedLocale: String

    /// Convenience: whether the transcript is non-empty.
    var isEmpty: Bool { transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - TranscriptionService

/// Transcribes recorded audio to text using OpenAI Whisper API.
///
/// Why Whisper instead of Apple SFSpeechRecognizer:
///   - No 60-second hard cap (Whisper handles files up to 25 MB ≈ 30 min)
///   - Industry-best accuracy for German and Swiss German dialect
///   - True language auto-detection (SFSpeechRecognizer requires a pre-specified locale)
///   - Consistent quality across all macOS versions
///
/// Language handling:
///   autoDetect     → no language param sent; Whisper detects from audio content
///   .german        → "de"
///   .english       → "en"
///   .swissGerman   → "de"  (Whisper transcribes Swiss German dialect under the "de" code;
///                            it was trained on real-world audio including Swiss speakers)
///
/// Cost: $0.006/min. A 20-second dictation costs $0.000002 — negligible.
final class TranscriptionService {

    private let whisperEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    // MARK: - Public Entry Point

    func transcribe(
        audio: RecordedAudio,
        language: LanguageSelection,
        mode: ProcessingMode,
        session: SupabaseSession
    ) async throws -> TranscriptionResult {

        let audioData = try Data(contentsOf: audio.fileURL)
        let fileExt   = audio.fileURL.pathExtension.lowercased()
        let mimeType  = fileExt == "m4a" ? "audio/m4a" : "audio/x-caf"
        let boundary  = "VF-\(UUID().uuidString)"

        var body = Data()

        // Required: model
        body.appendFormField(name: "model", value: "whisper-1", boundary: boundary)

        // Optional: language (omit for auto-detect — Whisper will infer from audio)
        if case .manual(let lang) = language {
            body.appendFormField(name: "language", value: lang.whisperCode, boundary: boundary)
        }

        // Required: audio file
        body.appendFilePart(
            name: "file",
            filename: "audio.\(fileExt)",
            mimeType: mimeType,
            data: audioData,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: whisperEndpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Config.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid server response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            // Diagnostic: surface the exact failure to the unified log, even in Release builds.
            NSLog("[VF-Whisper] HTTP %d body=%@", http.statusCode, msg)
            NSLog("[VF-Whisper] request URL=%@ method=%@ contentLength=%d",
                  req.url?.absoluteString ?? "?", req.httpMethod ?? "?", body.count)
            throw TranscriptionError.apiError(http.statusCode, msg)
        }

        // Whisper returns: { "text": "...", "language": "german" }
        // The "language" field uses full English names (e.g. "german"), not ISO codes.
        struct WhisperResponse: Decodable {
            let text: String
            let language: String?
        }
        let whisper = try JSONDecoder().decode(WhisperResponse.self, from: data)

        guard !whisper.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.emptyTranscript
        }

        // Normalise the returned language to a short code for session logging.
        let usedLocale: String
        switch language {
        case .autoDetect:
            // Whisper returns full names like "german" — convert to short code
            usedLocale = shortCode(from: whisper.language) ?? "auto"
        case .manual(let lang):
            usedLocale = lang.whisperCode
        }

        return TranscriptionResult(transcript: whisper.text, usedLocale: usedLocale)
    }

    // MARK: - Language Name → ISO Code

    /// Converts Whisper's full-language-name response (e.g. "german") to a short code ("de").
    private func shortCode(from whisperLanguage: String?) -> String? {
        switch whisperLanguage?.lowercased() {
        case "german":  return "de"
        case "english": return "en"
        case "french":  return "fr"
        case "italian": return "it"
        default:        return whisperLanguage.map { String($0.prefix(2)) }
        }
    }
}

// MARK: - Multipart Form Data Helpers

private extension Data {
    /// Appends a plain text field to a multipart/form-data body.
    mutating func appendFormField(name: String, value: String, boundary: String) {
        let part = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            + "\(value)\r\n"
        append(part.data(using: .utf8)!)
    }

    /// Appends a binary file part to a multipart/form-data body.
    mutating func appendFilePart(name: String, filename: String, mimeType: String, data fileData: Data, boundary: String) {
        let header = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: \(mimeType)\r\n\r\n"
        append(header.data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case emptyTranscript
    case apiError(Int, String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "No speech detected. Please try again."
        case .apiError(let code, let body):
            return "Transcription failed (\(code)): \(body)"
        case .networkError(let msg):
            return "Transcription network error: \(msg)"
        }
    }
}
