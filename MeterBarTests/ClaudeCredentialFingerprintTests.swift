import LocalAuthentication
import Security
import XCTest
@testable import MeterBar

final class ClaudeCredentialFingerprintTests: XCTestCase {
    func testScopedKeychainFingerprintWinsOverFileFallback() {
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/Users/tester/.claude-work"
        )
        let keychain = ClaudeCredentialFingerprint.keychain(
            service: "Claude Code-credentials-c4394a73",
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        let file = ClaudeCredentialFingerprint.file(
            path: "/Users/tester/.claude-work/.credentials.json",
            modificationDate: Date(timeIntervalSince1970: 200),
            size: 42
        )
        let store = ClaudeCredentialFingerprintStore(
            readKeychain: { _ in keychain },
            readFile: { _ in file }
        )

        XCTAssertEqual(
            store.fingerprint(
                for: account,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ),
            keychain
        )
    }

    func testFingerprintFallsBackToCredentialFileMetadata() {
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/Users/tester/.claude-work"
        )
        let expected = ClaudeCredentialFingerprint.file(
            path: "/Users/tester/.claude-work/.credentials.json",
            modificationDate: Date(timeIntervalSince1970: 200),
            size: 42
        )
        let store = ClaudeCredentialFingerprintStore(
            readKeychain: { _ in nil },
            readFile: { _ in expected }
        )

        XCTAssertEqual(
            store.fingerprint(
                for: account,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ),
            expected
        )
    }

    func testFingerprintReturnsNilWhenNoCredentialMetadataExists() {
        let store = ClaudeCredentialFingerprintStore(
            readKeychain: { _ in nil },
            readFile: { _ in nil }
        )

        XCTAssertNil(store.fingerprint(
            for: .defaultAccount,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        ))
    }

    func testFingerprintChangesWhenKeychainModificationDateChanges() {
        let service = "Claude Code-credentials-c4394a73"
        let before = ClaudeCredentialFingerprint.keychain(
            service: service,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        let after = ClaudeCredentialFingerprint.keychain(
            service: service,
            modificationDate: Date(timeIntervalSince1970: 101)
        )

        XCTAssertNotEqual(before, after)
    }

    func testFingerprintChangesWhenFileSizeChangesAtSameModificationDate() {
        let path = "/Users/tester/.claude-work/.credentials.json"
        let date = Date(timeIntervalSince1970: 100)
        let before = ClaudeCredentialFingerprint.file(path: path, modificationDate: date, size: 40)
        let after = ClaudeCredentialFingerprint.file(path: path, modificationDate: date, size: 41)

        XCTAssertNotEqual(before, after)
    }

    func testFingerprintQueryAlwaysFailsWithoutAuthenticationUI() {
        let service = "Claude Code-credentials-c4394a73"
        let date = Date(timeIntervalSince1970: 100)
        let backend = FingerprintRecordingKeychainBackend(
            status: errSecSuccess,
            result: [kSecAttrModificationDate as String: date] as NSDictionary
        )

        let outcome = ClaudeCredentialFingerprintStore.keychainFingerprint(
            service: service,
            backend: backend
        )

        XCTAssertEqual(
            outcome,
            .value(.keychain(service: service, modificationDate: date))
        )
        XCTAssertEqual(
            backend.lastQuery[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )
        let context = backend.lastQuery[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
    }

    func testFingerprintStoreSkipsCoolingKeychainServiceAndUsesFileMetadata() throws {
        let suite = "ClaudeCredentialFingerprintTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let denialStore = ClaudeKeychainDenialStore(userDefaults: defaults)
        let now = Date(timeIntervalSince1970: 10_000)
        let service = "Claude Code-credentials-c4394a73"
        denialStore.recordDenial(for: service, at: now)
        let recorder = FingerprintReadRecorder()
        let expected = ClaudeCredentialFingerprint.file(
            path: "/Users/tester/.claude-work/.credentials.json",
            modificationDate: now,
            size: 42
        )
        let store = ClaudeCredentialFingerprintStore(
            readKeychainResult: { service in recorder.read(service: service) },
            readFile: { _ in expected },
            denialStore: denialStore,
            isOAuthEnabled: { true },
            now: { now.addingTimeInterval(1) }
        )
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/Users/tester/.claude-work"
        )

        XCTAssertEqual(
            store.fingerprint(
                for: account,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ),
            expected
        )
        XCTAssertTrue(recorder.services.isEmpty)
    }

    func testFingerprintOAuthOptOutPerformsNoKeychainQuery() throws {
        let suite = "ClaudeCredentialFingerprintOptOutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let recorder = FingerprintReadRecorder()
        let store = ClaudeCredentialFingerprintStore(
            readKeychainResult: { service in recorder.read(service: service) },
            readFile: { _ in nil },
            denialStore: ClaudeKeychainDenialStore(userDefaults: defaults),
            isOAuthEnabled: { false }
        )

        XCTAssertNil(store.fingerprint(
            for: .defaultAccount,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        ))
        XCTAssertTrue(recorder.services.isEmpty)
    }
}

nonisolated private final class FingerprintRecordingKeychainBackend: KeychainBackend {
    private(set) var lastQuery: [String: Any] = [:]
    let status: OSStatus
    let result: AnyObject?

    init(status: OSStatus, result: AnyObject? = nil) {
        self.status = status
        self.result = result
    }

    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        _ = query
        _ = attributes
        return errSecUnimplemented
    }

    func add(query: [String: Any]) -> OSStatus {
        _ = query
        return errSecUnimplemented
    }

    func copyMatching(query: [String: Any], result: inout AnyObject?) -> OSStatus {
        lastQuery = query
        result = self.result
        return status
    }

    func delete(query: [String: Any]) -> OSStatus {
        _ = query
        return errSecUnimplemented
    }
}

nonisolated private final class FingerprintReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var services: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func read(service: String) -> ClaudeKeychainReadOutcome<ClaudeCredentialFingerprint> {
        lock.lock()
        storage.append(service)
        lock.unlock()
        return .notFound
    }
}
