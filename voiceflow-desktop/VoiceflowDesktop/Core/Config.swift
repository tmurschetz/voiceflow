/// App-wide configuration constants.
///
/// V2 architecture: fully local-first. The only credential is the user's own
/// OpenAI API key, stored in the Keychain (see KeychainStore). There is no
/// app backend, no login, no server-side prompts.
enum Config {

    // MARK: - Models

    /// Chat model for tone-of-voice rewriting (Private/Business/Calm).
    /// gpt-4o-mini: fast, cheap (~$0.15/1M input tokens), more than good enough
    /// for text editing tasks.
    static let chatModel = "gpt-4o-mini"

    /// Primary transcription model. gpt-4o-mini-transcribe is half the price of
    /// whisper-1 ($0.003/min vs $0.006/min) with lower latency and better WER.
    /// OpenAIClient falls back to whisper-1 automatically if the account lacks access.
    static let transcribeModel = "gpt-4o-mini-transcribe"

    // MARK: - Links

    /// Where users create their API key during onboarding.
    static let apiKeysURL = "https://platform.openai.com/api-keys"
}
