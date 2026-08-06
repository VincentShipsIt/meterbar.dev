import MeterBarShared
import XCTest

@testable import MeterBar

/// Covers the pure "follow the focused app" selection input (issue #341): a
/// frontmost bundle identifier plus the user's mapping resolves to one quota,
/// and every case that must hand the decision back to existing Auto selection.
final class MenuBarFocusSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    private let terminalBundleID = "com.apple.Terminal"
    private let unknownBundleID = "com.example.SomethingElse"

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
            lastUpdated: now,
            lastActivity: activeMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            isAutoSelectable: isAutoSelectable
        )
    }

    private func context(
        bundleID: String?,
        mapping: [String: ServiceType]? = nil,
        visibleServices: Set<ServiceType> = Set(ServiceType.allCases)
    ) -> MenuBarFocusContext {
        MenuBarFocusContext(
            bundleID: bundleID,
            mapping: mapping ?? [cursorBundleID: .cursor, terminalBundleID: .claudeCode],
            visibleServices: visibleServices
        )
    }

    private func select(
        _ candidates: [StatusLimitCandidate],
        bundleID: String?,
        mapping: [String: ServiceType]? = nil,
        visibleServices: Set<ServiceType> = Set(ServiceType.allCases)
    ) -> StatusLimitCandidate? {
        MenuBarFocusSelector.select(
            candidates: candidates,
            context: context(bundleID: bundleID, mapping: mapping, visibleServices: visibleServices)
        )
    }

    // MARK: - Mapping

    func testMappedFrontmostAppSelectsThatProvidersQuota() {
        let claude = candidate(key: "claude:gen", percentUsed: 20, activeMinutesAgo: 1)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        let selection = select([claude, cursor], bundleID: cursorBundleID)

        XCTAssertEqual(selection?.key, "cursor")
        XCTAssertEqual(selection?.service, .cursor)
    }

    func testMappedTerminalFollowsTheProviderTheUserChoseForIt() {
        // The mapping is the whole story: MeterBar never inspects which CLI is
        // running inside the terminal.
        let claude = candidate(key: "claude:gen", percentUsed: 20)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        XCTAssertEqual(select([claude, cursor], bundleID: terminalBundleID)?.service, .claudeCode)
    }

    func testMappedProviderWithSeveralWindowsPicksTheTightestAutoWindow() {
        let session = candidate(key: "claude:gen", percentUsed: 30, windowName: "Session")
        let weekly = candidate(
            key: "Claude Code:gen:weekly",
            percentUsed: 80,
            windowName: "Weekly",
            isAutoSelectable: false
        )

        let selection = select([session, weekly], bundleID: terminalBundleID)

        // Only Auto windows compete, exactly like `StatusItemLimitSelector`.
        XCTAssertEqual(selection?.key, "claude:gen")
    }

    func testMappedProviderWithSeveralAccountsPicksTheTightestOne() {
        let gen = candidate(key: "claude:gen", accountKey: "gen", percentUsed: 30)
        let ship = candidate(key: "claude:ship", accountKey: "ship", percentUsed: 70)

        XCTAssertEqual(select([gen, ship], bundleID: terminalBundleID)?.key, "claude:ship")
    }

    func testMappedProviderWithEveryAccountSpentStillResolves() {
        let gen = candidate(key: "claude:gen", accountKey: "gen", percentUsed: 100)
        let ship = candidate(key: "claude:ship", accountKey: "ship", percentUsed: 100)

        XCTAssertNotNil(select([gen, ship], bundleID: terminalBundleID))
    }

    func testMappedProviderSkipsSpentAccountsWhileAnotherHasQuotaLeft() {
        let gen = candidate(key: "claude:gen", accountKey: "gen", percentUsed: 100)
        let ship = candidate(key: "claude:ship", accountKey: "ship", percentUsed: 60)

        XCTAssertEqual(select([gen, ship], bundleID: terminalBundleID)?.key, "claude:ship")
    }

    // MARK: - Fallback to Auto

    func testUnmappedFrontmostAppFallsBackToAutoSelection() {
        let claude = candidate(key: "claude:gen", percentUsed: 20)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        XCTAssertNil(select([claude, cursor], bundleID: unknownBundleID))
    }

    func testUnknownFrontmostAppFallsBackToAutoSelection() {
        let claude = candidate(key: "claude:gen", percentUsed: 20)

        XCTAssertNil(select([claude], bundleID: nil))
        XCTAssertNil(select([claude], bundleID: "   "))
    }

    func testMappingToAHiddenProviderIsTreatedAsUnmapped() {
        let claude = candidate(key: "claude:gen", percentUsed: 20)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        let selection = select(
            [claude, cursor],
            bundleID: cursorBundleID,
            visibleServices: [.claudeCode, .codexCli]
        )

        XCTAssertNil(selection)
    }

    func testMappingToAProviderWithNoDataIsTreatedAsUnmapped() {
        let claude = candidate(key: "claude:gen", percentUsed: 20)

        XCTAssertNil(select([claude], bundleID: cursorBundleID))
    }

    func testMappingToAProviderWithNoAutoSelectableWindowIsTreatedAsUnmapped() {
        let cursorReview = candidate(
            key: "Cursor:default:codeReview",
            service: .cursor,
            percentUsed: 10,
            windowName: "Code Review",
            isAutoSelectable: false
        )

        XCTAssertNil(select([cursorReview], bundleID: cursorBundleID))
    }

    // MARK: - Critical priority

    func testCriticalQuotaElsewhereOverridesTheFocusMapping() {
        let claude = candidate(key: "claude:gen", percentUsed: 92)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        XCTAssertEqual(QuotaBand.forLimit(claude.limit), .critical)
        XCTAssertNil(select([claude, cursor], bundleID: cursorBundleID))
    }

    func testExhaustedQuotaElsewhereOverridesTheFocusMapping() {
        let claude = candidate(key: "claude:gen", percentUsed: 100)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        XCTAssertNil(select([claude, cursor], bundleID: cursorBundleID))
    }

    func testFocusFollowingResumesOnceTheCriticalQuotaClears() {
        let recovered = candidate(key: "claude:gen", percentUsed: 60)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        XCTAssertEqual(select([recovered, cursor], bundleID: cursorBundleID)?.key, "cursor")
    }

    func testTightQuotaElsewhereDoesNotOverrideTheFocusMapping() {
        // Only the critical/exhausted bands take priority; "tight" is normal.
        let claude = candidate(key: "claude:gen", percentUsed: 80)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        XCTAssertEqual(QuotaBand.forLimit(claude.limit), .tight)
        XCTAssertEqual(select([claude, cursor], bundleID: cursorBundleID)?.key, "cursor")
    }

    func testFocusedProviderInCriticalStaysSelected() {
        // The override exists to surface a quota the user cannot see; when the
        // focused provider is the critical one there is nothing to surface.
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 95)
        let claude = candidate(key: "claude:gen", percentUsed: 20)

        XCTAssertEqual(select([cursor, claude], bundleID: cursorBundleID)?.key, "cursor")
    }

    func testHiddenProviderInCriticalDoesNotOverrideTheFocusMapping() {
        let hiddenClaude = candidate(key: "claude:gen", percentUsed: 95)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        let selection = select(
            [hiddenClaude, cursor],
            bundleID: cursorBundleID,
            visibleServices: [.cursor]
        )

        XCTAssertEqual(selection?.key, "cursor")
    }

    // MARK: - Planner integration

    private func plan(
        _ candidates: [StatusLimitCandidate],
        mode: MenuBarPresentationMode = .merged,
        pinnedKey: String? = nil,
        focus: MenuBarFocusContext? = nil,
        rotationTick: Int? = nil
    ) -> [MenuBarStatusItemDescriptor] {
        MenuBarStatusItemPlanner.plan(
            mode: mode,
            candidates: candidates,
            previousKey: nil,
            pinnedKey: pinnedKey,
            metric: .percentLeft,
            size: .compact,
            focus: focus,
            rotationTick: rotationTick,
            now: now
        )
    }

    func testMergedModeShowsTheFocusedProvider() {
        let claude = candidate(key: "claude:gen", percentUsed: 20, activeMinutesAgo: 1)
        let cursor = candidate(
            key: "cursor",
            service: .cursor,
            percentUsed: 40,
            displayName: "Cursor",
            windowName: "Monthly"
        )

        let descriptors = plan([claude, cursor], focus: context(bundleID: cursorBundleID))

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.service, .cursor)
        XCTAssertEqual(descriptors.first?.selectionKey, "cursor")
        XCTAssertEqual(descriptors.first?.title, " 60%")
        // Focus behaves like Auto, not like a pin: no window qualifier.
        XCTAssertEqual(descriptors.first?.tooltip, "MeterBar: 60% left on Cursor")
    }

    func testMergedModeWithoutFocusBehavesExactlyAsBefore() {
        let claude = candidate(key: "claude:gen", percentUsed: 20, activeMinutesAgo: 1)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        let baseline = plan([claude, cursor])

        XCTAssertEqual(plan([claude, cursor], focus: nil), baseline)
        // Toggle on but nothing mapped is still the untouched Auto behavior.
        XCTAssertEqual(
            plan([claude, cursor], focus: context(bundleID: unknownBundleID)),
            baseline
        )
        XCTAssertEqual(baseline.first?.selectionKey, "claude:gen")
    }

    func testPinBeatsTheFocusMapping() {
        let claude = candidate(key: "claude:gen", percentUsed: 20, pinKey: "Claude Code:gen:session")
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        let descriptors = plan(
            [claude, cursor],
            pinnedKey: "Claude Code:gen:session",
            focus: context(bundleID: cursorBundleID)
        )

        XCTAssertEqual(descriptors.first?.selectionKey, "claude:gen")
    }

    func testFocusMappingBeatsRotationWhenBothAreEnabled() {
        let claude = candidate(key: "claude:gen", percentUsed: 20, activeMinutesAgo: 1)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        let descriptors = plan(
            [claude, cursor],
            focus: context(bundleID: cursorBundleID),
            rotationTick: 0
        )

        XCTAssertEqual(descriptors.first?.selectionKey, "cursor")
    }

    func testUnmappedFocusedAppKeepsAutoEvenWithADefensiveRotationTick() {
        let claude = candidate(key: "claude:gen", percentUsed: 20, activeMinutesAgo: 1)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        let descriptors = plan(
            [claude, cursor],
            focus: context(bundleID: unknownBundleID),
            rotationTick: 1
        )

        XCTAssertEqual(descriptors.first?.selectionKey, "claude:gen")
    }

    func testFocusIsIgnoredOutsideMergedMode() {
        let claude = candidate(key: "claude:gen", percentUsed: 20)
        let cursor = candidate(key: "cursor", service: .cursor, percentUsed: 40)

        let focused = plan([claude, cursor], mode: .perProvider, focus: context(bundleID: cursorBundleID))

        XCTAssertEqual(focused, plan([claude, cursor], mode: .perProvider))
        XCTAssertEqual(focused.count, 2)
    }

    // MARK: - Catalog

    func testEveryTerminalIsOfferedButNoneShipsMapped() {
        let offered = Set(MenuBarFocusAppCatalog.apps.map(\.bundleID))
        for terminal in MenuBarFocusAppCatalog.terminalBundleIDs {
            XCTAssertTrue(offered.contains(terminal), "\(terminal) is flagged a terminal but never offered")
            // MeterBar does not look inside a terminal, so it cannot guess.
            XCTAssertNil(MenuBarFocusAppCatalog.defaultMapping[terminal])
        }
    }

    func testDefaultMappingOnlyCoversUnambiguousApps() {
        XCTAssertEqual(MenuBarFocusAppCatalog.defaultMapping, [MenuBarFocusAppCatalog.cursorBundleID: .cursor])
    }

    func testCatalogRowsIncludeAppsTheUserMappedThemselves() {
        let rows = MenuBarFocusAppCatalog.rows(for: [unknownBundleID: .claudeCode])

        XCTAssertEqual(rows.count, MenuBarFocusAppCatalog.apps.count + 1)
        XCTAssertEqual(rows.last?.bundleID, unknownBundleID)
        // No display name is known for an app MeterBar does not ship, so the
        // identifier itself has to stand in — an unlabelled row is unusable.
        XCTAssertEqual(rows.last?.displayName, unknownBundleID)
    }

    func testCatalogRowsDoNotDuplicateKnownApps() {
        let rows = MenuBarFocusAppCatalog.rows(for: MenuBarFocusAppCatalog.defaultMapping)

        XCTAssertEqual(rows.map(\.bundleID), MenuBarFocusAppCatalog.apps.map(\.bundleID))
    }
}
