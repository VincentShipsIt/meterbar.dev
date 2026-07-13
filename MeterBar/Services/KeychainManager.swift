import Foundation
import Security

/// The four `SecItem*` primitives `KeychainManager` depends on, behind a
/// protocol so tests can drive the save/get/delete logic against an in-memory
/// fake instead of the real login keychain (which is unavailable / prompts on
/// CI runners). Signatures mirror the C API 1:1 so the production backend is a
/// thin pass-through.
nonisolated protocol KeychainBackend {
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(query: [String: Any]) -> OSStatus
    func copyMatching(query: [String: Any], result: inout AnyObject?) -> OSStatus
    func delete(query: [String: Any]) -> OSStatus
}

/// Production backend: forwards straight to the Security framework.
nonisolated struct SecItemKeychainBackend: KeychainBackend {
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
nonisolated final class KeychainManager {
    static let shared = KeychainManager()

    private let currentService: String
    private let legacyServices: [String]
    private let backend: KeychainBackend

    /// Defaults to the real Security-framework backend so `shared` behaves
    /// exactly as before; tests inject an in-memory fake and service names.
    init(
        backend: KeychainBackend = SecItemKeychainBackend(),
        currentService: String = "dev.meterbar.app",
        legacyServices: [String] = ["dev.shipshit.meterbar", "com.agenticindiedev.quotaguard"]
    ) {
        self.backend = backend
        self.currentService = currentService
        self.legacyServices = legacyServices
    }

    func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        guard save(data: data, key: key, service: currentService) else { return false }

        // A legacy item must remain available until the replacement is safely in
        // the current service. Cleanup is best-effort because the current write
        // already succeeded and should remain usable even if Keychain cleanup is
        // temporarily denied.
        deleteLegacyItems(key: key)
        return true
    }

    func get(key: String) -> String? {
        switch read(key: key, service: currentService) {
        case let .value(value):
            deleteLegacyItems(key: key)
            return value
        case .failure:
            return nil
        case .notFound:
            break
        }

        for legacyService in legacyServices {
            switch read(key: key, service: legacyService) {
            case let .value(value):
                // Return the usable legacy value even if the migration write
                // fails, and only remove it after the current copy is durable.
                if let data = value.data(using: .utf8),
                   save(data: data, key: key, service: currentService) {
                    deleteLegacyItems(key: key)
                }
                return value
            case .notFound:
                continue
            case .failure:
                return nil
            }
        }

        return nil
    }

    @discardableResult
    func delete(key: String) -> Bool {
        // Always attempt every service. Leaving a legacy item behind would make
        // a deliberately removed credential reappear on the next launch.
        var allDeleted = true
        for service in [currentService] + legacyServices {
            let status = backend.delete(query: baseQuery(key: key, service: service))
            let deleted = status == errSecSuccess || status == errSecItemNotFound
            if !deleted {
                allDeleted = false
            }
        }
        return allDeleted
    }

    func hasKey(key: String) -> Bool {
        get(key: key) != nil
    }

    private enum ReadResult {
        case value(String)
        case notFound
        case failure
    }

    private func baseQuery(key: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func save(data: Data, key: String, service: String) -> Bool {
        let query = baseQuery(key: key, service: service)
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

    private func read(key: String, service: String) -> ReadResult {
        var query = baseQuery(key: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = backend.copyMatching(query: query, result: &result)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .failure
        }
        return .value(value)
    }

    private func deleteLegacyItems(key: String) {
        for service in legacyServices {
            _ = backend.delete(query: baseQuery(key: key, service: service))
        }
    }
}
