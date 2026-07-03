import Foundation
import Security

/// The four `SecItem*` primitives `KeychainManager` depends on, behind a
/// protocol so tests can drive the save/get/delete logic against an in-memory
/// fake instead of the real login keychain (which is unavailable / prompts on
/// CI runners). Signatures mirror the C API 1:1 so the production backend is a
/// thin pass-through.
protocol KeychainBackend {
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(query: [String: Any]) -> OSStatus
    func copyMatching(query: [String: Any], result: inout AnyObject?) -> OSStatus
    func delete(query: [String: Any]) -> OSStatus
}

/// Production backend: forwards straight to the Security framework.
struct SecItemKeychainBackend: KeychainBackend {
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func copyMatching(query: [String: Any], result: inout AnyObject?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    func delete(query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Minimal Keychain wrapper for the org API admin keys entered in Settings.
final class KeychainManager {
    static let shared = KeychainManager()

    private let service = "dev.shipshit.meterbar"
    private let backend: KeychainBackend

    /// Defaults to the real Security-framework backend so `shared` behaves
    /// exactly as before; tests inject an in-memory fake.
    init(backend: KeychainBackend = SecItemKeychainBackend()) {
        self.backend = backend
    }

    func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        // Update-then-add instead of delete-then-add. Two concurrent saves with a
        // delete/add pair can both delete and then race on add (one fails with
        // errSecDuplicateItem); SecItemUpdate has no such window.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = backend.update(query: query, attributes: attributes)

        switch updateStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            return backend.add(query: addQuery) == errSecSuccess
        default:
            return false
        }
    }

    func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = backend.copyMatching(query: query, result: &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    @discardableResult
    func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = backend.delete(query: query)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func hasKey(key: String) -> Bool {
        get(key: key) != nil
    }
}
