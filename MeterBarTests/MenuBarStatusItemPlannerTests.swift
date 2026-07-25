import MeterBarShared
import XCTest

@testable import MeterBar

/// Covers the pure layout decision behind the menu bar: how many status items
/// exist, what each one shows, and how they are identified across refreshes.
final class MenuBarStatusItemPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func candidate(
        key: String,
        service: ServiceType = .claudeCode,
        accountKey: String? = nil,
        percentUsed: Double,
        displayName: String? = nil,
        windowName: String = "Session",
        pinKey: String? = nil,
        activeMinutesAgo: Double? = nil,
        isAutoSelectable: Bool = true
    ) -> StatusLimitCandidate {
        StatusLimitCandidate(
            key: key,
            pinKey: pinKey ?? key,
            service: service,
            accountKey: accountKey,
            displayName: displayName ?? key,
            windowName: windowName,
            limit: UsageLimit(used: percentUsed, total: 100, resetTime: nil),
            lastActivity: activeMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            isAutoSelectable: isAutoSelectable
        )
    }

    private func plan(
        _ candidates: [StatusLimitCandidate],
        mode: MenuBarPresentationMode = .merged,
        previousKey: String? = nil,
        pinnedKey: String? = nil,
        metric: StatusItemLabelMetric = .percentLeft,
        size: StatusItemLabelSize = .compact
    ) -> [MenuBarStatusItemDescriptor] {
        MenuBarStatusItemPlanner.plan(
            mode: mode,
            candidates: candidates,
            previousKey: previousKey,
            pinnedKey: pinnedKey,
            metric: metric,
            size: size,
            now: now
        )
    }

    // MARK: - Merged mode

    func testMergedModeProducesExactlyOneItemForTheSelectedQuota() {
        let codex = candidate(key: "codex", service: .codexCli, percentUsed: 100, activeMinutesAgo: 1)
        let claude = candidate(key: "claude:gen", percentUsed: 48, displayName: "genfeedai (Claude Code)")

        let descriptors = plan([codex, claude])

        XCTAssertEqual(descriptors.count, 1)
        let item = descriptors.first
        XCTAssertEqual(item?.id, MenuBarStatusItemPlanner.mergedItemID)
        XCTAssertEqual(item?.service, .claudeCode)
        XCTAssertEqual(item?.selectionKey, "claude:gen")
        XCTAssertEqual(item?.title, " 52%")
        XCTAssertEqual(item?.tooltip, "MeterBar: 52% left on genfeedai (Claude Code)")
        XCTAssertEqual(item?.accessibilityLabel, "MeterBar 52% left on genfeedai (Claude Code)")
    }

    func testMergedModeQualifiesTheWindowOnlyWhenPinned() {
        let claude = candidate(
            key: "claude:gen",
            percentUsed: 48,
            displayName: "genfeedai (Claude Code)",
            windowName: "Weekly",
            pinKey: "Claude Code:gen:weekly",
            isAutoSelectable: false
        )

        let descriptors = plan([claude], pinnedKey: "Claude Code:gen:weekly")

        XCTAssertEqual(descriptors.first?.tooltip, "MeterBar: 52% left on genfeedai (Claude Code) · Weekly")
    }

    func testMergedModeWithoutASelectionKeepsOneIconOnlyItem() {
        // Losing the item entirely would leave the app with no way to open the
        // popover or quit, so an empty plan still owns one slot.
        let descriptors = plan([])

        XCTAssertEqual(descriptors.map(\.id), [MenuBarStatusItemPlanner.mergedItemID])
        XCTAssertEqual(descriptors.first?.title, "")
        XCTAssertNil(descriptors.first?.selectionKey)
        XCTAssertNil(descriptors.first?.service)
        XCTAssertEqual(descriptors.first?.tooltip, "MeterBar")
        XCTAssertEqual(descriptors.first?.accessibilityLabel, "MeterBar")
    }

    func testMergedModeIconOnlyMetricDropsTheLabelButKeepsTheAccount() {
        let claude = candidate(key: "claude:gen", percentUsed: 48, displayName: "genfeedai (Claude Code)")

        let descriptors = plan([claude], metric: .iconOnly)

        XCTAssertEqual(descriptors.first?.title, "")
        XCTAssertEqual(descriptors.first?.tooltip, "MeterBar: genfeedai (Claude Code)")
        XCTAssertEqual(descriptors.first?.accessibilityLabel, "MeterBar genfeedai (Claude Code)")
    }

    func testMergedModeHonorsTheRegularLabelSize() {
        let claude = candidate(key: "claude:gen", percentUsed: 48)

        XCTAssertEqual(plan([claude], size: .regular).first?.title, " 52% left")
    }

    func testMergedModeStaysStickyOnThePreviouslyShownAccount() {
        let claude = candidate(key: "claude:gen", percentUsed: 48, activeMinutesAgo: 1)
        let codex = candidate(key: "codex", service: .codexCli, percentUsed: 50, activeMinutesAgo: 1)

        XCTAssertEqual(plan([claude, codex], previousKey: "codex").first?.selectionKey, "codex")
    }

    // MARK: - Per-provider mode

    func testPerProviderModeCreatesOneItemPerAutoSelectableCandidate() {
        let codex = candidate(key: "codex", service: .codexCli, percentUsed: 100, displayName: "Personal (Codex)")
        let claude = candidate(key: "claude:gen", percentUsed: 48, displayName: "genfeedai (Claude Code)")

        let descriptors = plan([codex, claude], mode: .perProvider)

        // Sorted by provider so the items don't reshuffle between refreshes.
        XCTAssertEqual(descriptors.map(\.id), ["claude:gen", "codex"])
        XCTAssertEqual(descriptors.map(\.service), [.claudeCode, .codexCli])
        XCTAssertEqual(descriptors.map(\.title), [" 52%", " 0%"])
    }

    func testPerProviderModeAlwaysNamesTheQuotaWindow() {
        let claude = candidate(key: "claude:gen", percentUsed: 48, displayName: "genfeedai (Claude Code)")

        let descriptors = plan([claude], mode: .perProvider)

        XCTAssertEqual(descriptors.first?.tooltip, "MeterBar: 52% left on genfeedai (Claude Code) · Session")
        XCTAssertEqual(
            descriptors.first?.accessibilityLabel,
            "MeterBar 52% left on genfeedai (Claude Code) · Session"
        )
    }

    func testPerProviderModeIgnoresPinOnlyWindows() {
        let session = candidate(key: "claude:gen", percentUsed: 48)
        let weekly = candidate(
            key: "Claude Code:gen:weekly",
            percentUsed: 10,
            windowName: "Weekly",
            isAutoSelectable: false
        )

        XCTAssertEqual(plan([session, weekly], mode: .perProvider).map(\.id), ["claude:gen"])
    }

    func testPerProviderModeNeverReportsASelectionKey() {
        // Per-provider items each own a fixed account, so feeding their keys
        // back into the sticky selector would be meaningless.
        let claude = candidate(key: "claude:gen", percentUsed: 48)

        XCTAssertNil(plan([claude], mode: .perProvider).first?.selectionKey)
    }

    func testPerProviderModeFallsBackToASingleItemWhenNothingIsTracked() {
        let descriptors = plan([], mode: .perProvider)

        XCTAssertEqual(descriptors.map(\.id), [MenuBarStatusItemPlanner.mergedItemID])
        XCTAssertEqual(descriptors.first?.tooltip, "MeterBar")
    }

    func testPerProviderModeShowsExhaustedAccountsInsteadOfHidingThem() {
        // The Auto heuristic skips spent quotas; an explicit per-provider row
        // is the user asking to see that account regardless.
        let codex = candidate(key: "codex", service: .codexCli, percentUsed: 100)

        XCTAssertEqual(plan([codex], mode: .perProvider).map(\.title), [" 0%"])
    }

    func testPerProviderModeOrdersEqualProvidersByKey() {
        let second = candidate(key: "claude:zzz", percentUsed: 10)
        let first = candidate(key: "claude:aaa", percentUsed: 90)

        XCTAssertEqual(plan([second, first], mode: .perProvider).map(\.id), ["claude:aaa", "claude:zzz"])
    }

    // MARK: - Switcher options

    func testSwitcherOffersEveryWindowIncludingPinOnlyOnes() {
        let session = candidate(
            key: "claude:gen",
            percentUsed: 48,
            displayName: "genfeedai (Claude Code)",
            pinKey: "Claude Code:gen:session"
        )
        let weekly = candidate(
            key: "Claude Code:gen:weekly",
            percentUsed: 10,
            displayName: "genfeedai (Claude Code)",
            windowName: "Weekly",
            pinKey: "Claude Code:gen:weekly",
            isAutoSelectable: false
        )
        let codex = candidate(
            key: "codex",
            service: .codexCli,
            percentUsed: 100,
            displayName: "Personal (OpenAI Codex)",
            pinKey: "Codex CLI:personal:session"
        )

        let options = MenuBarStatusItemPlanner.switcherOptions(for: [weekly, codex, session])

        XCTAssertEqual(
            options,
            [
                StatusItemPinOption(id: "Claude Code:gen:session", title: "genfeedai (Claude Code) · Session"),
                StatusItemPinOption(id: "Claude Code:gen:weekly", title: "genfeedai (Claude Code) · Weekly"),
                StatusItemPinOption(id: "Codex CLI:personal:session", title: "Personal (OpenAI Codex) · Session")
            ]
        )
    }

    func testSwitcherDropsDuplicatePinKeys() {
        // The same account can surface twice across a refresh boundary; a menu
        // with two identical radio items would be unusable.
        let first = candidate(key: "claude:gen", percentUsed: 48, pinKey: "Claude Code:gen:session")
        let duplicate = candidate(key: "claude:gen", percentUsed: 47, pinKey: "Claude Code:gen:session")

        XCTAssertEqual(MenuBarStatusItemPlanner.switcherOptions(for: [first, duplicate]).count, 1)
    }

    // MARK: - Per-account mode

    /// Two accounts, each holding a tight window and a slightly looser one that
    /// sits inside the 5-point hysteresis band, so the previously shown window
    /// wins only when this item's own history says it should.
    private var twoAccountCandidates: [StatusLimitCandidate] {
        [
            candidate(key: "a-session", accountKey: "claudeCode:a", percentUsed: 78, windowName: "Session"),
            candidate(key: "a-weekly", accountKey: "claudeCode:a", percentUsed: 80, windowName: "Weekly"),
            candidate(
                key: "b-session",
                service: .codexCli,
                accountKey: "codexCli:b",
                percentUsed: 70,
                windowName: "Session"
            ),
            candidate(
                key: "b-weekly",
                service: .codexCli,
                accountKey: "codexCli:b",
                percentUsed: 72,
                windowName: "Weekly"
            )
        ]
    }

    private var twoAccountEntries: [MenuBarAccountItemEntry] {
        [
            MenuBarAccountItemEntry(
                id: "claudeCode:a",
                accountKey: "claudeCode:a",
                displayName: "Work",
                badge: "W",
                showsAccountSwitcher: false
            ),
            MenuBarAccountItemEntry(
                id: "codexCli:b",
                accountKey: "codexCli:b",
                displayName: "Personal",
                badge: "P",
                showsAccountSwitcher: false
            )
        ]
    }

    private func planAccounts(
        _ candidates: [StatusLimitCandidate],
        entries: [MenuBarAccountItemEntry],
        previousKey: String? = nil,
        previousKeys: [String: String] = [:],
        pinnedKey: String? = nil
    ) -> [MenuBarStatusItemDescriptor] {
        MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            accountPlan: MenuBarAccountItemPlan(mode: .perAccount, entries: entries),
            candidates: candidates,
            previousKey: previousKey,
            previousKeys: previousKeys,
            pinnedKey: pinnedKey,
            metric: .percentLeft,
            size: .compact,
            now: now
        )
    }

    /// Baseline: with no history at all every item lands on its own tightest
    /// window, which is what the sticky assertions below have to move away from.
    func testPerAccountItemsWithoutHistoryShowTheirOwnTightestWindow() {
        let descriptors = planAccounts(twoAccountCandidates, entries: twoAccountEntries)

        XCTAssertEqual(descriptors.map(\.selectionKey), ["a-weekly", "b-weekly"])
    }

    /// The core of the per-item history: each slot is anchored by what *it*
    /// showed last refresh, so two accounts can hold two different windows.
    func testPerAccountItemsEachKeepTheirOwnStickySelection() {
        let descriptors = planAccounts(
            twoAccountCandidates,
            entries: twoAccountEntries,
            previousKeys: ["claudeCode:a": "a-session", "codexCli:b": "b-session"]
        )

        XCTAssertEqual(descriptors.map(\.selectionKey), ["a-session", "b-session"])
    }

    /// One item's history must not anchor another's. Before the per-item map,
    /// every account item was handed the merged item's key, so at most one of
    /// them could ever match and the rest lost their hysteresis entirely.
    func testOneAccountsHistoryDoesNotAnchorAnother() {
        let descriptors = planAccounts(
            twoAccountCandidates,
            entries: twoAccountEntries,
            previousKeys: ["claudeCode:a": "a-session"]
        )

        XCTAssertEqual(descriptors.map(\.selectionKey), ["a-session", "b-weekly"])
    }

    /// The merged item's key belongs to the merged slot. Feeding it to account
    /// items would apply one account's history to windows it does not own.
    func testTheMergedKeyNeverAnchorsAnAccountItem() {
        let descriptors = planAccounts(
            twoAccountCandidates,
            entries: twoAccountEntries,
            previousKey: "a-session"
        )

        XCTAssertEqual(descriptors.map(\.selectionKey), ["a-weekly", "b-weekly"])
    }

    /// Reporting a key is what closes the loop: the presenter stores it per item
    /// id and hands it straight back on the next refresh.
    func testPerAccountItemsReportTheItemIDTheyBelongTo() {
        let descriptors = planAccounts(twoAccountCandidates, entries: twoAccountEntries)

        XCTAssertEqual(descriptors.map(\.id), ["claudeCode:a", "codexCli:b"])
        XCTAssertFalse(descriptors.contains { $0.selectionKey == nil })
    }

    /// Same rule the merged item follows: Auto means "whichever window matters",
    /// so naming it is noise — but a pin is a deliberate choice of one window.
    func testPerAccountItemNamesTheWindowOnlyWhenPinned() {
        let auto = planAccounts(twoAccountCandidates, entries: twoAccountEntries)
        let pinned = planAccounts(twoAccountCandidates, entries: twoAccountEntries, pinnedKey: "a-session")

        XCTAssertEqual(auto.first?.tooltip, "MeterBar: Work · a-weekly")
        XCTAssertEqual(pinned.first?.tooltip, "MeterBar: Work · a-session · Session")
    }

    /// A pin naming a window in another account must not drag this item onto it,
    /// and must not qualify this item's own auto choice either.
    func testAPinOutsideTheAccountLeavesTheItemOnAuto() {
        let descriptors = planAccounts(twoAccountCandidates, entries: twoAccountEntries, pinnedKey: "b-session")

        XCTAssertEqual(descriptors.first?.selectionKey, "a-weekly")
        XCTAssertEqual(descriptors.first?.tooltip, "MeterBar: Work · a-weekly")
    }
}
