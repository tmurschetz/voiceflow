/// App-wide configuration constants.
///
/// For V1 internal beta — API keys are compile-time constants.
/// In V2, move to a backend-fetched config (Supabase remote config or similar).
enum Config {

    // MARK: - Transcription

    /// OpenAI API key used for Whisper speech-to-text.
    /// Model: whisper-1 ($0.006/min — negligible for typical 5-30s dictations)
    /// Obtain from: https://platform.openai.com/api-keys
    static let openAIAPIKey = "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"

    // MARK: - Web App

    /// Base URL of the Lovable web app.
    /// Used for the "Forgot password?" link in the login screen.
    static let webAppURL = "https://voiceflow.lovable.app"
}
