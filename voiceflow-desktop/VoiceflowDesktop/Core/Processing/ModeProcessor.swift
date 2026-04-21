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
    /// Reference documentation of what each server-side prompt does.
    /// The actual prompts live in the Supabase edge function (process-transcription).
    /// These are kept here as spec documentation only — not sent in API requests.
    var systemPromptDocumentation: String {
        switch self {
        case .private:
            return "Minimal correction: punctuation, capitalisation, paragraph breaks. Exact wording preserved."
        case .business:
            return "Professional rewrite: customer-facing tone, clear and concise, suitable for external comms."
        case .calm:
            return "De-escalation rewrite: removes aggression/sarcasm, keeps core message, calm and respectful."
        }
    }
}

// MARK: - ModeProcessor

/// Sends the raw transcript to the Supabase edge function for mode-specific AI processing.
///
/// Edge function contract (POST /functions/v1/process-transcription):
///
///   Request body (Lovable-deployed schema, verified 2026-04-21):
///     {
///       "transcript": String,  // raw transcript text
///       "mode":       String,  // "private" | "business" | "calm"
///       "language":   String   // locale used, e.g. "de", "en"
///     }
///
///   Success response (200):
///     { "transformed_text": String, "mode": String }
///
///   Error response:
///     { "error": { "formErrors": [], "fieldErrors": { ... } } }
///
/// Fallback behaviour:
///   - If the edge function returns 404 (not deployed) or 503 (unavailable),
///     the raw transcript is returned unchanged. The pipeline still succeeds.
///   - For all other HTTP errors, the error is surfaced.
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

        // Request body uses "transcript" (not "text") per Lovable edge function Zod schema
        struct RequestBody: Encodable {
            let transcript: String
            let mode: String
            let language: String
        }

        // Response uses "transformed_text" (not "result") per Lovable edge function
        struct ResponseBody: Decodable {
            let transformedText: String?
            let error: String?
            // CodingKeys not needed — JSONDecoder.supabase uses convertFromSnakeCase
        }

        let body = RequestBody(
            transcript: text,
            mode: mode.rawValue,
            language: language
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
            guard let result = response.transformedText, !result.isEmpty else {
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
