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
    ///
    /// Prompt structure (precedence order):
    ///   1. ABSOLUTE rule — output only the transformed text. Never overridable,
    ///      because the app inserts the raw response into a text field; any
    ///      preamble like "Here's your text:" would be pasted verbatim.
    ///   2. The user's custom instruction — takes precedence over everything below.
    ///   3. DEFAULT style (incl. the Swiss-Standard-German language default) —
    ///      applied only where the custom instruction is silent. This is what
    ///      lets a custom instruction say "output in Zürich dialect" and win,
    ///      instead of being clamped to Hochdeutsch by a hard-coded rule.
    func systemPrompt(userInstruction: String) -> String {
        let instruction = userInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasInstruction = !instruction.isEmpty

        let absolute = """
        ABSOLUTE RULE (never overridable): Respond with ONLY the transformed text — \
        no explanations, no quotes, no preamble, no commentary. This is the single rule \
        the user's instruction below cannot change.
        """

        // Language is a DEFAULT, not a hard rule — a custom instruction may
        // request a different output language or a spoken dialect and must win.
        let defaults = """
        Default style — apply each item ONLY where the user's custom instruction does not say otherwise:
        - Output language follows the input: German or Swiss-German speech → Swiss Standard \
        German (Schweizer Hochdeutsch, "ss" instead of "ß", Swiss vocabulary); English → English. \
        If the custom instruction asks for a different language or for spoken Swiss-German dialect \
        (Mundart), follow the instruction instead — including dialect spelling.
        - Mirror the speaker's register: du/dich/dir → Du-form; Sie/Ihnen → Sie-form; if unclear, \
        Sie-form (German) or neutral (English).
        - Apply self-corrections: "am Montag — nein, am Dienstag" → keep only the corrected version.
        - Remove filler words (ähm, äh, halt, quasi, sozusagen, um, uh, like, you know).
        - Don't add anything that wasn't said: no salutations, closings, subject lines or extra \
        sentences.
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
            defined PRIMARILY by the user's custom instruction below — follow it exactly, \
            even when it departs from the default style (e.g. writing in spoken dialect, \
            translating, or reformatting). If no custom instruction is given, apply a light \
            cleanup only and keep the speaker's wording.
            """
        }

        if hasInstruction {
            // Instruction sits ABOVE the defaults and is explicitly given precedence.
            return """
            \(base)

            \(absolute)

            USER'S CUSTOM INSTRUCTION FOR THIS MODE — this takes PRECEDENCE over the default \
            style below. Where it conflicts with a default (including the output language or \
            dialect), follow the instruction:
            «\(instruction)»

            \(defaults)
            """
        } else {
            return "\(base)\n\n\(absolute)\n\n\(defaults)"
        }
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
    /// Short delay: a stalled request is best retried quickly on a fresh
    /// connection. (The longer 5 s wait made sense only for a full server
    /// outage, which the raw-transcript fallback already covers.)
    private static let retryDelaySeconds = 2

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
