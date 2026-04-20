import Foundation

// MARK: - ProcessingMode

/// The three dictation modes.
enum ProcessingMode: String, CaseIterable {
    case `private` = "private"
    case business  = "business"
    case calm      = "calm"

    var displayName: String {
        switch self {
        case .private:  return "Private"
        case .business: return "Business"
        case .calm:     return "Calm"
        }
    }

    /// System prompt sent to the AI model via the backend edge function.
    var systemPrompt: String {
        switch self {
        case .private:
            return """
            You are a minimal text corrector. Apply only:
            - Correct punctuation
            - Fix capitalization
            - Add appropriate paragraph breaks
            Preserve the speaker's exact wording. Do not paraphrase, improve, or restructure.
            Return only the corrected text with no commentary.
            """
        case .business:
            return """
            You are a professional business communication editor. Rewrite the text to be:
            - Customer-facing and professional in tone
            - Clear, concise, and modern
            - Pragmatic and credible
            - Suitable for external communication (not internal Slack/email style)
            Return only the rewritten text with no commentary.
            """
        case .calm:
            return """
            You are a de-escalation communication editor. Rewrite the text to:
            - Preserve the core message and intent
            - Remove aggression, sarcasm, insults, and escalating language
            - Keep the tone calm, direct, and respectful
            - Avoid being passive-aggressive or condescending
            Return only the rewritten text with no commentary.
            """
        }
    }
}

// MARK: - ModeProcessor

/// Sends the raw transcript to the Supabase edge function for mode-specific AI processing.
///
/// Edge function contract (POST /functions/v1/process-transcription):
///
///   Request body:
///     {
///       "text":          String,   // raw transcript
///       "mode":          String,   // "private" | "business" | "calm"
///       "language":      String,   // locale used, e.g. "de-DE"
///       "system_prompt": String    // full system prompt (defined above)
///     }
///
///   Success response (200):
///     { "result": String }
///
///   Error response:
///     { "error": String }
///
/// Fallback behaviour:
///   - If the edge function returns 404 (not deployed) or 503 (unavailable),
///     the raw transcript is returned unchanged. The pipeline still succeeds,
///     and the user gets plain dictation output.
///   - For all other HTTP errors, the error is surfaced.
///
/// To deploy the edge function, see the backend README or use:
///   supabase functions deploy process-transcription
final class ModeProcessor {

    private let api = APIClient.shared

    // MARK: - Process

    func process(
        text: String,
        mode: ProcessingMode,
        language: String,
        session: SupabaseSession
    ) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        struct RequestBody: Encodable {
            let text: String
            let mode: String
            let language: String
            let systemPrompt: String

            enum CodingKeys: String, CodingKey {
                case text, mode, language
                case systemPrompt = "system_prompt"
            }
        }

        struct ResponseBody: Decodable {
            let result: String?
            let error: String?
        }

        let body = RequestBody(
            text: text,
            mode: mode.rawValue,
            language: language,
            systemPrompt: mode.systemPrompt
        )

        let req = try api.request(
            path: Endpoints.processTranscription,
            method: "POST",
            body: body,
            authToken: session.accessToken
        )

        do {
            let response = try await api.perform(req, as: ResponseBody.self)

            if let error = response.error {
                throw ProcessingError.edgeFunctionError(error)
            }
            guard let result = response.result, !result.isEmpty else {
                throw ProcessingError.emptyResult
            }
            return result

        } catch let apiError as APIError {
            switch apiError {
            case .httpError(404, _), .httpError(503, _):
                // Edge function not deployed or temporarily unavailable.
                // Fall back to raw transcript so the app remains usable.
                #if DEBUG
                print("[ModeProcessor] Edge function unavailable (\(apiError)). Returning raw transcript.")
                #endif
                return text
            default:
                throw ProcessingError.networkError(apiError)
            }
        }
    }

    // MARK: - Legacy overload (keeps AppDelegate compatible during migration)

    func process(
        text: String,
        mode: ProcessingMode,
        session: SupabaseSession
    ) async throws -> String {
        try await process(text: text, mode: mode, language: "auto", session: session)
    }
}

// MARK: - Errors

enum ProcessingError: LocalizedError {
    case emptyResult
    case edgeFunctionError(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .emptyResult:
            return "The AI processing returned an empty result."
        case .edgeFunctionError(let msg):
            return "Processing error: \(msg)"
        case .networkError(let e):
            return "Processing network error: \(e.localizedDescription)"
        }
    }
}
