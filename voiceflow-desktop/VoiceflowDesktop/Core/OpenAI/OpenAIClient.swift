import Foundation

/// Direct client for the OpenAI API — the only backend Voiceflow talks to.
///
/// Endpoints used:
///   POST /v1/audio/transcriptions   — speech-to-text (gpt-4o-mini-transcribe, whisper-1 fallback)
///   POST /v1/chat/completions       — tone-of-voice rewriting (Private/Business/Calm)
///   GET  /v1/models                 — API-key validation during onboarding
///
/// The API key comes from the Keychain (user-supplied during onboarding).
final class OpenAIClient {

    static let shared = OpenAIClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45   // generous for long dictations
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    // MARK: - Key validation

    /// Validates an API key by listing models. Throws `OpenAIError` on failure.
    func validate(apiKey: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard http.statusCode == 200 else {
            throw OpenAIError.httpError(http.statusCode, Self.errorMessage(from: data))
        }
    }

    // MARK: - Transcription

    struct Transcription {
        let text: String
    }

    /// Transcribes the audio file using the fastest available model.
    ///
    /// Strategy: try `gpt-4o-mini-transcribe` (half the price of whisper-1, lower
    /// latency, better WER). If the account doesn't have access (400/403/404 model
    /// error), permanently fall back to `whisper-1` (remembered in UserDefaults so
    /// we don't pay the failed round-trip on every dictation).
    func transcribe(audioData: Data, fileExt: String, languageCode: String?, apiKey: String) async throws -> Transcription {
        let fallbackFlag = "com.voiceflow.desktop.transcribe_fallback_whisper1"
        let useFallback = UserDefaults.standard.bool(forKey: fallbackFlag)
        let primaryModel = useFallback ? "whisper-1" : "gpt-4o-mini-transcribe"

        do {
            return try await transcribeOnce(audioData: audioData, fileExt: fileExt,
                                            languageCode: languageCode, model: primaryModel, apiKey: apiKey)
        } catch let OpenAIError.httpError(code, message) where !useFallback && (code == 400 || code == 403 || code == 404)
                    && message.lowercased().contains("model") {
            // Account lacks access to the new model — remember and fall back.
            NSLog("[OpenAIClient] %@ unavailable (%d: %@) — falling back to whisper-1 permanently",
                  primaryModel, code, message)
            UserDefaults.standard.set(true, forKey: fallbackFlag)
            return try await transcribeOnce(audioData: audioData, fileExt: fileExt,
                                            languageCode: languageCode, model: "whisper-1", apiKey: apiKey)
        }
    }

    private func transcribeOnce(audioData: Data, fileExt: String, languageCode: String?,
                                model: String, apiKey: String) async throws -> Transcription {
        let boundary = "VF-\(UUID().uuidString)"
        let mimeType = fileExt == "m4a" ? "audio/m4a" : "audio/x-caf"

        var body = Data()
        body.appendFormField(name: "model", value: model, boundary: boundary)
        // Faster server-side path: plain JSON, no timestamps/verbose metadata.
        body.appendFormField(name: "response_format", value: "json", boundary: boundary)
        if let languageCode {
            body.appendFormField(name: "language", value: languageCode, boundary: boundary)
        }
        body.appendFilePart(name: "file", filename: "audio.\(fileExt)", mimeType: mimeType,
                            data: audioData, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = Self.errorMessage(from: data)
            NSLog("[VF-Whisper] HTTP %d model=%@ body=%@", http.statusCode, model, msg)
            throw OpenAIError.httpError(http.statusCode, msg)
        }

        struct Response: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Transcription(text: decoded.text)
    }

    // MARK: - Chat (tone-of-voice rewriting)

    /// Runs a single chat completion. Low temperature for deterministic editing.
    func chat(systemPrompt: String, userText: String, apiKey: String) async throws -> String {
        struct Message: Codable { let role: String; let content: String }
        struct RequestBody: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
        }
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            let choices: [Choice]
        }

        let body = RequestBody(
            model: Config.chatModel,
            messages: [
                Message(role: "system", content: systemPrompt),
                Message(role: "user", content: userText)
            ],
            temperature: 0.3
        )

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = Self.errorMessage(from: data)
            NSLog("[VF-Chat] HTTP %d body=%@", http.statusCode, msg)
            throw OpenAIError.httpError(http.statusCode, msg)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.emptyResult
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Extracts the human-readable message from an OpenAI error payload.
    private static func errorMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let msg = env.error?.message {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}

// MARK: - Errors

enum OpenAIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(Int, String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Kein OpenAI API-Key hinterlegt. Bitte in den Einstellungen eintragen."
        case .invalidResponse:
            return "Ungültige Server-Antwort."
        case .httpError(let code, let msg):
            if code == 401 { return "API-Key ungültig oder abgelaufen. Bitte in den Einstellungen prüfen." }
            if code == 429 { return "OpenAI Rate-Limit erreicht — kurz warten und erneut versuchen." }
            return "OpenAI-Fehler (\(code)): \(msg)"
        case .emptyResult:
            return "Die KI hat ein leeres Ergebnis geliefert."
        }
    }
}

// MARK: - Multipart helpers

extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        let part = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            + "\(value)\r\n"
        append(part.data(using: .utf8)!)
    }

    mutating func appendFilePart(name: String, filename: String, mimeType: String, data fileData: Data, boundary: String) {
        let header = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: \(mimeType)\r\n\r\n"
        append(header.data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}
