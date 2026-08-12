import Foundation
import Security

/// Minimal Keychain wrapper for storing the user's OpenAI API key.
///
/// The key never leaves the Mac: it is stored as a generic password item,
/// accessible only after first unlock, on this device only.
enum KeychainStore {

    private static let service = "com.voiceflow.desktop"
    private static let account = "openai_api_key"
    private static let deviceTokenAccount = "account_device_token"

    /// Test-harness override (in-memory only, set by SelfTest). Freshly built
    /// ad-hoc test binaries get silently denied by the Keychain ACL in headless
    /// runs; the harness then reads the key via /usr/bin/security instead and
    /// parks it here. NEVER persisted — the stored item's ACL stays untouched.
    static var testOverrideAPIKey: String?

    /// The user's OpenAI API key, or nil if not yet configured.
    static var apiKey: String? {
        get { testOverrideAPIKey ?? read(account: account) }
        set { write(account: account, value: newValue) }
    }

    /// Random 256-bit token identifying this Mac towards the accounts service
    /// (managed access — see AccountService). Not an API key.
    static var accountDeviceToken: String? {
        get { read(account: deviceTokenAccount) }
        set { write(account: deviceTokenAccount, value: newValue) }
    }

    // MARK: - Generic password plumbing

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func write(account: String, value: String?) {
        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty,
              let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// True once the user has stored a key.
    static var hasAPIKey: Bool { apiKey != nil }

    /// Masked representation for display, e.g. "sk-…RYA" — never show the full key.
    static var maskedKey: String {
        guard let key = apiKey, key.count > 8 else { return "—" }
        return "\(key.prefix(5))…\(key.suffix(4))"
    }
}
