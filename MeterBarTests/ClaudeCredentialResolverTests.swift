import XCTest
@testable import MeterBar

/// Covers how a Claude Code account maps onto the credential Claude Code itself
/// wrote: the per-profile Keychain service name, the candidate ordering, and the
/// on-disk fallback. The derivation is pure, so it is fully testable without
/// touching the real Keychain.
final class ClaudeCredentialResolverTests: XCTestCase {
    // MARK: - Keychain service-name derivation

    /// Claude Code names its Keychain item `Claude Code-credentials-<suffix>`
    /// where the suffix is the first 8 lowercase hex characters of the SHA-256
    /// of the *resolved* config-directory path, with no trailing newline.
    /// Reproduce a vector with: `printf '%s' <path> | shasum -a 256 | cut -c1-8`.
    func testKeychainServiceIsFirstEightHexCharactersOfConfigDirSHA256() {
        XCTAssertEqual(
            ClaudeCredentialResolver.keychainService(forConfigDirectory: "/Users/tester/.claude"),
            "Claude Code-credentials-ee16a9f4"
        )
        XCTAssertEqual(
            ClaudeCredentialResolver.keychainService(forConfigDirectory: "/Users/tester/.claude-work"),
            "Claude Code-credentials-c4394a73"
        )
    }

    func testKeychainServiceIsPathSensitive() {
        let claude = ClaudeCredentialResolver.keychainService(forConfigDirectory: "/Users/tester/.claude")
        let work = ClaudeCredentialResolver.keychainService(forConfigDirectory: "/Users/tester/.claude-work")
        XCTAssertNotEqual(claude, work)
    }

    // MARK: - Effective config directory

    func testAccountConfigDirectoryWinsOverTheEnvironment() {
        let account = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "~/.claude-work")

        XCTAssertEqual(
            ClaudeCredentialResolver.configDirectory(
                for: account,
                environment: ["CLAUDE_CONFIG_DIR": "/elsewhere/.claude"],
                realHomeDirectory: "/Users/tester"
            ),
            "/Users/tester/.claude-work"
        )
    }

    func testBlankAccountConfigDirectoryFallsBackToTheEnvironmentProfile() {
        let account = ClaudeCodeAccount(id: ClaudeCodeAccount.defaultID, name: "Default", configDirectory: "   ")

        XCTAssertEqual(
            ClaudeCredentialResolver.configDirectory(
                for: account,
                environment: ["CLAUDE_CONFIG_DIR": "/Users/tester/.claude-genfeedai"],
                realHomeDirectory: "/Users/tester"
            ),
            "/Users/tester/.claude-genfeedai"
        )
    }

    func testUnscopedDefaultAccountResolvesToClaudeUnderRealHome() {
        XCTAssertEqual(
            ClaudeCredentialResolver.configDirectory(
                for: .defaultAccount,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ),
            "/Users/tester/.claude"
        )
    }

    // MARK: - Candidate ordering

    func testCanonicalProfileTriesSuffixedThenBareThenFile() {
        let candidates = ClaudeCredentialResolver.candidates(
            for: .defaultAccount,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertEqual(candidates, [
            .keychain(service: "Claude Code-credentials-ee16a9f4"),
            .keychain(service: ClaudeCredentialResolver.bareKeychainService),
            .file(path: "/Users/tester/.claude/.credentials.json")
        ])
    }

    /// The bare item belongs to whichever identity last logged in unscoped, so a
    /// scoped profile reaching it would report another account's usage. Excluding
    /// it makes that cross-identity contamination impossible by construction —
    /// the guarantee previously bought by refusing OAuth for scoped profiles.
    func testScopedProfileNeverFallsBackToTheBareKeychainItem() {
        let account = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/Users/tester/.claude-work")

        let candidates = ClaudeCredentialResolver.candidates(
            for: account,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertEqual(candidates, [
            .keychain(service: "Claude Code-credentials-c4394a73"),
            .file(path: "/Users/tester/.claude-work/.credentials.json")
        ])
        XCTAssertFalse(candidates.contains(.keychain(service: ClaudeCredentialResolver.bareKeychainService)))
    }

    func testEnvironmentScopedDefaultAccountAlsoSkipsTheBareKeychainItem() {
        let candidates = ClaudeCredentialResolver.candidates(
            for: .defaultAccount,
            environment: ["CLAUDE_CONFIG_DIR": "/Users/tester/.claude-work"],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertFalse(candidates.contains(.keychain(service: ClaudeCredentialResolver.bareKeychainService)))
        XCTAssertEqual(candidates.first, .keychain(service: "Claude Code-credentials-c4394a73"))
    }

    // MARK: - Store (candidate walk)

    func testStoreReturnsTheFirstCandidateThatResolves() {
        let store = ClaudeCredentialStore(
            readKeychain: { service in
                service == "Claude Code-credentials-c4394a73" ? Data("scoped".utf8) : nil
            },
            readFile: { _ in Data("file".utf8) }
        )
        let account = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/Users/tester/.claude-work")

        let data = store.credentialsData(for: account, environment: [:], realHomeDirectory: "/Users/tester")

        XCTAssertEqual(data.flatMap { String(bytes: $0, encoding: .utf8) }, "scoped")
    }

    func testStoreFallsBackToTheProfileCredentialsFileWhenTheKeychainIsEmpty() {
        let recorder = PathRecorder()
        let store = ClaudeCredentialStore(
            readKeychain: { _ in nil },
            readFile: { path in
                recorder.record(path)
                return Data("file".utf8)
            }
        )
        let account = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/Users/tester/.claude-work")

        let data = store.credentialsData(for: account, environment: [:], realHomeDirectory: "/Users/tester")

        XCTAssertEqual(data.flatMap { String(bytes: $0, encoding: .utf8) }, "file")
        XCTAssertEqual(recorder.paths, ["/Users/tester/.claude-work/.credentials.json"])
    }

    func testStoreReturnsNilWhenNoCandidateResolves() {
        let store = ClaudeCredentialStore(readKeychain: { _ in nil }, readFile: { _ in nil })

        XCTAssertNil(store.credentialsData(
            for: .defaultAccount,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        ))
    }

    /// An empty blob is not a credential; treating it as a hit would shadow a
    /// perfectly good file fallback behind a stale, emptied Keychain item.
    func testStoreSkipsEmptyCandidatePayloads() {
        let store = ClaudeCredentialStore(
            readKeychain: { _ in Data() },
            readFile: { _ in Data("file".utf8) }
        )

        let data = store.credentialsData(
            for: .defaultAccount,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertEqual(data.flatMap { String(bytes: $0, encoding: .utf8) }, "file")
    }
}

/// Records the paths a store probed. The store's readers are `@Sendable`, so a
/// captured `var` will not compile — a locked reference type is the substitute.
private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(path)
    }
}
