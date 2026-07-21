import Foundation

/// App-wide configuration constants.
///
/// Architecture: local-first at runtime — dictation goes device → OpenAI with a
/// key from the Keychain (BYOK, or provisioned once via the accounts service).
enum Config {

    /// Where users create their API key during onboarding (bring-your-own-key).
    static let apiKeysURL = "https://platform.openai.com/api-keys"

    /// Base URL of the accounts (key-issuing) service — see voiceflow-backend/.
    /// Contacted ONLY for registration/approval/key pickup; dictation traffic
    /// never touches it. Overridable for local testing:
    ///   defaults write com.voiceflow.desktop accountServiceURL http://localhost:8787
    static var accountServiceURL: String {
        UserDefaults.standard.string(forKey: "accountServiceURL")
            ?? "https://voiceflow-accounts.tmurschetz.workers.dev"
    }
}
