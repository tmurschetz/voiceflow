/// App-wide configuration constants.
///
/// V2 architecture: fully local-first. The only credential is the user's own
/// OpenAI API key, stored in the Keychain (see KeychainStore). Model choices
/// live in AppSettings (TranscribeModel / TextModel catalogues) — the user
/// picks them in Settings.
enum Config {

    /// Where users create their API key during onboarding.
    static let apiKeysURL = "https://platform.openai.com/api-keys"
}
