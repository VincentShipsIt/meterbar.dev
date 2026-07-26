import LocalAuthentication
import Security
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

    // MARK: - Prompt hygiene

    func testBackgroundPayloadQueryFailsWithoutAuthenticationUI() {
        let backend = RecordingKeychainBackend(
            status: errSecSuccess,
            result: Data("payload".utf8) as NSData
        )

        let outcome = ClaudeCredentialStore.keychainPayload(
            service: "Claude Code-credentials-c4394a73",
            mode: .background,
            backend: backend
        )

        XCTAssertEqual(outcome, .value(Data("payload".utf8)))
        XCTAssertEqual(
            backend.lastQuery[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )
        let context = backend.lastQuery[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
    }

    func testInteractivePayloadQueryAllowsAuthenticationUI() {
        let backend = RecordingKeychainBackend(
            status: errSecSuccess,
            result: Data("payload".utf8) as NSData
        )

        let outcome = ClaudeCredentialStore.keychainPayload(
            service: "Claude Code-credentials-c4394a73",
            mode: .interactive,
            backend: backend
        )

        XCTAssertEqual(outcome, .value(Data("payload".utf8)))
        XCTAssertNil(backend.lastQuery[kSecUseAuthenticationUI as String])
        XCTAssertNil(backend.lastQuery[kSecUseAuthenticationContext as String])
    }

    func testPayloadQueryPreservesSecurityStatusClasses() {
        let cases: [(OSStatus, ClaudeKeychainReadOutcome<Data>)] = [
            (errSecItemNotFound, .notFound),
            (errSecInteractionNotAllowed, .interactionRequired),
            (errSecUserCanceled, .denied),
            (errSecAuthFailed, .denied),
            (-9_999, .failure(-9_999))
        ]

        for (status, expected) in cases {
            let backend = RecordingKeychainBackend(status: status)
            XCTAssertEqual(
                ClaudeCredentialStore.keychainPayload(
                    service: "Claude Code-credentials-c4394a73",
                    mode: .interactive,
                    backend: backend
                ),
                expected
            )
        }
    }

    func testCanonicalInteractiveWalkOffersAtMostOnePromptAfterDenial() throws {
        let fixture = try makeDenialStore()
        let recorder = KeychainReadRecorder { service, mode in
            service == "Claude Code-credentials-ee16a9f4"
                ? .denied
                : .notFound
        }
        let store = ClaudeCredentialStore(
            readKeychainResult: { service, mode in recorder.read(service: service, mode: mode) },
            readFile: { _ in Data("file".utf8) },
            denialStore: fixture.store,
            isOAuthEnabled: { true },
            now: { Date(timeIntervalSince1970: 10_000) }
        )

        let data = store.credentialsData(
            for: .defaultAccount,
            mode: .interactive,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertEqual(data.flatMap { String(bytes: $0, encoding: .utf8) }, "file")
        XCTAssertEqual(recorder.calls, [
            .init(service: "Claude Code-credentials-ee16a9f4", mode: .interactive),
            .init(service: ClaudeCredentialResolver.bareKeychainService, mode: .background)
        ])
        XCTAssertEqual(
            fixture.store.deniedAt(for: "Claude Code-credentials-ee16a9f4"),
            Date(timeIntervalSince1970: 10_000)
        )
    }

    func testInteractiveFailureConsumesPromptBudgetForRemainingCandidates() throws {
        let fixture = try makeDenialStore()
        let recorder = KeychainReadRecorder { service, _ in
            service == "Claude Code-credentials-ee16a9f4"
                ? .failure(errSecInternalError)
                : .notFound
        }
        let store = ClaudeCredentialStore(
            readKeychainResult: { service, mode in recorder.read(service: service, mode: mode) },
            readFile: { _ in nil },
            denialStore: fixture.store,
            isOAuthEnabled: { true }
        )

        _ = store.credentialsDataResult(
            for: .defaultAccount,
            mode: .interactive,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertEqual(recorder.calls, [
            .init(service: "Claude Code-credentials-ee16a9f4", mode: .interactive),
            .init(service: ClaudeCredentialResolver.bareKeychainService, mode: .background)
        ])
    }

    func testBackgroundWalkSkipsCoolingServiceAndStillUsesFileFallback() throws {
        let fixture = try makeDenialStore()
        let service = "Claude Code-credentials-c4394a73"
        let now = Date(timeIntervalSince1970: 10_000)
        fixture.store.recordDenial(for: service, at: now)
        let recorder = KeychainReadRecorder { _, _ in .value(Data("unexpected".utf8)) }
        let store = ClaudeCredentialStore(
            readKeychainResult: { service, mode in recorder.read(service: service, mode: mode) },
            readFile: { _ in Data("file".utf8) },
            denialStore: fixture.store,
            isOAuthEnabled: { true },
            now: { now.addingTimeInterval(1) }
        )
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/Users/tester/.claude-work"
        )

        let data = store.credentialsData(
            for: account,
            mode: .background,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(data.flatMap { String(bytes: $0, encoding: .utf8) }, "file")
    }

    func testUserInitiatedWalkExplicitlyRetriesCoolingService() throws {
        let fixture = try makeDenialStore()
        let service = "Claude Code-credentials-c4394a73"
        let now = Date(timeIntervalSince1970: 10_000)
        fixture.store.recordDenial(for: service, at: now)
        let recorder = KeychainReadRecorder { _, _ in .value(Data("scoped".utf8)) }
        let store = ClaudeCredentialStore(
            readKeychainResult: { service, mode in recorder.read(service: service, mode: mode) },
            readFile: { _ in nil },
            denialStore: fixture.store,
            isOAuthEnabled: { true },
            now: { now.addingTimeInterval(1) }
        )
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/Users/tester/.claude-work"
        )

        let data = store.credentialsData(
            for: account,
            mode: .interactive,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertEqual(
            recorder.calls,
            [.init(service: service, mode: .interactive)]
        )
        XCTAssertEqual(data.flatMap { String(bytes: $0, encoding: .utf8) }, "scoped")
        XCTAssertNil(fixture.store.deniedAt(for: service))
    }

    func testBackgroundInteractionRequirementRecordsCooldownAndFallsBackToFile() throws {
        let fixture = try makeDenialStore()
        let now = Date(timeIntervalSince1970: 10_000)
        let service = "Claude Code-credentials-c4394a73"
        let store = ClaudeCredentialStore(
            readKeychainResult: { _, _ in .interactionRequired },
            readFile: { _ in Data("file".utf8) },
            denialStore: fixture.store,
            isOAuthEnabled: { true },
            now: { now }
        )
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/Users/tester/.claude-work"
        )

        let data = store.credentialsData(
            for: account,
            mode: .background,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertEqual(data.flatMap { String(bytes: $0, encoding: .utf8) }, "file")
        XCTAssertEqual(fixture.store.deniedAt(for: service), now)
    }

    func testInteractionBarrierRemainsDistinctWhenNoFileFallbackExists() throws {
        let fixture = try makeDenialStore()
        let store = ClaudeCredentialStore(
            readKeychainResult: { _, _ in .interactionRequired },
            readFile: { _ in nil },
            denialStore: fixture.store,
            isOAuthEnabled: { true }
        )
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/Users/tester/.claude-work"
        )

        XCTAssertEqual(
            store.credentialsDataResult(
                for: account,
                mode: .background,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ),
            .interactionRequired
        )
    }

    func testCoolingServiceRemainsInteractionBarrierInsteadOfBecomingMissing() throws {
        let fixture = try makeDenialStore()
        let now = Date(timeIntervalSince1970: 10_000)
        let service = "Claude Code-credentials-c4394a73"
        fixture.store.recordDenial(for: service, at: now)
        let store = ClaudeCredentialStore(
            readKeychainResult: { _, _ in .value(Data("unexpected".utf8)) },
            readFile: { _ in nil },
            denialStore: fixture.store,
            isOAuthEnabled: { true },
            now: { now.addingTimeInterval(1) }
        )
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/Users/tester/.claude-work"
        )

        XCTAssertEqual(
            store.credentialsDataResult(
                for: account,
                mode: .background,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ),
            .interactionRequired
        )
    }

    func testAbsentCandidatesRemainNotFound() throws {
        let fixture = try makeDenialStore()
        let store = ClaudeCredentialStore(
            readKeychainResult: { _, _ in .notFound },
            readFile: { _ in nil },
            denialStore: fixture.store,
            isOAuthEnabled: { true }
        )

        XCTAssertEqual(
            store.credentialsDataResult(
                for: .defaultAccount,
                mode: .background,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ),
            .notFound
        )
    }

    func testOAuthOptOutSkipsEveryKeychainQueryButLeavesFileFallbackAvailable() throws {
        let fixture = try makeDenialStore()
        let recorder = KeychainReadRecorder { _, _ in .value(Data("unexpected".utf8)) }
        let store = ClaudeCredentialStore(
            readKeychainResult: { service, mode in recorder.read(service: service, mode: mode) },
            readFile: { _ in Data("file".utf8) },
            denialStore: fixture.store,
            isOAuthEnabled: { false }
        )

        let data = store.credentialsData(
            for: .defaultAccount,
            mode: .interactive,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(data.flatMap { String(bytes: $0, encoding: .utf8) }, "file")
    }

    private func makeDenialStore() throws -> (
        store: ClaudeKeychainDenialStore,
        defaults: UserDefaults
    ) {
        let suite = "ClaudeCredentialResolverTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (ClaudeKeychainDenialStore(userDefaults: defaults), defaults)
    }
}

/// Records the paths a store probed. The store's readers are `@Sendable`, so a
/// captured `var` will not compile — a locked reference type is the substitute.
nonisolated private final class PathRecorder: @unchecked Sendable {
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

nonisolated private final class RecordingKeychainBackend: KeychainBackend {
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

nonisolated private final class KeychainReadRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let service: String
        let mode: ClaudeKeychainAccessMode
    }

    private let lock = NSLock()
    private let result: @Sendable (String, ClaudeKeychainAccessMode) -> ClaudeKeychainReadOutcome<Data>
    private var storage: [Call] = []

    init(
        result: @escaping @Sendable (
            String,
            ClaudeKeychainAccessMode
        ) -> ClaudeKeychainReadOutcome<Data>
    ) {
        self.result = result
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func read(
        service: String,
        mode: ClaudeKeychainAccessMode
    ) -> ClaudeKeychainReadOutcome<Data> {
        lock.lock()
        storage.append(Call(service: service, mode: mode))
        lock.unlock()
        return result(service, mode)
    }
}
