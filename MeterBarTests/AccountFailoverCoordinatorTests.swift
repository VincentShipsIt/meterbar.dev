import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class AccountFailoverCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "AccountFailoverCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testRefreshSnapshotSwitchesDepletedClaudeAccountAndEmitsOneVisibleEvent() async {
        let accounts = ClaudeCodeAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", configDirectory: "/tmp/claude-fallback")
        let ordered = accounts.enabledAccounts
        let preferred = ordered[0]
        let fallback = ordered[1]
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        settings.setEnabled(true, for: .claudeCode)
        let switcher = CoordinatorCredentialSwitcher()
        let notifier = CoordinatorFailoverNotifier()
        let coordinator = AccountFailoverCoordinator(
            settings: settings,
            claudeAccounts: accounts,
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            credentialSwitcher: switcher,
            notifier: notifier
        )

        await coordinator.evaluate(
            claudeMetrics: [preferred.id: metrics(.claudeCode, used: 100), fallback.id: metrics(.claudeCode, used: 12)],
            codexMetrics: [:]
        )

        XCTAssertEqual(
            settings.activeAccountID(for: .claudeCode, orderedAccountIDs: ordered.map(\.id)),
            fallback.id
        )
        XCTAssertEqual(switcher.calls.count, 1)
        XCTAssertEqual(switcher.calls.first?.fromAccountID, preferred.id)
        XCTAssertEqual(switcher.calls.first?.toAccountID, fallback.id)
        XCTAssertEqual(notifier.events.map(\.toAccountName), ["Fallback"])
    }

    func testResetSnapshotSwitchesBackToPreferredAccount() async {
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/tmp/codex-fallback")
        let ordered = accounts.enabledAccounts
        let preferred = ordered[0]
        let fallback = ordered[1]
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        settings.setEnabled(true, for: .codexCli)
        settings.setActiveAccountID(fallback.id, for: .codexCli)
        let switcher = CoordinatorCredentialSwitcher()
        let notifier = CoordinatorFailoverNotifier()
        let coordinator = AccountFailoverCoordinator(
            settings: settings,
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            credentialSwitcher: switcher,
            notifier: notifier
        )

        await coordinator.evaluate(
            claudeMetrics: [:],
            codexMetrics: [preferred.id: metrics(.codexCli, used: 0), fallback.id: metrics(.codexCli, used: 40)]
        )

        XCTAssertEqual(settings.activeAccountID(for: .codexCli, orderedAccountIDs: ordered.map(\.id)), preferred.id)
        XCTAssertEqual(switcher.calls.first?.fromAccountID, fallback.id)
        XCTAssertEqual(switcher.calls.first?.toAccountID, preferred.id)
        XCTAssertEqual(notifier.events.first?.reason, .preferredAccountRecovered)
    }

    func testCredentialFailureDoesNotChangeLiveAccountOrNotify() async {
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/tmp/codex-fallback")
        let ordered = accounts.enabledAccounts
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        settings.setEnabled(true, for: .codexCli)
        let switcher = CoordinatorCredentialSwitcher(error: TestError.failed)
        let notifier = CoordinatorFailoverNotifier()
        let coordinator = AccountFailoverCoordinator(
            settings: settings,
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            credentialSwitcher: switcher,
            notifier: notifier
        )

        await coordinator.evaluate(
            claudeMetrics: [:],
            codexMetrics: [ordered[0].id: metrics(.codexCli, used: 100), ordered[1].id: metrics(.codexCli, used: 1)]
        )

        XCTAssertEqual(settings.activeAccountID(for: .codexCli, orderedAccountIDs: ordered.map(\.id)), ordered[0].id)
        XCTAssertTrue(notifier.events.isEmpty)
    }

    func testIneligibleCredentialLayoutDisablesFailoverBeforeAnyMutation() async {
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/tmp/codex-fallback")
        let ordered = accounts.enabledAccounts
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        settings.setEnabled(true, for: .codexCli)
        let switcher = CoordinatorCredentialSwitcher(
            eligibility: .ineligible("Atomic file exchange unavailable.")
        )
        let notifier = CoordinatorFailoverNotifier()
        let coordinator = AccountFailoverCoordinator(
            settings: settings,
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            credentialSwitcher: switcher,
            notifier: notifier
        )

        await coordinator.evaluate(
            claudeMetrics: [:],
            codexMetrics: [ordered[0].id: metrics(.codexCli, used: 100), ordered[1].id: metrics(.codexCli, used: 1)]
        )

        XCTAssertFalse(settings.isEnabled(for: .codexCli))
        XCTAssertTrue(switcher.calls.isEmpty)
        XCTAssertTrue(notifier.events.isEmpty)
    }

    @MainActor
    func testLiveNotifierUsesSharedPermissionAwareNotificationBoundary() async {
        let poster = RecordingUserNotificationPoster()
        let notifier = LiveAccountFailoverNotifier(notificationPoster: poster)
        let timestamp = Date(timeIntervalSince1970: 123)

        await notifier.notify(AccountFailoverEvent(
            provider: .codexCli,
            fromAccountID: UUID(),
            fromAccountName: "Primary",
            toAccountID: UUID(),
            toAccountName: "Fallback",
            reason: .activeAccountDepleted,
            timestamp: timestamp
        ))

        XCTAssertEqual(poster.posts.count, 1)
        XCTAssertEqual(poster.posts.first?.title, "Codex account switched")
        XCTAssertEqual(poster.posts.first?.body, "Primary → Fallback")
    }

    private func metrics(_ service: ServiceType, used: Double) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: UsageLimit(used: used, total: 100, resetTime: nil)
        )
    }
}

@MainActor
private final class RecordingUserNotificationPoster: UserNotificationPosting {
    struct Post {
        let identifier: String
        let title: String
        let body: String
    }

    private(set) var posts: [Post] = []

    func requestAuthorizationIfNeeded() {}

    func post(identifier: String, title: String, body: String) async -> Bool {
        posts.append(Post(identifier: identifier, title: title, body: body))
        return true
    }
}
private enum TestError: Error { case failed }

private final class CoordinatorCredentialSwitcher: AccountCredentialSwitching {
    private(set) var calls: [AccountCredentialSwitch] = []
    private let error: Error?
    private let switchEligibility: AccountCredentialSwitchEligibility

    init(
        error: Error? = nil,
        eligibility: AccountCredentialSwitchEligibility = .eligible
    ) {
        self.error = error
        switchEligibility = eligibility
    }

    func eligibility(for _: AccountFailoverProvider) -> AccountCredentialSwitchEligibility {
        switchEligibility
    }

    func switchCredentials(provider: AccountFailoverProvider, from: UUID, to: UUID) async throws {
        if let error { throw error }
        calls.append(AccountCredentialSwitch(provider: provider, fromAccountID: from, toAccountID: to))
    }
}

private final class CoordinatorFailoverNotifier: AccountFailoverNotifying {
    private(set) var events: [AccountFailoverEvent] = []

    func notify(_ event: AccountFailoverEvent) async {
        events.append(event)
    }
}
