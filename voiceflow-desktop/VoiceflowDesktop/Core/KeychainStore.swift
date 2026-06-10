import Foundation
import Security

/// Minimal Keychain wrapper for storing the user's OpenAI API key.
///
/// The key never leaves the Mac: it is stored as a generic password item,
/// accessible only after first unlock, on this device only.
enum KeychainStore {

    private static let service = "com.voiceflow.desktop"
    private static let account = "openai_api_key"

    /// The user's OpenAI API key, or nil if not yet configured.
    static var apiKey: String? {
        get {
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
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty
            else { return nil }
            return key
        }
        set {
            let base: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty,
                  let data = newValue.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// True once the user has stored a key.
    static var hasAPIKey: Bool { apiKey != nil }

    /// Masked representation for display, e.g. "sk-…RYA" — never show the full key.
    static var maskedKey: String {
        guard let key = apiKey, key.count > 8 else { return "—" }
        return "\(key.prefix(5))…\(key.suffix(4))"
    }
}
