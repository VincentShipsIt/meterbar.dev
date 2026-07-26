import XCTest
@testable import MeterBar

final class ClaudeOAuthAccessCoordinatorTests: XCTestCase {
    private let account = ClaudeCodeAccount(
        id: UUID(),
        name: "Work",
        configDirectory: "/Users/tester/.claude-work"
    )

    func testValidCredentialSkipsDelegatedRefresh() async {
        let refresh = RefreshCallRecorder(result: .hardFailure)

        let result = await ClaudeOAuthAccessCoordinator.resolve(
            initialAccess: .valid(token: "current"),
            account: account,
            trigger: .background,
            refresh: { account, trigger in await refresh.run(account: account, trigger: trigger) },
            reread: { .missing }
        )

        XCTAssertEqual(result, .token("current"))
        let callCount = await refresh.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testMissingCredentialPreservesCLIFallbackWithoutSpawningStatus() async {
        let refresh = RefreshCallRecorder(result: .hardFailure)

        let result = await ClaudeOAuthAccessCoordinator.resolve(
            initialAccess: .missing,
            account: account,
            trigger: .background,
            refresh: { account, trigger in await refresh.run(account: account, trigger: trigger) },
            reread: { .valid(token: "unexpected") }
        )

        XCTAssertEqual(result, .missing)
        let callCount = await refresh.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testUnavailableCredentialDoesNotBecomeMissingOrSpawnRefresh() async {
        let refresh = RefreshCallRecorder(result: .hardFailure)

        let result = await ClaudeOAuthAccessCoordinator.resolve(
            initialAccess: .unavailable,
            account: account,
            trigger: .background,
            refresh: { account, trigger in await refresh.run(account: account, trigger: trigger) },
            reread: { .valid(token: "unexpected") }
        )

        XCTAssertEqual(result, .unavailable)
        let callCount = await refresh.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testExpiredCredentialRefreshesAndRereadsTokenOnce() async {
        let refresh = RefreshCallRecorder(result: .refreshed)
        let reread = AccessSequence([.valid(token: "rotated")])

        let result = await ClaudeOAuthAccessCoordinator.resolve(
            initialAccess: .expired,
            account: account,
            trigger: .userInitiated,
            refresh: { account, trigger in await refresh.run(account: account, trigger: trigger) },
            reread: { await reread.next() }
        )

        XCTAssertEqual(result, .token("rotated"))
        let callCount = await refresh.callCount
        let observedTrigger = await refresh.observedTrigger
        let rereadCount = await reread.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(observedTrigger, .userInitiated)
        XCTAssertEqual(rereadCount, 1)
    }

    func testChangedFingerprintWithoutAUsableTokenIsRefreshFailure() async {
        let refresh = RefreshCallRecorder(result: .refreshed)

        let result = await ClaudeOAuthAccessCoordinator.resolve(
            initialAccess: .expired,
            account: account,
            trigger: .background,
            refresh: { account, trigger in await refresh.run(account: account, trigger: trigger) },
            reread: { .expired }
        )

        XCTAssertEqual(result, .refreshFailed(.refreshed))
    }

    func testInconclusiveRefreshDoesNotRereadCredential() async {
        let refresh = RefreshCallRecorder(result: .inconclusive)
        let reread = AccessSequence([.valid(token: "unexpected")])

        let result = await ClaudeOAuthAccessCoordinator.resolve(
            initialAccess: .expired,
            account: account,
            trigger: .background,
            refresh: { account, trigger in await refresh.run(account: account, trigger: trigger) },
            reread: { await reread.next() }
        )

        XCTAssertEqual(result, .refreshFailed(.inconclusive))
        let rereadCount = await reread.callCount
        XCTAssertEqual(rereadCount, 0)
    }

    func testHardFailureBecomesRefreshFailure() async {
        let refresh = RefreshCallRecorder(result: .hardFailure)

        let result = await ClaudeOAuthAccessCoordinator.resolve(
            initialAccess: .expired,
            account: account,
            trigger: .background,
            refresh: { account, trigger in await refresh.run(account: account, trigger: trigger) },
            reread: { .valid(token: "unexpected") }
        )

        XCTAssertEqual(result, .refreshFailed(.hardFailure))
    }
}

private actor RefreshCallRecorder {
    private(set) var callCount = 0
    private(set) var observedTrigger: ClaudeTokenRefreshTrigger?
    private let result: ClaudeTokenRefreshResult

    init(result: ClaudeTokenRefreshResult) {
        self.result = result
    }

    func run(
        account: ClaudeCodeAccount,
        trigger: ClaudeTokenRefreshTrigger
    ) -> ClaudeTokenRefreshResult {
        _ = account
        callCount += 1
        observedTrigger = trigger
        return result
    }
}

private actor AccessSequence {
    private(set) var callCount = 0
    private var values: [ClaudeOAuthCredentialAccess]

    init(_ values: [ClaudeOAuthCredentialAccess]) {
        self.values = values
    }

    func next() -> ClaudeOAuthCredentialAccess {
        callCount += 1
        guard !values.isEmpty else { return .missing }
        return values.removeFirst()
    }
}
