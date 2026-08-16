import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Shared `--provider` / `--account` selection for `meterbar usage` and
/// `serve /usage`. Account matching is exact-token (id or name), never a
/// substring, so "Work" cannot silently select "Workplace".
final class UsageCLISelectionTests: XCTestCase {
    private let claudePersonalID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11))
    private let claudeWorkID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12))
    private let claudeStagingID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x13))
    private let codexDefaultID = CodexAccount.defaultID
    private let codexWorkID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x22))
    private let grokTeamID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x33))

    private lazy var metrics: [ServiceType: UsageMetrics] = [
        .claudeCode: MetricsFixtures.claudeCode(sessionUsedPercent: 10),
        .codexCli: MetricsFixtures.codexCli(sessionUsedPercent: 20),
        .cursor: MetricsFixtures.cursor(),
        .openRouter: openRouterMetrics,
        .grok: MetricsFixtures.grok(),
    ]

    private lazy var accounts: [AccountUsageSnapshot] = [
        snapshot(id: claudeWorkID, name: "Work", metrics: MetricsFixtures.claudeCode(sessionUsedPercent: 80)),
        snapshot(id: claudeStagingID, name: "Staging", metrics: MetricsFixtures.claudeCode(sessionUsedPercent: 15)),
        snapshot(id: claudePersonalID, name: "Personal", metrics: MetricsFixtures.claudeCode(sessionUsedPercent: 40)),
        snapshot(id: codexWorkID, name: "Work", metrics: MetricsFixtures.codexCli(sessionUsedPercent: 70)),
        snapshot(id: codexDefaultID, name: CodexAccount.defaultName, metrics: MetricsFixtures.codexCli()),
        snapshot(id: grokTeamID, name: "Team", metrics: MetricsFixtures.grok(weeklyUsedPercent: 90)),
    ]

    private var openRouterMetrics: UsageMetrics {
        UsageMetrics(
            service: .openRouter,
            weeklyLimit: UsageLimit(used: 8, total: 20, resetTime: MetricsFixtures.referenceDate),
            lastUpdated: MetricsFixtures.referenceDate
        )
    }

    // MARK: Listing

    func testThreeProfileClaudeCodexGrokFixturesListIndependently() {
        let selection = resolve()

        XCTAssertEqual(
            selection.accounts.map { "\($0.metrics.service.cliIdentifier):\($0.name)" },
            [
                "claude:Personal",
                "claude:Staging",
                "claude:Work",
                "codex:Default CLI Profile",
                "codex:Work",
                "grok:Team",
            ]
        )
        XCTAssertEqual(Set(selection.metrics.keys), Set(ServiceType.allCases))
    }

    func testCursorAndOpenRouterStayProviderOnlyWithNoFakeAccounts() {
        let selection = resolve()

        XCTAssertFalse(selection.accounts.contains { $0.metrics.service == .cursor })
        XCTAssertFalse(selection.accounts.contains { $0.metrics.service == .openRouter })
        XCTAssertNotNil(selection.metrics[.cursor])
        XCTAssertNotNil(selection.metrics[.openRouter])
    }

    func testLegacyProviderOnlyCacheKeepsAccountsEmpty() {
        let selection = UsageCLISelection.resolve(metrics: metrics, accounts: [])

        XCTAssertTrue(selection.accounts.isEmpty)
        XCTAssertEqual(Set(selection.metrics.keys), Set(ServiceType.allCases))
    }

    func testMissingAccountCacheAndEmptyFiltersAreDeterministic() {
        let noAccounts = UsageCLISelection.resolve(metrics: metrics, accounts: [], provider: nil, account: nil)
        let blankFilters = UsageCLISelection.resolve(
            metrics: metrics,
            accounts: accounts,
            provider: "   ",
            account: "  "
        )

        XCTAssertTrue(noAccounts.accounts.isEmpty)
        XCTAssertEqual(blankFilters.accounts.map(\.id), resolve().accounts.map(\.id))
    }

    // MARK: Selection

    func testAccountIdSelectsExactlyOneProfile() {
        let selection = resolve(account: claudeWorkID.uuidString)

        XCTAssertEqual(selection.accounts.map(\.id), [claudeWorkID])
        XCTAssertEqual(selection.accounts.first?.name, "Work")
        XCTAssertEqual(selection.accounts.first?.metrics.service, .claudeCode)
    }

    func testAccountIdMatchIsCaseInsensitive() {
        let selection = resolve(account: claudeWorkID.uuidString.uppercased())

        XCTAssertEqual(selection.accounts.map(\.id), [claudeWorkID])
    }

    func testExactAccountNameSelectsEveryDuplicateAcrossProviders() {
        let selection = resolve(account: "Work")

        XCTAssertEqual(selection.accounts.map(\.id), [claudeWorkID, codexWorkID])
        XCTAssertEqual(selection.accounts.map(\.metrics.service), [.claudeCode, .codexCli])
    }

    func testAccountNameMatchIsExactAndCaseInsensitiveNotSubstring() {
        XCTAssertEqual(resolve(account: "work").accounts.map(\.id), [claudeWorkID, codexWorkID])
        XCTAssertEqual(resolve(account: " Work ").accounts.map(\.id), [claudeWorkID, codexWorkID])
        XCTAssertTrue(resolve(account: "Workplace").accounts.isEmpty)
        XCTAssertTrue(resolve(account: "Pers").accounts.isEmpty)
    }

    func testProviderAndAccountFiltersIntersect() {
        let selection = resolve(provider: "claude", account: "Work")

        XCTAssertEqual(selection.accounts.map(\.id), [claudeWorkID])
        XCTAssertEqual(Set(selection.metrics.keys), [.claudeCode])
    }

    func testProviderFilterAloneKeepsEveryAccountForThatProvider() {
        let selection = resolve(provider: "codex")

        XCTAssertEqual(selection.accounts.map(\.name), [CodexAccount.defaultName, "Work"])
        XCTAssertEqual(Set(selection.metrics.keys), [.codexCli])
    }

    func testUnknownAccountIsDeterministicallyEmpty() {
        let selection = resolve(account: "not-a-real-account")

        XCTAssertTrue(selection.accounts.isEmpty)
        XCTAssertEqual(selection.emptyReportMessage, UsageCLISelection.noMatchingAccountsMessage)
        XCTAssertEqual(Set(selection.metrics.keys), Set(ServiceType.allCases))
    }

    func testUnknownProviderStillWinsOverAnAccountFilter() {
        let selection = resolve(provider: "clod", account: "Work")

        XCTAssertTrue(selection.metrics.isEmpty)
        XCTAssertTrue(selection.accounts.isEmpty)
        XCTAssertEqual(selection.emptyReportMessage, CLIProviderFilter.noMatchesMessage)
    }

    func testDisabledOrDeletedProfilesAreOnlyWhatTheCacheStillHolds() {
        let liveOnly = [
            snapshot(id: claudePersonalID, name: "Personal", metrics: MetricsFixtures.claudeCode()),
        ]

        let selection = UsageCLISelection.resolve(metrics: metrics, accounts: liveOnly)

        XCTAssertEqual(selection.accounts.map(\.name), ["Personal"])
        XCTAssertFalse(selection.accounts.contains { $0.name == "Work" })
    }

    func testAccountsAreSortedByProviderThenNameThenId() {
        let sameNameA = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x41))
        let sameNameB = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40))
        let shuffled = [
            snapshot(id: sameNameA, name: "Twin", metrics: MetricsFixtures.claudeCode()),
            snapshot(id: grokTeamID, name: "Team", metrics: MetricsFixtures.grok()),
            snapshot(id: sameNameB, name: "Twin", metrics: MetricsFixtures.claudeCode()),
        ]

        let selection = UsageCLISelection.resolve(metrics: metrics, accounts: shuffled)

        XCTAssertEqual(selection.accounts.map(\.id), [sameNameB, sameNameA, grokTeamID])
    }

    private func resolve(provider: String? = nil, account: String? = nil) -> UsageCLISelection {
        UsageCLISelection.resolve(
            metrics: metrics,
            accounts: accounts,
            provider: provider,
            account: account
        )
    }

    private func snapshot(id: UUID, name: String, metrics: UsageMetrics) -> AccountUsageSnapshot {
        AccountUsageSnapshot(id: id, name: name, metrics: metrics)
    }
}
