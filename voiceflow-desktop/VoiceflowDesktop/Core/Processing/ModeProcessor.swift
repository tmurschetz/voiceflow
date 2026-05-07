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

    /// Result of a processing attempt — distinguishes a successful AI polish from
    /// a fallback to the raw Whisper transcript so callers can show appropriate UX.
    struct Result {
        let text: String
        /// True when all retries failed and we returned the raw transcript instead.
        let usedFallback: Bool
    }

    /// Events fired during a retry cycle so the UI can show a countdown.
    enum RetryEvent: Sendable {
        case willRetryIn(seconds: Int, attempt: Int, total: Int)
        case retrying(attempt: Int, total: Int)
    }

    /// Retry policy: 1 initial attempt + 1 retry, with a 5-second visible countdown
    /// between them. Keeps the user's recording usable on transient server outages
    /// without making them wait too long.
    private static let maxAttempts = 2
    private static let retryDelaySeconds = 5

    func process(
        text: String,
        mode: ProcessingMode,
        language: String,
        session: SupabaseSession,
        onRetry: (@MainActor @Sendable (RetryEvent) async -> Void)? = nil
    ) async throws -> Result {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(text: text, usedFallback: false)
        }

        var lastError: Error?

        for attempt in 1...Self.maxAttempts {
            do {
                let polished = try await callEdgeFunction(
                    text: text, mode: mode, language: language, session: session
                )
                return Result(text: polished, usedFallback: false)

            } catch {
                // Catch *all* errors so URLSession-level failures (timeouts,
                // connection refused, DNS, etc.) flow through the same retry
                // logic as APIError. Previously these were thrown as URLError
                // and bypassed retry entirely → user lost their recording.
                let retryable = Self.isRetryable(error)
                NSLog("[ModeProcessor] Attempt %d failed: %@ (retryable=%@)",
                      attempt, String(describing: error), retryable ? "YES" : "NO")

                if retryable, attempt < Self.maxAttempts {
                    if let onRetry {
                        for sec in stride(from: Self.retryDelaySeconds, through: 1, by: -1) {
                            await onRetry(.willRetryIn(seconds: sec, attempt: attempt, total: Self.maxAttempts))
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        await onRetry(.retrying(attempt: attempt + 1, total: Self.maxAttempts))
                    } else {
                        try? await Task.sleep(nanoseconds: UInt64(Self.retryDelaySeconds) * 1_000_000_000)
                    }
                    lastError = error
                    continue
                }
                if retryable {
                    // Retries exhausted on a transient/availability error — fall
                    // back to the raw Whisper transcript so the user keeps their words.
                    NSLog("[ModeProcessor] All %d attempts failed. Returning raw transcript.",
                          Self.maxAttempts)
                    return Result(text: text, usedFallback: true)
                }
                // Non-retryable error (auth, malformed body, …). Surface a
                // user-friendly error — but the audio file lives on disk for now,
                // so callers can still recover the raw text if they want.
                if let apiError = error as? APIError {
                    throw ProcessingError.networkError(apiError)
                }
                throw error
            }
        }

        // Defensive: should not reach here.
        if let lastError {
            NSLog("[ModeProcessor] Exited retry loop unexpectedly (%@). Returning raw transcript.",
                  String(describing: lastError))
        }
        return Result(text: text, usedFallback: true)
    }

    // MARK: - Internals

    /// Single call to the edge function — no retry logic.
    private func callEdgeFunction(
        text: String,
        mode: ProcessingMode,
        language: String,
        session: SupabaseSession
    ) async throws -> String {
        struct RequestBody: Encodable {
            let transcript: String
            let mode: String
            let language: String
        }
        struct ResponseBody: Decodable {
            let transformedText: String?
            let error: String?
            // CodingKeys not needed — JSONDecoder.supabase uses convertFromSnakeCase
        }

        let body = RequestBody(transcript: text, mode: mode.rawValue, language: language)
        let req = try api.request(
            path: Endpoints.processTranscription,
            method: "POST",
            body: body,
            authToken: session.accessToken
        )
        let response = try await api.perform(req, as: ResponseBody.self)
        if let error = response.error {
            throw ProcessingError.edgeFunctionError(error)
        }
        guard let result = response.transformedText, !result.isEmpty else {
            throw ProcessingError.emptyResult
        }
        return result
    }

    /// Decide whether an error warrants a retry + raw-transcript fallback.
    /// Covers both `APIError` (HTTP-level) and `URLError` (transport-level —
    /// timeouts, DNS, connection refused). Auth/4xx errors are NOT retried since
    /// they indicate a real bug or expired credentials.
    private static func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .httpError(let code, _) where code == 404 || (500..<600).contains(code):
                return true
            case .invalidResponse, .decodingError:
                return true
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            // Transport-level failures — almost always worth retrying.
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .resourceUnavailable, .badServerResponse,
                 .secureConnectionFailed, .serverCertificateUntrusted,
                 .cannotLoadFromNetwork, .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        // ProcessingError.edgeFunctionError — server returned `{"error": "..."}`.
        // Often a transient Gemini/LLM issue; retry once.
        if let _ = error as? ProcessingError {
            return true
        }
        return false
    }

    // MARK: - Legacy overload (keeps unit tests / older callers compatible)

    /// Legacy entry point that returns just the text. New callers should use the
    /// retry-aware overload that returns `Result` and supports `onRetry`.
    func process(
        text: String,
        mode: ProcessingMode,
        session: SupabaseSession
    ) async throws -> String {
        try await process(text: text, mode: mode, language: "auto", session: session).text
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
