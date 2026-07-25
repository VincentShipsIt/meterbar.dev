import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Status-item planning (issue #266): how a display mode plus a persisted
/// account selection turns into the concrete set of `NSStatusItem`s, how that
/// set is reconciled when accounts appear or disappear, and how the merged
/// item's in-menu switcher behaves.
final class MenuBarStatusItemPlannerTests: XCTestCase {
    // MARK: Internal

    // MARK: - Single (legacy) mode

    /// The upgrade path: an installation that never opted in plans exactly one
    /// aggregate item, which competes across every account exactly as before.
    func testSingleModePlansOneAggregateItemRegardlessOfSelection() {
        let plan = MenuBarStatusItemPlanner.plan(
            mode: .single,
            selectedAccountKeys: [work.key, personal.key],
            mergedAccountKey: personal.key,
            accounts: accounts
        )

        XCTAssertEqual(plan.itemIDs, [MenuBarStatusItemPlanEntry.aggregateID])
        XCTAssertNil(plan.entries.first?.accountKey)
        XCTAssertEqual(plan.entries.first?.badge, "")
        XCTAssertEqual(plan.entries.first?.displayName, "")
        XCTAssertEqual(plan.entries.first?.showsAccountSwitcher, false)
    }

    // MARK: - Per-account mode

    func testPerAccountModePlansOneItemPerSelectedAccountInSelectionOrder() {
        let plan = MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: [personal.key, work.key],
            mergedAccountKey: nil,
            accounts: accounts
        )

        XCTAssertEqual(plan.itemIDs, [personal.key, work.key])
        XCTAssertEqual(plan.entries.map(\.accountKey), [personal.key, work.key])
        XCTAssertEqual(plan.entries.map(\.displayName), ["Personal", "Work"])
        XCTAssertFalse(plan.entries.contains { $0.showsAccountSwitcher })
    }

    /// Two accounts on the same provider must not be visually identical.
    func testSameProviderItemsCarryDistinctBadges() {
        let plan = MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: [work.key, personal.key],
            mergedAccountKey: nil,
            accounts: accounts
        )

        let badges = plan.entries.map(\.badge)
        XCTAssertEqual(badges, ["W", "P"])
        XCTAssertEqual(Set(badges).count, badges.count)
    }

    /// A disabled (or removed) account claims no status item, and the accounts
    /// around it keep their identity and order so their slots survive.
    func testDisabledAccountDropsItsItemWithoutDisturbingTheOthers() {
        let selection = [work.key, disabled.key, personal.key]

        let plan = MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: selection,
            mergedAccountKey: nil,
            accounts: accounts
        )

        XCTAssertEqual(plan.itemIDs, [work.key, personal.key])

        let removedAccount = MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: selection,
            mergedAccountKey: nil,
            accounts: accounts.filter { $0.key != personal.key }
        )
        XCTAssertEqual(removedAccount.itemIDs, [work.key])
    }

    func testPerAccountModeFallsBackToTheAggregateItemWhenNothingResolves() {
        let plan = MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: [disabled.key, "claudeCode:gone"],
            mergedAccountKey: nil,
            accounts: accounts
        )

        XCTAssertEqual(plan.itemIDs, [MenuBarStatusItemPlanEntry.aggregateID])
    }

    func testPlannerNeverExceedsTheDocumentedItemCap() {
        let many = (0 ..< 12).map { index in
            MenuBarAccountIdentity(
                key: "claudeCode:\(index)",
                service: .claudeCode,
                accountID: UUID(),
                displayName: "Account \(index)",
                badge: "A",
                isEnabled: true
            )
        }

        let plan = MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: many.map(\.key),
            mergedAccountKey: nil,
            accounts: many
        )

        XCTAssertEqual(plan.entries.count, MenuBarStatusItemPlanner.maximumConcurrentItems)
        XCTAssertLessThanOrEqual(MenuBarStatusItemPlanner.maximumConcurrentItems, 4)
    }

    // MARK: - Merged mode

    func testMergedModePlansOneSwitchableItemBoundToTheChosenAccount() {
        let plan = MenuBarStatusItemPlanner.plan(
            mode: .merged,
            selectedAccountKeys: [],
            mergedAccountKey: personal.key,
            accounts: accounts
        )

        XCTAssertEqual(plan.itemIDs, [MenuBarStatusItemPlanEntry.mergedID])
        XCTAssertEqual(plan.entries.first?.accountKey, personal.key)
        XCTAssertEqual(plan.entries.first?.displayName, "Personal")
        XCTAssertEqual(plan.entries.first?.showsAccountSwitcher, true)
    }

    /// Switching the merged account keeps the same item id, so the live status
    /// item is retitled in place instead of being destroyed and re-created at
    /// the end of the menu bar.
    func testMergedItemKeepsItsSlotWhenTheAccountChanges() {
        let before = MenuBarStatusItemPlanner.plan(
            mode: .merged, selectedAccountKeys: [], mergedAccountKey: work.key, accounts: accounts
        )
        let after = MenuBarStatusItemPlanner.plan(
            mode: .merged, selectedAccountKeys: [], mergedAccountKey: personal.key, accounts: accounts
        )

        XCTAssertEqual(before.itemIDs, after.itemIDs)
        XCTAssertNotEqual(before.entries.first?.accountKey, after.entries.first?.accountKey)
        let diff = MenuBarStatusItemDiff.between(existing: before.itemIDs, desired: after.itemIDs)
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testMergedModeFallsBackToTheFirstEnabledAccountWhenTheChoiceIsUnavailable() {
        let plan = MenuBarStatusItemPlanner.plan(
            mode: .merged, selectedAccountKeys: [], mergedAccountKey: disabled.key, accounts: accounts
        )

        XCTAssertEqual(plan.entries.first?.accountKey, work.key)
    }

    func testMergedModeFallsBackToTheAggregateItemWithNoEnabledAccounts() {
        let plan = MenuBarStatusItemPlanner.plan(
            mode: .merged, selectedAccountKeys: [], mergedAccountKey: nil, accounts: [disabled]
        )

        XCTAssertEqual(plan.itemIDs, [MenuBarStatusItemPlanEntry.aggregateID])
    }

    // MARK: - Switcher

    /// The switcher lists every tracked account — disabled ones included, marked
    /// so the menu can explain why they hold no status item.
    func testSwitcherListsEveryTrackedAccountWithActiveAndEnabledFlags() {
        let entries = MenuBarAccountSwitcher.entries(accounts: accounts, activeKey: personal.key)

        XCTAssertEqual(entries.map(\.key), accounts.map(\.key))
        XCTAssertEqual(entries.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(entries.filter(\.isActive).map(\.key), [personal.key])
        XCTAssertEqual(entries.map(\.title), ["Work", "Personal", "Retired"])
    }

    func testSwitcherCyclesOnlyEnabledAccountsAndWrapsAround() {
        XCTAssertEqual(MenuBarAccountSwitcher.nextKey(after: work.key, accounts: accounts), personal.key)
        XCTAssertEqual(MenuBarAccountSwitcher.nextKey(after: personal.key, accounts: accounts), work.key)
        XCTAssertEqual(MenuBarAccountSwitcher.nextKey(after: nil, accounts: accounts), work.key)
        XCTAssertEqual(MenuBarAccountSwitcher.nextKey(after: disabled.key, accounts: accounts), work.key)
        XCTAssertNil(MenuBarAccountSwitcher.nextKey(after: nil, accounts: [disabled]))
    }

    // MARK: - Reconciliation diff

    func testDiffAddsAndRemovesOnlyTheDifferenceAndPreservesRetainedOrder() {
        let diff = MenuBarStatusItemDiff.between(
            existing: ["a", "b", "c"], desired: ["a", "c", "d"]
        )

        XCTAssertEqual(diff.added, ["d"])
        XCTAssertEqual(diff.removed, ["b"])
        XCTAssertEqual(diff.retained, ["a", "c"])
    }

    func testIdenticalPlansProduceNoChurn() {
        let diff = MenuBarStatusItemDiff.between(existing: ["a", "b"], desired: ["a", "b"])

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.retained, ["a", "b"])
    }

    // MARK: - Candidate scoping

    /// Each per-account item selects only from its own account's limits; the
    /// aggregate item still competes across all of them.
    func testCandidateFilterScopesAnAccountItemToItsOwnLimits() throws {
        let candidates = [
            candidate(key: "claude-work", accountKey: work.key, percentLeft: 40),
            candidate(key: "claude-personal", accountKey: personal.key, percentLeft: 10),
            candidate(key: "cursor", accountKey: nil, percentLeft: 5)
        ]
        let plan = MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            selectedAccountKeys: [work.key],
            mergedAccountKey: nil,
            accounts: accounts
        )
        let entry = try XCTUnwrap(plan.entries.first)

        let scoped = MenuBarStatusItemCandidateFilter.candidates(for: entry, in: candidates)

        XCTAssertEqual(scoped.map(\.key), ["claude-work"])
    }

    func testCandidateFilterLeavesTheAggregateItemUnscoped() {
        let candidates = [
            candidate(key: "claude-work", accountKey: work.key, percentLeft: 40),
            candidate(key: "cursor", accountKey: nil, percentLeft: 5)
        ]

        let scoped = MenuBarStatusItemCandidateFilter.candidates(
            for: .aggregate, in: candidates
        )

        XCTAssertEqual(scoped.count, candidates.count)
    }

    // MARK: Private

    private let work = MenuBarAccountIdentity(
        key: "claudeCode:work",
        service: .claudeCode,
        accountID: UUID(),
        displayName: "Work",
        badge: "W",
        isEnabled: true
    )
    private let personal = MenuBarAccountIdentity(
        key: "codexCli:personal",
        service: .codexCli,
        accountID: UUID(),
        displayName: "Personal",
        badge: "P",
        isEnabled: true
    )
    private let disabled = MenuBarAccountIdentity(
        key: "claudeCode:retired",
        service: .claudeCode,
        accountID: UUID(),
        displayName: "Retired",
        badge: "R",
        isEnabled: false
    )

    private var accounts: [MenuBarAccountIdentity] { [work, personal, disabled] }

    private func candidate(key: String, accountKey: String?, percentLeft: Int) -> StatusLimitCandidate {
        StatusLimitCandidate(
            key: key,
            pinKey: key,
            accountKey: accountKey,
            displayName: key,
            windowName: "Session",
            limit: UsageLimit(used: Double(100 - percentLeft), total: 100, resetTime: nil),
            lastActivity: nil,
            isAutoSelectable: true
        )
    }
}
