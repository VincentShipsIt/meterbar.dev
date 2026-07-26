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
}
