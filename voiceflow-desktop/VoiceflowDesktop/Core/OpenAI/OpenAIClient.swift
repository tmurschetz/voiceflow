import Foundation

/// Direct client for the OpenAI API — the only network endpoint Voiceflow talks to.
///
/// Endpoints used:
///   POST /v1/audio/transcriptions   — speech-to-text
///   POST /v1/chat/completions       — tone-of-voice rewriting
///   GET  /v1/models                 — API-key validation + connection warm-up
///
/// Security properties:
///   - The API key comes from the Keychain and is only ever placed in the
///     Authorization header of requests to https://api.openai.com.
///   - The key is never logged, never written to disk outside the Keychain,
///     and never sent anywhere else (this client is the app's entire network layer).
final class OpenAIClient {

    static let shared = OpenAIClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45   // generous for long dictations
        config.timeoutIntervalForResource = 120
        // TLS 1.2+ only (1.3 is negotiated automatically when available).
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config)
    }()

    // MARK: - Key validation / connection warm-up

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

    /// Fire-and-forget connection warm-up. Called when recording STARTS so the
    /// DNS lookup + TCP + TLS handshake (~300–600 ms) happen while the user is
    /// still speaking — the transcription POST then reuses the warm connection.
    func warmUpConnection() {
        guard let apiKey = KeychainStore.apiKey else { return }
        Task.detached(priority: .utility) { [session] in
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 10
            _ = try? await session.data(for: req)
        }
    }

    // MARK: - Transcription

    struct Transcription {
        let text: String
    }

    /// Transcribes the audio file with the user-selected model.
    ///
    /// If the account lacks access to the selected model (400/403/404 model
    /// error), falls back to whisper-1 for this call — without overriding the
    /// user's choice in Settings.
    func transcribe(audioData: Data, fileExt: String, languageCode: String?,
                    model: String, apiKey: String) async throws -> Transcription {
        do {
            return try await transcribeOnce(audioData: audioData, fileExt: fileExt,
                                            languageCode: languageCode, model: model, apiKey: apiKey)
        } catch let OpenAIError.httpError(code, message) where model != "whisper-1"
                    && (code == 400 || code == 403 || code == 404)
                    && message.lowercased().contains("model") {
            NSLog("[OpenAIClient] %@ unavailable (%d) — falling back to whisper-1 for this call", model, code)
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
        // Fast server path: plain JSON, no timestamps/verbose metadata.
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

        let started = Date()
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = Self.errorMessage(from: data)
            NSLog("[VF-Transcribe] HTTP %d model=%@ body=%@", http.statusCode, model, msg)
            throw OpenAIError.httpError(http.statusCode, msg)
        }
        NSLog("[VF-Transcribe] %.2fs model=%@ upload=%dKB", Date().timeIntervalSince(started),
              model, audioData.count / 1024)

        struct Response: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Transcription(text: decoded.text)
    }

    // MARK: - Chat (tone-of-voice rewriting)

    /// Runs a single chat completion. Low temperature for deterministic editing.
    ///
    /// `predictOutput`: enables OpenAI Predicted Outputs with the input text as
    /// the prediction. For editing tasks the output is mostly identical to the
    /// input, so the model skips re-generating unchanged tokens — measured
    /// ~25–40 % lower latency on real dictations. Disable for transformations
    /// where the output diverges heavily (e.g. Random mode with a translation
    /// instruction): rejected prediction tokens cost extra and save nothing.
    func chat(systemPrompt: String, userText: String, model: String, apiKey: String,
              predictOutput: Bool = true) async throws -> String {
        struct Message: Codable { let role: String; let content: String }
        struct Prediction: Encodable {
            let type = "content"
            let content: String
        }
        struct RequestBody: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
            let prediction: Prediction?
        }
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
            }
            let choices: [Choice]
        }

        let body = RequestBody(
            model: model,
            messages: [
                Message(role: "system", content: systemPrompt),
                Message(role: "user", content: userText)
            ],
            temperature: 0.3,
            prediction: predictOutput ? Prediction(content: userText) : nil
        )

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let started = Date()
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = Self.errorMessage(from: data)
            NSLog("[VF-Chat] HTTP %d model=%@ body=%@", http.statusCode, model, msg)
            throw OpenAIError.httpError(http.statusCode, msg)
        }
        NSLog("[VF-Chat] %.2fs model=%@", Date().timeIntervalSince(started), model)

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.emptyResult
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Extracts the human-readable message from an OpenAI error payload.
    /// Never includes request headers — the API key cannot leak through here.
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
