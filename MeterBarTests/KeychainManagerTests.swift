import Security
import XCTest
@testable import MeterBar

/// Exercises `KeychainManager`'s save/get/delete orchestration against an
/// in-memory backend. The real login keychain is unavailable (and prompts) on
/// CI runners, so the `KeychainBackend` seam lets us verify the update-then-add
/// fallback, UTF-8 round-tripping, and the not-found → nil path deterministically.
final class KeychainManagerTests: XCTestCase {
    private static let currentService = "dev.meterbar.app"
    private static let legacyService = "dev.shipshit.meterbar"
    private static let oldestLegacyService = "com.agenticindiedev.quotaguard"

    /// Minimal in-memory stand-in for the Security framework, keyed by service
    /// and account. Mirrors the real semantics the manager relies on: update on
    /// a missing item returns `errSecItemNotFound`, copy on a missing item
    /// returns `errSecItemNotFound`, and delete is idempotent at the manager.
    nonisolated private final class InMemoryKeychainBackend: KeychainBackend {
        private struct ItemKey: Hashable {
            let service: String
            let account: String
        }

        private var storage: [ItemKey: Data] = [:]
        private(set) var addCallCount = 0
        private(set) var updateCallCount = 0
        var addFailureServices: Set<String> = []
        var deleteFailureServices: Set<String> = []

        func seed(service: String, account: String, value: String) {
            storage[ItemKey(service: service, account: account)] = Data(value.utf8)
        }

        func value(service: String, account: String) -> String? {
            guard let data = storage[ItemKey(service: service, account: account)] else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private func itemKey(in query: [String: Any]) -> ItemKey? {
            guard let service = query[kSecAttrService as String] as? String,
                  let account = query[kSecAttrAccount as String] as? String else {
                return nil
            }
            return ItemKey(service: service, account: account)
        }

        func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
            updateCallCount += 1
            guard let itemKey = itemKey(in: query), storage[itemKey] != nil else {
                return errSecItemNotFound
            }
            guard let data = attributes[kSecValueData as String] as? Data else {
                return errSecParam
            }
            storage[itemKey] = data
            return errSecSuccess
        }

        func add(query: [String: Any]) -> OSStatus {
            addCallCount += 1
            guard let itemKey = itemKey(in: query),
                  let data = query[kSecValueData as String] as? Data else {
                return errSecParam
            }
            if addFailureServices.contains(itemKey.service) {
                return errSecAuthFailed
            }
            guard storage[itemKey] == nil else { return errSecDuplicateItem }
            storage[itemKey] = data
            return errSecSuccess
        }

        func copyMatching(query: [String: Any], result: inout AnyObject?) -> OSStatus {
            guard let itemKey = itemKey(in: query), let data = storage[itemKey] else {
                return errSecItemNotFound
            }
            result = data as AnyObject
            return errSecSuccess
        }

        func delete(query: [String: Any]) -> OSStatus {
            guard let itemKey = itemKey(in: query) else { return errSecParam }
            if deleteFailureServices.contains(itemKey.service) {
                return errSecAuthFailed
            }
            guard storage.removeValue(forKey: itemKey) != nil else { return errSecItemNotFound }
            return errSecSuccess
        }
    }

    private func makeManager() -> (KeychainManager, InMemoryKeychainBackend) {
        let backend = InMemoryKeychainBackend()
        return (KeychainManager(backend: backend), backend)
    }

    func testSaveThenGetRoundTrips() {
        let (manager, _) = makeManager()
        XCTAssertTrue(manager.save(key: "openai", value: "sk-secret"))
        XCTAssertEqual(manager.get(key: "openai"), "sk-secret")
    }

    func testFirstSaveFallsBackToAddAfterItemNotFound() {
        let (manager, backend) = makeManager()
        XCTAssertTrue(manager.save(key: "anthropic", value: "value-1"))
        // The item did not exist, so update reported not-found and the manager
        // fell back to add exactly once.
        XCTAssertEqual(backend.updateCallCount, 1)
        XCTAssertEqual(backend.addCallCount, 1)
    }

    func testOverwriteUsesUpdateWithoutAdding() {
        let (manager, backend) = makeManager()
        XCTAssertTrue(manager.save(key: "anthropic", value: "value-1"))
        XCTAssertTrue(manager.save(key: "anthropic", value: "value-2"))
        XCTAssertEqual(manager.get(key: "anthropic"), "value-2")
        // Second save updated in place — only the first save added.
        XCTAssertEqual(backend.addCallCount, 1)
        XCTAssertEqual(backend.updateCallCount, 2)
    }

    func testGetMissingKeyReturnsNil() {
        let (manager, _) = makeManager()
        XCTAssertNil(manager.get(key: "absent"))
    }

    func testHasKeyReflectsPresence() {
        let (manager, _) = makeManager()
        XCTAssertFalse(manager.hasKey(key: "cursor"))
        XCTAssertTrue(manager.save(key: "cursor", value: "token"))
        XCTAssertTrue(manager.hasKey(key: "cursor"))
    }

    func testDeleteRemovesKeyAndIsIdempotent() {
        let (manager, _) = makeManager()
        XCTAssertTrue(manager.save(key: "cursor", value: "token"))
        XCTAssertTrue(manager.delete(key: "cursor"))
        XCTAssertFalse(manager.hasKey(key: "cursor"))
        // Deleting an absent key still succeeds (errSecItemNotFound is tolerated).
        XCTAssertTrue(manager.delete(key: "cursor"))
    }

    func testKeysAreIsolatedByAccount() {
        let (manager, _) = makeManager()
        XCTAssertTrue(manager.save(key: "openai", value: "a"))
        XCTAssertTrue(manager.save(key: "anthropic", value: "b"))
        XCTAssertEqual(manager.get(key: "openai"), "a")
        XCTAssertEqual(manager.get(key: "anthropic"), "b")
        XCTAssertTrue(manager.delete(key: "openai"))
        XCTAssertNil(manager.get(key: "openai"))
        XCTAssertEqual(manager.get(key: "anthropic"), "b")
    }

    func testGetMigratesOldestLegacyItemAcrossTheFullChain() {
        let (manager, backend) = makeManager()
        backend.seed(service: Self.oldestLegacyService, account: "anthropic", value: "v1-key")

        XCTAssertEqual(manager.get(key: "anthropic"), "v1-key")
        XCTAssertEqual(
            backend.value(service: Self.currentService, account: "anthropic"),
            "v1-key"
        )
        XCTAssertNil(backend.value(service: Self.oldestLegacyService, account: "anthropic"))
    }

    func testNewerLegacyServiceWinsOverOldest() {
        let (manager, backend) = makeManager()
        backend.seed(service: Self.legacyService, account: "anthropic", value: "v16-key")
        backend.seed(service: Self.oldestLegacyService, account: "anthropic", value: "v1-key")

        XCTAssertEqual(manager.get(key: "anthropic"), "v16-key")
        XCTAssertEqual(
            backend.value(service: Self.currentService, account: "anthropic"),
            "v16-key"
        )
    }

    func testDeleteRemovesEveryServiceInTheChain() {
        let (manager, backend) = makeManager()
        XCTAssertTrue(manager.save(key: "anthropic", value: "current"))
        backend.seed(service: Self.legacyService, account: "anthropic", value: "v16-key")
        backend.seed(service: Self.oldestLegacyService, account: "anthropic", value: "v1-key")

        XCTAssertTrue(manager.delete(key: "anthropic"))
        XCTAssertNil(backend.value(service: Self.currentService, account: "anthropic"))
        XCTAssertNil(backend.value(service: Self.legacyService, account: "anthropic"))
        XCTAssertNil(backend.value(service: Self.oldestLegacyService, account: "anthropic"))
    }

    func testGetMigratesLegacyItemAfterCurrentWriteSucceeds() {
        let (manager, backend) = makeManager()
        backend.seed(service: Self.legacyService, account: "anthropic", value: "legacy-key")

        XCTAssertEqual(manager.get(key: "anthropic"), "legacy-key")
        XCTAssertEqual(
            backend.value(service: Self.currentService, account: "anthropic"),
            "legacy-key"
        )
        XCTAssertNil(backend.value(service: Self.legacyService, account: "anthropic"))
    }

    func testCurrentItemWinsWhenBothServicesContainAValue() {
        let (manager, backend) = makeManager()
        backend.seed(service: Self.currentService, account: "openai", value: "current-key")
        backend.seed(service: Self.legacyService, account: "openai", value: "legacy-key")

        XCTAssertEqual(manager.get(key: "openai"), "current-key")
        XCTAssertNil(backend.value(service: Self.legacyService, account: "openai"))
    }

    func testFailedMigrationReturnsAndPreservesLegacyItem() {
        let (manager, backend) = makeManager()
        backend.seed(service: Self.legacyService, account: "anthropic", value: "legacy-key")
        backend.addFailureServices = [Self.currentService]

        XCTAssertEqual(manager.get(key: "anthropic"), "legacy-key")
        XCTAssertNil(backend.value(service: Self.currentService, account: "anthropic"))
        XCTAssertEqual(
            backend.value(service: Self.legacyService, account: "anthropic"),
            "legacy-key"
        )
    }

    func testSuccessfulSaveRemovesStaleLegacyItem() {
        let (manager, backend) = makeManager()
        backend.seed(service: Self.legacyService, account: "openai", value: "legacy-key")

        XCTAssertTrue(manager.save(key: "openai", value: "current-key"))
        XCTAssertEqual(
            backend.value(service: Self.currentService, account: "openai"),
            "current-key"
        )
        XCTAssertNil(backend.value(service: Self.legacyService, account: "openai"))
    }

    func testDeleteRemovesCurrentAndLegacyItems() {
        let (manager, backend) = makeManager()
        backend.seed(service: Self.currentService, account: "anthropic", value: "current-key")
        backend.seed(service: Self.legacyService, account: "anthropic", value: "legacy-key")

        XCTAssertTrue(manager.delete(key: "anthropic"))
        XCTAssertNil(backend.value(service: Self.currentService, account: "anthropic"))
        XCTAssertNil(backend.value(service: Self.legacyService, account: "anthropic"))
        XCTAssertNil(manager.get(key: "anthropic"))
    }

    func testAuthenticationManagerClearsCredentialAfterCompleteDelete() {
        let (keychain, backend) = makeManager()
        let account = ApiProvider.anthropic.keychainKey
        backend.seed(service: Self.currentService, account: account, value: "current-key")
        let authentication = AuthenticationManager(keychain: keychain)

        XCTAssertTrue(authentication.removeAdminKey(for: .anthropic))
        XCTAssertNil(authentication.claudeAdminKey)
        XCTAssertFalse(authentication.isClaudeAuthenticated)
    }

    func testAuthenticationManagerKeepsSurvivingCredentialAfterPartialDelete() {
        let (keychain, backend) = makeManager()
        let account = ApiProvider.anthropic.keychainKey
        backend.seed(service: Self.currentService, account: account, value: "current-key")
        let authentication = AuthenticationManager(keychain: keychain)

        // Simulate a stale legacy item appearing after initialization. The
        // current item deletes, but Keychain denies deletion of the legacy one.
        backend.seed(service: Self.legacyService, account: account, value: "legacy-key")
        backend.deleteFailureServices = [Self.legacyService]

        XCTAssertFalse(authentication.removeAdminKey(for: .anthropic))
        XCTAssertEqual(authentication.claudeAdminKey, "legacy-key")
        XCTAssertTrue(authentication.isClaudeAuthenticated)
        XCTAssertEqual(
            backend.value(service: Self.legacyService, account: account),
            "legacy-key"
        )
    }
}
