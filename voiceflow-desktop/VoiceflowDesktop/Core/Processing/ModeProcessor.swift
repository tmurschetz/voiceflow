import Foundation

// MARK: - ProcessingMode

/// The three dictation modes (tone of voice).
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

    /// The system prompt for this mode. Lives client-side — there is no server.
    ///
    /// Shared rules across all modes (mirrors what modern tools like Typeless do):
    ///   - Mirror the input language (German/Swiss German → Swiss Standard German
    ///     with ss instead of ß; English → English)
    ///   - Mirror the speaker's register (Du vs Sie) — never override it
    ///   - Handle self-corrections ("send it Monday — no wait, Tuesday" → Tuesday)
    ///   - Remove filler words (ähm, halt, quasi, like, you know)
    ///   - Never add letter structure (no salutation, no closing, no subject)
    ///   - Output only the text, no explanations
    var systemPrompt: String {
        let shared = """
        Universal rules (always apply):
        - Respond ONLY with the transformed text. No explanations, no quotes, no preamble.
        - Mirror the input language. German or Swiss German dialect input → output in Swiss \
        Standard German (Schweizer Hochdeutsch): always use "ss" instead of "ß", Swiss \
        vocabulary and phrasing. Never output dialect spelling. English input → English output.
        - Mirror the speaker's register: if they use du/dich/dir/dein, keep Du-form; if they \
        use Sie/Ihnen, keep Sie-form; if unclear, use Sie-form (German) or neutral (English).
        - Apply self-corrections: when the speaker corrects themselves mid-sentence \
        ("am Montag — nein, am Dienstag"), keep only the corrected version.
        - Remove filler words (ähm, äh, halt, quasi, sozusagen, eigentlich as filler, \
        um, uh, like, you know).
        - Never add anything that was not said: no salutations (Sehr geehrte, Hallo, Dear), \
        no closings (Mit freundlichen Grüssen, Best regards), no subject lines, no extra \
        sentences. The output stays roughly the same length as the input.
        - Format numbers, dates, e-mail addresses and URLs properly (zwanzig Prozent → 20 %, \
        drei Uhr → 15:00 only if clearly an appointment).
        """

        switch self {
        case .private:
            return """
            You are a transcription editor for a dictation tool. Lightly clean up the spoken \
            input: fix punctuation, capitalisation and obvious transcription errors, apply \
            self-corrections, remove fillers. Do NOT rewrite, restructure or change the \
            meaning, vocabulary or tone of what was said.

            \(shared)
            """
        case .business:
            return """
            You are a professional writing editor for a dictation tool. Rewrite the spoken \
            input in a polished, professional register — direct and concise, Swiss business \
            style, no flowery phrasing. Keep the same format and roughly the same length as \
            what was said. This is NOT a letter or an email: never add salutations, closings \
            or subject lines. Fix grammar, tighten phrasing, remove fillers — but do not add \
            new content or change the meaning.

            \(shared)
            """
        case .calm:
            return """
            You are a communication coach for a dictation tool. Rewrite the spoken input to \
            remove aggression, sarcasm, frustration and blunt language while keeping the core \
            message and roughly the same length. Stay direct and specific — do NOT use vague \
            therapeutic phrases ("Lass uns kurz innehalten", "I hear you"). The result should \
            sound like a calm, professional person, not a mediator.

            \(shared)
            """
        }
    }
}

// MARK: - ModeProcessor

/// Applies the tone-of-voice transformation by calling the OpenAI chat API directly
/// with the user's own key. No app backend involved.
///
/// Resilience: transient failures (5xx, timeouts, connection loss) are retried once
/// after a visible 5-second countdown; if all attempts fail, the raw transcript is
/// returned so the user never loses a dictation.
final class ModeProcessor {

    private let client = OpenAIClient.shared

    // MARK: - Result / events

    struct Result {
        let text: String
        /// True when all retries failed and we returned the raw transcript instead.
        let usedFallback: Bool
    }

    enum RetryEvent: Sendable {
        case willRetryIn(seconds: Int, attempt: Int, total: Int)
        case retrying(attempt: Int, total: Int)
    }

    private static let maxAttempts = 2
    private static let retryDelaySeconds = 5

    // MARK: - Process

    func process(
        text: String,
        mode: ProcessingMode,
        onRetry: (@MainActor @Sendable (RetryEvent) async -> Void)? = nil
    ) async throws -> Result {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(text: text, usedFallback: false)
        }
        guard let apiKey = KeychainStore.apiKey else {
            throw OpenAIError.missingAPIKey
        }

        for attempt in 1...Self.maxAttempts {
            do {
                let polished = try await client.chat(
                    systemPrompt: mode.systemPrompt,
                    userText: text,
                    apiKey: apiKey
                )
                return Result(text: polished, usedFallback: false)

            } catch {
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
                    continue
                }
                if retryable {
                    // Retries exhausted — return the raw transcript so no dictation is lost.
                    NSLog("[ModeProcessor] All %d attempts failed. Returning raw transcript.", Self.maxAttempts)
                    return Result(text: text, usedFallback: true)
                }
                // Non-retryable (invalid key, malformed request) — surface it.
                throw error
            }
        }

        return Result(text: text, usedFallback: true)
    }

    // MARK: - Retry classification

    /// 5xx + 429 + transport-level errors are transient → retry, then raw fallback.
    /// 401 (bad key) and other 4xx indicate a configuration problem → surface immediately.
    private static func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? OpenAIError {
            switch apiError {
            case .httpError(let code, _) where code == 429 || (500..<600).contains(code):
                return true
            case .invalidResponse, .emptyResult:
                return true
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .resourceUnavailable, .badServerResponse,
                 .secureConnectionFailed, .cannotLoadFromNetwork, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        if error is DecodingError { return true }
        return false
    }
}
