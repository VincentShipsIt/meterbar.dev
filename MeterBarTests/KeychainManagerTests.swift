import Security
import XCTest
@testable import MeterBar

/// Exercises `KeychainManager`'s save/get/delete orchestration against an
/// in-memory backend. The real login keychain is unavailable (and prompts) on
/// CI runners, so the `KeychainBackend` seam lets us verify the update-then-add
/// fallback, UTF-8 round-tripping, and the not-found → nil path deterministically.
final class KeychainManagerTests: XCTestCase {

    /// Minimal in-memory stand-in for the Security framework, keyed by the
    /// `kSecAttrAccount` value. Mirrors the real semantics the manager relies on:
    /// update on a missing item returns `errSecItemNotFound`, copy on a missing
    /// item returns `errSecItemNotFound`, delete is idempotent.
    private final class InMemoryKeychainBackend: KeychainBackend {
        private(set) var storage: [String: Data] = [:]
        private(set) var addCallCount = 0
        private(set) var updateCallCount = 0

        private func account(in query: [String: Any]) -> String? {
            query[kSecAttrAccount as String] as? String
        }

        func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
            updateCallCount += 1
            guard let account = account(in: query), storage[account] != nil else {
                return errSecItemNotFound
            }
            guard let data = attributes[kSecValueData as String] as? Data else {
                return errSecParam
            }
            storage[account] = data
            return errSecSuccess
        }

        func add(query: [String: Any]) -> OSStatus {
            addCallCount += 1
            guard let account = account(in: query),
                  let data = query[kSecValueData as String] as? Data else {
                return errSecParam
            }
            guard storage[account] == nil else { return errSecDuplicateItem }
            storage[account] = data
            return errSecSuccess
        }

        func copyMatching(query: [String: Any], result: inout AnyObject?) -> OSStatus {
            guard let account = account(in: query), let data = storage[account] else {
                return errSecItemNotFound
            }
            result = data as AnyObject
            return errSecSuccess
        }

        func delete(query: [String: Any]) -> OSStatus {
            guard let account = account(in: query) else { return errSecParam }
            guard storage.removeValue(forKey: account) != nil else { return errSecItemNotFound }
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
}
