import Foundation
import Security

/// File overview:
/// Thin wrapper around the macOS Keychain Services API for storing per-provider API keys used by
/// the OpenAI-compatible suggestion engine.
///
/// Why this file exists:
/// API keys are user secrets and must not live in `UserDefaults` (plaintext) or in any synced
/// preference. Tabby had no Keychain code yet, so this file centralizes the small amount of
/// `SecItem*` plumbing in one tested-shaped surface and keeps the rest of the app free of
/// CoreFoundation casting.
///
/// Keys are scoped by `service` (constant per consumer) and `account` (per provider preset)
/// so multiple providers can hold separate keys side by side.
struct KeychainCredentialStore {
    /// Service identifier used as the Keychain `kSecAttrService` value for the OpenAI engine.
    /// Lives here so callers don't have to coordinate magic strings.
    static let openAIEngineService = "com.tabby.openai-engine"

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataEncoding

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain operation failed (status \(status))."
            case .dataEncoding:
                return "Keychain data could not be encoded as UTF-8."
            }
        }
    }

    /// Reads the stored secret for the (service, account) pair. Returns `nil` when the item
    /// does not exist; throws only on unexpected Keychain failures so callers can distinguish
    /// "no key configured" from "Keychain is broken right now."
    func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataEncoding
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Stores `secret` for the (service, account) pair, replacing any existing value. Passing an
    /// empty string deletes the entry so the UI can use a single SecureField to both set and
    /// clear the key.
    func store(service: String, account: String, secret: String) throws {
        guard !secret.isEmpty else {
            try delete(service: service, account: account)
            return
        }

        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.dataEncoding
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Try update first; if no record exists, fall through to add.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            // `kSecAttrAccessibleAfterFirstUnlock` matches the behavior users expect from a menu
            // bar app: the key is readable as soon as the user logs in but is still encrypted at
            // rest before the first unlock.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Removes the secret. `errSecItemNotFound` is treated as success so callers can clear a
    /// missing key without inspecting the error type.
    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
