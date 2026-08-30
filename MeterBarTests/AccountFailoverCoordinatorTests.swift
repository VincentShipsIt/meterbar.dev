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
        let switcher = CoordinatorCredentialSwitcher(liveAccountID: preferred.id)
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
            codexMetrics: [:],
            evidence: evidence(claude: [preferred.id, fallback.id])
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
        let switcher = CoordinatorCredentialSwitcher(liveAccountID: fallback.id)
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
            codexMetrics: [preferred.id: metrics(.codexCli, used: 0), fallback.id: metrics(.codexCli, used: 40)],
            evidence: evidence(codex: [preferred.id, fallback.id])
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
        let switcher = CoordinatorCredentialSwitcher(error: TestError.failed, liveAccountID: ordered[0].id)
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
            codexMetrics: [ordered[0].id: metrics(.codexCli, used: 100), ordered[1].id: metrics(.codexCli, used: 1)],
            evidence: evidence(codex: Set(ordered.map(\.id)))
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
            codexMetrics: [ordered[0].id: metrics(.codexCli, used: 100), ordered[1].id: metrics(.codexCli, used: 1)],
            evidence: evidence(codex: Set(ordered.map(\.id)))
        )

        XCTAssertFalse(settings.isEnabled(for: .codexCli))
        XCTAssertTrue(switcher.calls.isEmpty)
        XCTAssertTrue(notifier.events.isEmpty)
    }

    func testCachedFailedPrimaryRefreshCannotTriggerSwitch() async {
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/tmp/codex-fallback")
        let ordered = accounts.enabledAccounts
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        settings.setEnabled(true, for: .codexCli)
        let switcher = CoordinatorCredentialSwitcher(liveAccountID: ordered[0].id)
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
            codexMetrics: [ordered[0].id: metrics(.codexCli, used: 100), ordered[1].id: metrics(.codexCli, used: 1)],
            evidence: evidence(codex: [ordered[1].id])
        )

        XCTAssertTrue(switcher.calls.isEmpty)
        XCTAssertTrue(notifier.events.isEmpty)
    }

    func testDeniedNotificationAuthorizationPreventsCredentialMutation() async {
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/tmp/codex-fallback")
        let ordered = accounts.enabledAccounts
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        settings.setEnabled(true, for: .codexCli)
        let switcher = CoordinatorCredentialSwitcher(liveAccountID: ordered[0].id)
        let notifier = CoordinatorFailoverNotifier()
        notifier.isPrepared = false
        let coordinator = AccountFailoverCoordinator(
            settings: settings,
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            credentialSwitcher: switcher,
            notifier: notifier
        )

        await coordinator.evaluate(
            claudeMetrics: [:],
            codexMetrics: [ordered[0].id: metrics(.codexCli, used: 100), ordered[1].id: metrics(.codexCli, used: 1)],
            evidence: evidence(codex: Set(ordered.map(\.id)))
        )

        XCTAssertTrue(switcher.calls.isEmpty)
        XCTAssertTrue(notifier.events.isEmpty)
    }

    func testTransientNotificationFailureLeavesCommittedEventForRetry() async {
        let pendingEvent = AccountFailoverEvent(
            id: UUID(),
            provider: .codexCli,
            fromAccountID: UUID(),
            fromAccountName: "Primary",
            toAccountID: UUID(),
            toAccountName: "Fallback",
            reason: .activeAccountDepleted,
            timestamp: Date()
        )
        let switcher = CoordinatorCredentialSwitcher(
            liveAccountID: pendingEvent.toAccountID,
            pendingEvent: pendingEvent
        )
        let notifier = CoordinatorFailoverNotifier()
        notifier.deliverySucceeds = false
        let coordinator = AccountFailoverCoordinator(
            settings: AccountFailoverSettingsStore(userDefaults: defaults),
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            credentialSwitcher: switcher,
            notifier: notifier
        )

        await coordinator.evaluate(claudeMetrics: [:], codexMetrics: [:])

        XCTAssertEqual(notifier.events, [pendingEvent])
        XCTAssertTrue(switcher.completedEventIDs.isEmpty)

        notifier.deliverySucceeds = true
        await coordinator.evaluate(claudeMetrics: [:], codexMetrics: [:])

        XCTAssertEqual(notifier.events, [pendingEvent, pendingEvent])
        XCTAssertEqual(switcher.completedEventIDs, [pendingEvent.id])
    }

    func testCrashAfterNotificationBeforeAcknowledgementRetriesStableEvent() async {
        let pendingEvent = AccountFailoverEvent(
            id: UUID(),
            provider: .codexCli,
            fromAccountID: UUID(),
            fromAccountName: "Primary",
            toAccountID: UUID(),
            toAccountName: "Fallback",
            reason: .activeAccountDepleted,
            timestamp: Date()
        )
        let switcher = CoordinatorCredentialSwitcher(
            liveAccountID: pendingEvent.toAccountID,
            pendingEvent: pendingEvent,
            completionFailuresRemaining: 1
        )
        let notifier = CoordinatorFailoverNotifier()
        let coordinator = AccountFailoverCoordinator(
            settings: AccountFailoverSettingsStore(userDefaults: defaults),
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            credentialSwitcher: switcher,
            notifier: notifier
        )

        await coordinator.evaluate(claudeMetrics: [:], codexMetrics: [:])
        await coordinator.evaluate(claudeMetrics: [:], codexMetrics: [:])

        XCTAssertEqual(notifier.events, [pendingEvent, pendingEvent])
        XCTAssertEqual(Set(notifier.events.map(\.id)), [pendingEvent.id])
        XCTAssertEqual(switcher.completedEventIDs, [pendingEvent.id, pendingEvent.id])
    }

    func testConcurrentEvaluationsSerializeAcrossSuspendingCredentialSwitch() async {
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/tmp/codex-fallback")
        let ordered = accounts.enabledAccounts
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        settings.setEnabled(true, for: .codexCli)
        let switcher = SuspendingCredentialSwitcher(liveAccountID: ordered[0].id)
        let coordinator = AccountFailoverCoordinator(
            settings: settings,
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            credentialSwitcher: switcher,
            notifier: CoordinatorFailoverNotifier()
        )
        let metricsByAccount = [
            ordered[0].id: metrics(.codexCli, used: 100),
            ordered[1].id: metrics(.codexCli, used: 1),
        ]
        let refreshEvidence = evidence(codex: Set(ordered.map(\.id)))

        let first = Task {
            await coordinator.evaluate(
                claudeMetrics: [:],
                codexMetrics: metricsByAccount,
                evidence: refreshEvidence
            )
        }
        await switcher.waitUntilSwitchStarts()
        let second = Task {
            await coordinator.evaluate(
                claudeMetrics: [:],
                codexMetrics: metricsByAccount,
                evidence: refreshEvidence
            )
        }
        await Task.yield()

        XCTAssertEqual(switcher.switchCount, 1)
        switcher.resumeSwitch()
        await first.value
        await second.value
        XCTAssertEqual(switcher.switchCount, 1)
    }

    @MainActor
    func testLiveNotifierUsesSharedPermissionAwareNotificationBoundary() async {
        let poster = RecordingUserNotificationPoster()
        let notifier = LiveAccountFailoverNotifier(notificationPoster: poster)
        let timestamp = Date(timeIntervalSince1970: 123)

        let posted = await notifier.notify(AccountFailoverEvent(
            provider: .codexCli,
            fromAccountID: UUID(),
            fromAccountName: "Primary",
            toAccountID: UUID(),
            toAccountName: "Fallback",
            reason: .activeAccountDepleted,
            timestamp: timestamp
        ))

        XCTAssertTrue(posted)
        XCTAssertEqual(poster.posts.count, 1)
        XCTAssertEqual(poster.posts.first?.title, "Codex account switched")
        XCTAssertEqual(poster.posts.first?.body, "Primary → Fallback")
    }

    @MainActor
    func testLiveNotifierUsesSameStableIdentifierWhenDeliveryIsRetried() async {
        let poster = RecordingUserNotificationPoster()
        let notifier = LiveAccountFailoverNotifier(notificationPoster: poster)
        let event = AccountFailoverEvent(
            id: UUID(),
            provider: .claudeCode,
            fromAccountID: UUID(),
            fromAccountName: "Primary",
            toAccountID: UUID(),
            toAccountName: "Fallback",
            reason: .activeAccountDepleted,
            timestamp: Date()
        )

        _ = await notifier.notify(event)
        _ = await notifier.notify(event)

        XCTAssertEqual(poster.posts.count, 2)
        XCTAssertEqual(Set(poster.posts.map(\.identifier)), ["account-failover-\(event.id.uuidString.lowercased())"])
    }

    private func metrics(_ service: ServiceType, used: Double) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: UsageLimit(used: used, total: 100, resetTime: nil)
        )
    }

    private func evidence(
        claude: Set<UUID> = [],
        codex: Set<UUID> = []
    ) -> AccountFailoverRefreshEvidence {
        AccountFailoverRefreshEvidence(
            claudeSuccessfulAccountIDs: claude,
            codexSuccessfulAccountIDs: codex
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
    func ensureAuthorization() async -> Bool { true }

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
    private var currentLiveAccountID: UUID?
    private var pendingEvent: AccountFailoverEvent?
    private var completionFailuresRemaining: Int
    private(set) var completedEventIDs: [UUID] = []

    init(
        error: Error? = nil,
        eligibility: AccountCredentialSwitchEligibility = .eligible,
        liveAccountID: UUID? = nil,
        pendingEvent: AccountFailoverEvent? = nil,
        completionFailuresRemaining: Int = 0
    ) {
        self.error = error
        switchEligibility = eligibility
        currentLiveAccountID = liveAccountID
        self.pendingEvent = pendingEvent
        self.completionFailuresRemaining = completionFailuresRemaining
    }

    func eligibility(for _: AccountFailoverProvider) -> AccountCredentialSwitchEligibility {
        switchEligibility
    }

    func liveAccountID(for _: AccountFailoverProvider) throws -> UUID {
        guard let currentLiveAccountID else { throw CredentialExchangeError.liveAccountUnavailable }
        return currentLiveAccountID
    }

    func recoverPendingTransactions() async throws -> AccountFailoverEvent? { pendingEvent }

    func switchCredentials(for event: AccountFailoverEvent) async throws {
        if let error { throw error }
        calls.append(AccountCredentialSwitch(
            provider: event.provider,
            fromAccountID: event.fromAccountID,
            toAccountID: event.toAccountID
        ))
        currentLiveAccountID = event.toAccountID
    }

    func completeNotification(eventID: UUID) throws {
        completedEventIDs.append(eventID)
        if completionFailuresRemaining > 0 {
            completionFailuresRemaining -= 1
            throw TestError.failed
        }
        pendingEvent = nil
    }
}

@MainActor
private final class SuspendingCredentialSwitcher: AccountCredentialSwitching {
    private var currentLiveAccountID: UUID
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private(set) var switchCount = 0

    init(liveAccountID: UUID) {
        currentLiveAccountID = liveAccountID
    }

    func eligibility(for _: AccountFailoverProvider) -> AccountCredentialSwitchEligibility { .eligible }
    func liveAccountID(for _: AccountFailoverProvider) throws -> UUID { currentLiveAccountID }

    func switchCredentials(for event: AccountFailoverEvent) async throws {
        switchCount += 1
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        currentLiveAccountID = event.toAccountID
    }

    func waitUntilSwitchStarts() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func resumeSwitch() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class CoordinatorFailoverNotifier: AccountFailoverNotifying {
    private(set) var events: [AccountFailoverEvent] = []
    var isPrepared = true
    var deliverySucceeds = true

    func prepareForAutomaticSwitch() async -> Bool { isPrepared }

    func notify(_ event: AccountFailoverEvent) async -> Bool {
        events.append(event)
        return deliverySucceeds
    }
}
