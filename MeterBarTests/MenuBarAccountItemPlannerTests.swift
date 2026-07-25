import MeterBarShared
import XCTest

@testable import MeterBar

/// Covers the *account* half of the menu bar plan: which accounts get a status
/// item at all. What each item then says is `MenuBarStatusItemPlannerTests`.
final class MenuBarAccountItemPlannerTests: XCTestCase {
    private func identity(
        _ key: String,
        service: ServiceType = .claudeCode,
        name: String = "Work",
        isEnabled: Bool = true
    ) -> MenuBarAccountIdentity {
        MenuBarAccountIdentity(
            key: key,
            service: service,
            accountID: UUID(),
            displayName: MenuBarAccountLabel.displayName(for: name),
            badge: MenuBarAccountLabel.badge(for: name),
            isEnabled: isEnabled
        )
    }

    private func candidate(
        key: String,
        accountKey: String?,
        service: ServiceType = .claudeCode,
        percentUsed: Double = 40
    ) -> StatusLimitCandidate {
        StatusLimitCandidate(
            key: key,
            pinKey: key,
            service: service,
            accountKey: accountKey,
            displayName: key,
            windowName: "Session",
            limit: UsageLimit(used: percentUsed, total: 100, resetTime: nil),
            lastActivity: nil,
            isAutoSelectable: true
        )
    }

    // MARK: - Provider-level modes

    /// Neither provider-level mode is account-scoped, so the planner must hand
    /// back the single unscoped entry that keeps the legacy layout intact.
    func testProviderModesPlanTheUnscopedAggregateItem() {
        for mode in [MenuBarPresentationMode.merged, .perProvider] {
            let plan = MenuBarAccountItemPlanner.plan(
                mode: mode,
                selectedAccountKeys: ["claudeCode:a"],
                mergedAccountKey: "claudeCode:a",
                accounts: [identity("claudeCode:a")]
            )

            XCTAssertEqual(plan, .aggregate(mode: mode))
            XCTAssertEqual(plan.itemIDs, [MenuBarStatusItemPlanner.mergedItemID])
        }
    }

    /// The fallback entry has to land on the merged item's slot, otherwise
    /// dropping back to it respawns the status item and loses its position.
    func testAggregateEntryReusesTheMergedItemIdentity() {
        XCTAssertEqual(MenuBarAccountItemEntry.aggregate.id, MenuBarStatusItemPlanner.mergedItemID)
        XCTAssertNil(MenuBarAccountItemEntry.aggregate.accountKey)
        XCTAssertFalse(MenuBarAccountItemEntry.aggregate.showsAccountSwitcher)
    }

    // MARK: - Per-account mode

    func testPerAccountPlanFollowsTheSelectionOrder() {
        let plan = MenuBarAccountItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: ["codexCli:b", "claudeCode:a"],
            mergedAccountKey: nil,
            accounts: [
                identity("claudeCode:a", name: "Work"),
                identity("codexCli:b", service: .codexCli, name: "Personal")
            ]
        )

        XCTAssertEqual(plan.itemIDs, ["codexCli:b", "claudeCode:a"])
        XCTAssertEqual(plan.entries.map(\.accountKey), ["codexCli:b", "claudeCode:a"])
        XCTAssertEqual(plan.entries.map(\.badge), ["P", "W"])
        XCTAssertFalse(plan.entries.contains { $0.showsAccountSwitcher })
    }

    func testPerAccountPlanSkipsUntrackedAccounts() {
        let plan = MenuBarAccountItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: ["claudeCode:a", "codexCli:b", "claudeCode:gone"],
            mergedAccountKey: nil,
            accounts: [
                identity("claudeCode:a"),
                identity("codexCli:b", service: .codexCli, isEnabled: false)
            ]
        )

        XCTAssertEqual(plan.itemIDs, ["claudeCode:a"])
    }

    /// Menu-bar width is finite, and macOS silently hides items that overflow.
    func testPerAccountPlanStopsAtTheDocumentedCap() {
        let keys = (0 ... MenuBarAccountItemPlanner.maximumConcurrentItems).map { "claudeCode:\($0)" }

        let plan = MenuBarAccountItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: keys,
            mergedAccountKey: nil,
            accounts: keys.map { identity($0) }
        )

        XCTAssertEqual(plan.entries.count, MenuBarAccountItemPlanner.maximumConcurrentItems)
    }

    /// Every selected account disappearing must not leave the user without any
    /// status item — the popover, Settings and Quit all hang off it.
    func testPerAccountPlanFallsBackToTheAggregateItemWhenNothingSurvives() {
        let plan = MenuBarAccountItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: ["claudeCode:gone"],
            mergedAccountKey: nil,
            accounts: [identity("claudeCode:a")]
        )

        XCTAssertEqual(plan, .aggregate(mode: .perAccount))
    }

    // MARK: - Switcher mode

    func testSwitcherPlanScopesTheSingleItemToTheChosenAccount() {
        let plan = MenuBarAccountItemPlanner.plan(
            mode: .accountSwitcher,
            selectedAccountKeys: [],
            mergedAccountKey: "codexCli:b",
            accounts: [
                identity("claudeCode:a", name: "Work"),
                identity("codexCli:b", service: .codexCli, name: "Personal")
            ]
        )

        XCTAssertEqual(plan.itemIDs, [MenuBarStatusItemPlanner.mergedItemID])
        XCTAssertEqual(plan.entries.first?.accountKey, "codexCli:b")
        XCTAssertEqual(plan.entries.first?.showsAccountSwitcher, true)
    }

    func testSwitcherPlanFallsBackToTheFirstEnabledAccount() {
        let plan = MenuBarAccountItemPlanner.plan(
            mode: .accountSwitcher,
            selectedAccountKeys: [],
            mergedAccountKey: "claudeCode:removed",
            accounts: [
                identity("claudeCode:a", isEnabled: false),
                identity("codexCli:b", service: .codexCli)
            ]
        )

        XCTAssertEqual(plan.entries.first?.accountKey, "codexCli:b")
    }

    func testSwitcherPlanFallsBackToTheAggregateItemWithoutAnyEnabledAccount() {
        let plan = MenuBarAccountItemPlanner.plan(
            mode: .accountSwitcher,
            selectedAccountKeys: [],
            mergedAccountKey: nil,
            accounts: [identity("claudeCode:a", isEnabled: false)]
        )

        XCTAssertEqual(plan, .aggregate(mode: .accountSwitcher))
    }

    // MARK: - Switcher menu entries

    /// Disabled accounts stay in the list so the menu can explain why they hold
    /// no status item, rather than silently omitting them.
    func testSwitcherEntriesKeepUntrackedAccountsAndMarkTheActiveOne() {
        let entries = MenuBarAccountSwitcher.entries(
            accounts: [
                identity("claudeCode:a", name: "Work"),
                identity("codexCli:b", service: .codexCli, name: "Personal", isEnabled: false)
            ],
            activeKey: "claudeCode:a"
        )

        XCTAssertEqual(entries.map(\.key), ["claudeCode:a", "codexCli:b"])
        XCTAssertEqual(entries.map(\.isActive), [true, false])
        XCTAssertEqual(entries.map(\.isEnabled), [true, false])
    }

    func testNextKeyCyclesThroughEnabledAccountsAndWrapsAround() {
        let accounts = [
            identity("claudeCode:a"),
            identity("claudeCode:skipped", isEnabled: false),
            identity("codexCli:b", service: .codexCli)
        ]

        XCTAssertEqual(MenuBarAccountSwitcher.nextKey(after: "claudeCode:a", accounts: accounts), "codexCli:b")
        XCTAssertEqual(MenuBarAccountSwitcher.nextKey(after: "codexCli:b", accounts: accounts), "claudeCode:a")
        // An unknown or absent active key starts the cycle over.
        XCTAssertEqual(MenuBarAccountSwitcher.nextKey(after: nil, accounts: accounts), "claudeCode:a")
        XCTAssertEqual(MenuBarAccountSwitcher.nextKey(after: "gone", accounts: accounts), "claudeCode:a")
        XCTAssertNil(MenuBarAccountSwitcher.nextKey(after: nil, accounts: []))
    }

    // MARK: - Candidate scoping

    func testCandidateFilterKeepsOnlyTheEntrysOwnAccount() {
        let candidates = [
            candidate(key: "claude:a", accountKey: "claudeCode:a"),
            candidate(key: "codex:b", accountKey: "codexCli:b", service: .codexCli),
            candidate(key: "cursor", accountKey: nil, service: .cursor)
        ]
        let entry = MenuBarAccountItemEntry(
            id: "claudeCode:a",
            accountKey: "claudeCode:a",
            displayName: "Work",
            badge: "W",
            showsAccountSwitcher: false
        )

        XCTAssertEqual(
            MenuBarAccountCandidateFilter.candidates(for: entry, in: candidates).map(\.key),
            ["claude:a"]
        )
    }

    /// The aggregate entry is the legacy merged item, so it must keep competing
    /// across every provider — including the single-account ones.
    func testCandidateFilterPassesEverythingThroughForTheAggregateEntry() {
        let candidates = [
            candidate(key: "claude:a", accountKey: "claudeCode:a"),
            candidate(key: "cursor", accountKey: nil, service: .cursor)
        ]

        XCTAssertEqual(
            MenuBarAccountCandidateFilter.candidates(for: .aggregate, in: candidates).count,
            candidates.count
        )
    }
}
