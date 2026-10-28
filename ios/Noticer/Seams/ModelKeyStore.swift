import Foundation
import NoticerAgent
import Security

enum ModelKeyStoreError: LocalizedError {
    case empty
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a key before saving."
        case .status:
            return "The Keychain did not save the key."
        }
    }
}

/// The Meta Model API key is never stored in the repo.
///
/// On device, a saved Keychain item wins. Otherwise the process environment
/// `META_API_KEY` is used. The key is not written to logs.
enum ModelKeyStore {
    static let environmentVariable = MuseSparkModelClient.apiKeyEnvironmentVariable
    private static let service = "app.noticer.Noticer"
    private static let account = environmentVariable

    static func environmentKey() -> String? {
        let value = ProcessInfo.processInfo.environment[environmentVariable]
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    static func currentKey() -> String? {
        if let saved = keychainKey() {
            return saved
        }
        return environmentKey()
    }

    static func statusLine() -> String {
        if keychainKey() != nil {
            return "A key is saved in the Keychain."
        }
        if environmentKey() != nil {
            return "META_API_KEY is set in the environment."
        }
        return "No key saved. Replay does not need one."
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ModelKeyStoreError.empty
        }
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ModelKeyStoreError.status(status)
        }
    }

    static func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelKeyStoreError.status(status)
        }
    }

    private static func keychainKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        let value = String(data: data, encoding: .utf8)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
