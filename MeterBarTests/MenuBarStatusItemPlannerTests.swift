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
}
