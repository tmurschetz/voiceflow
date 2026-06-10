import Foundation

// MARK: - ProcessingMode

/// The three dictation modes. Each can be personalised with a free-text
/// instruction from Settings (AppSettings.instruction(for:)).
enum ProcessingMode: String, CaseIterable {
    case `private` = "private"
    case business  = "business"
    case random    = "random"

    var displayName: String {
        switch self {
        case .private:  return "Privat"
        case .business: return "Business"
        case .random:   return "Random"
        }
    }

    var shortDescription: String {
        switch self {
        case .private:  return "Leichte Korrektur — dein Wortlaut bleibt"
        case .business: return "Professioneller, geschäftstauglicher Ton"
        case .random:   return "Deine Regeln — ganz nach deiner Instruktion"
        }
    }

    var sfSymbol: String {
        switch self {
        case .private:  return "person.fill"
        case .business: return "briefcase.fill"
        case .random:   return "sparkles"
        }
    }

    /// Builds the full system prompt for this mode, including the user's
    /// custom instruction when present.
    func systemPrompt(userInstruction: String) -> String {
        let shared = """
        Universal rules (always apply, highest priority):
        - Respond ONLY with the transformed text. No explanations, no quotes, no preamble.
        - Mirror the input language. German or Swiss German dialect input → output in Swiss \
        Standard German (Schweizer Hochdeutsch): always use "ss" instead of "ß", Swiss \
        vocabulary and phrasing. Never output dialect spelling. English input → English output.
        - Mirror the speaker's register: if they use du/dich/dir/dein, keep Du-form; if they \
        use Sie/Ihnen, keep Sie-form; if unclear, use Sie-form (German) or neutral (English).
        - Apply self-corrections: when the speaker corrects themselves mid-sentence \
        ("am Montag — nein, am Dienstag"), keep only the corrected version.
        - Remove filler words (ähm, äh, halt, quasi, sozusagen, um, uh, like, you know).
        - Never add anything that was not said: no salutations, no closings, no subject \
        lines, no extra sentences — unless the user's custom instruction explicitly asks for it.
        - Format numbers, dates, e-mail addresses and URLs properly.
        """

        let base: String
        switch self {
        case .private:
            base = """
            You are a transcription editor for a dictation tool. Lightly clean up the spoken \
            input: fix punctuation, capitalisation and obvious transcription errors, apply \
            self-corrections, remove fillers. Do NOT rewrite, restructure or change the \
            meaning, vocabulary or tone of what was said.
            """
        case .business:
            base = """
            You are a professional writing editor for a dictation tool. Rewrite the spoken \
            input in a polished, professional register — direct and concise, Swiss business \
            style, no flowery phrasing. Keep the same format and roughly the same length as \
            what was said. Fix grammar, tighten phrasing, remove fillers — but do not add \
            new content or change the meaning.
            """
        case .random:
            base = """
            You are a flexible text transformer for a dictation tool. Your behaviour is \
            defined primarily by the user's custom instruction below. If no custom \
            instruction is given, apply a light cleanup only (punctuation, fillers, \
            self-corrections) and keep the speaker's wording.
            """
        }

        let instruction = userInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let personalisation = instruction.isEmpty ? "" : """


        User's custom instruction for this mode (apply it faithfully; it overrides style \
        defaults but never the universal rules):
        «\(instruction)»
        """

        return base + "\n\n" + shared + personalisation
    }
}

// MARK: - ModeProcessor

/// Applies the tone-of-voice transformation by calling the OpenAI chat API directly
/// with the user's own key. No app backend involved.
///
/// Resilience: transient failures (429/5xx, timeouts, connection loss) are retried
/// once after a visible 5-second countdown; if all attempts fail, the raw transcript
/// is returned so the user never loses a dictation.
final class ModeProcessor {

    private let client = OpenAIClient.shared

    // MARK: - Result / events

    struct Result {
        let text: String
        /// True when all retries failed and we returned the raw transcript instead.
        let usedFallback: Bool
    }

    typealias RetryEvent = PipelineRetryEvent

    private static let maxAttempts = 2
    private static let retryDelaySeconds = 5

    // MARK: - Process

    func process(
        text: String,
        mode: ProcessingMode,
        userInstruction: String,
        textModel: String,
        onRetry: (@MainActor @Sendable (RetryEvent) async -> Void)? = nil
    ) async throws -> Result {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(text: text, usedFallback: false)
        }
        guard let apiKey = KeychainStore.apiKey else {
            throw OpenAIError.missingAPIKey
        }

        let systemPrompt = mode.systemPrompt(userInstruction: userInstruction)

        // Predicted Outputs speed up editing tasks where output ≈ input
        // (Privat/Business). Random with a custom instruction can transform the
        // text arbitrarily (translate, restructure) — prediction would be
        // rejected and only cost extra, so skip it there.
        let predictOutput = !(mode == .random
            && !userInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        for attempt in 1...Self.maxAttempts {
            do {
                let polished = try await client.chat(
                    systemPrompt: systemPrompt,
                    userText: text,
                    model: textModel,
                    apiKey: apiKey,
                    predictOutput: predictOutput
                )
                return Result(text: polished, usedFallback: false)

            } catch {
                let retryable = OpenAIRetry.isRetryable(error)
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
                    NSLog("[ModeProcessor] All %d attempts failed. Returning raw transcript.", Self.maxAttempts)
                    return Result(text: text, usedFallback: true)
                }
                throw error
            }
        }

        return Result(text: text, usedFallback: true)
    }

}
