import MeterBarShared
import XCTest

@testable import MeterBar

/// Locks the bounded visible copy and the richer spoken copy for issue #269.
/// These are presentation-model tests, so they cover every status-item layout
/// without depending on an `NSStatusBar` being available in the test process.
final class StatusItemRenderingContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCombinedPercentModesUseBoundedSessionWeeklyAbbreviations() {
        let compact = plan(
            candidates(),
            metric: .percentLeft,
            size: .compact,
            windowMode: .combined
        )
        let regular = plan(
            candidates(),
            metric: .percentUsed,
            size: .regular,
            windowMode: .combined
        )

        XCTAssertEqual(compact.title, " S58% · W29%")
        XCTAssertEqual(
            compact.accessibilityLabel,
            "MeterBar Session 58% left; Weekly 29% left on Work (Claude Code)"
        )
        XCTAssertEqual(regular.title, " S 42% used · W 71% used")
        XCTAssertLessThanOrEqual(
            regular.title.count,
            StatusItemLabelFormatter.maximumCombinedTitleCharacters + 1
        )
    }

    func testCombinedPaceShowsReserveAndDeficitWithoutClippingTheContract() {
        let session = candidate(
            windowID: "session",
            windowName: "Session",
            used: 28,
            resetIn: 3 * 60 * 60,
            windowSeconds: 10 * 60 * 60
        )
        let weekly = candidate(
            windowID: "weekly",
            windowName: "Weekly",
            used: 80,
            resetIn: 5 * 24 * 60 * 60,
            windowSeconds: 7 * 24 * 60 * 60,
            isAutoSelectable: false
        )

        let descriptor = plan(
            [session, weekly],
            metric: .pace,
            size: .compact,
            windowMode: .combined
        )

        XCTAssertEqual(descriptor.title, " SR42% · WD51%")
        XCTAssertEqual(
            descriptor.accessibilityLabel,
            "MeterBar Session 42% in reserve; Weekly 51% in deficit on Work (Claude Code)"
        )
        XCTAssertLessThanOrEqual(
            descriptor.title.count,
            StatusItemLabelFormatter.maximumCombinedTitleCharacters + 1
        )
    }

    func testWorstCaseCombinedTokensStayInsideTheDeclaredWidthPolicy() {
        let farFuture = candidate(
            windowID: "session",
            windowName: "Session",
            used: 100,
            resetIn: 200 * 24 * 60 * 60,
            windowSeconds: 365 * 24 * 60 * 60
        )
        let extremeDeficit = candidate(
            windowID: "weekly",
            windowName: "Weekly",
            used: 100,
            resetIn: 6 * 24 * 60 * 60,
            windowSeconds: 7 * 24 * 60 * 60,
            isAutoSelectable: false
        )

        let countdown = plan(
            [farFuture, extremeDeficit],
            metric: .percentLeft,
            size: .regular,
            windowMode: .combined,
            showsExhaustedResetCountdown: true
        )
        let pace = plan(
            [farFuture, extremeDeficit],
            metric: .pace,
            size: .regular,
            windowMode: .combined
        )

        XCTAssertEqual(countdown.title, " S reset 99d+ · W reset 6d")
        XCTAssertLessThanOrEqual(
            countdown.title.count,
            StatusItemLabelFormatter.maximumCombinedTitleCharacters + 1
        )
        XCTAssertLessThanOrEqual(
            pace.title.count,
            StatusItemLabelFormatter.maximumCombinedTitleCharacters + 1
        )
    }

    func testExhaustedWindowUsesBoundedCountdownOnlyWhenOptionIsEnabled() {
        let exhausted = candidate(
            windowID: "session",
            windowName: "Session",
            used: 100,
            resetIn: 3_660,
            windowSeconds: 5 * 60 * 60
        )

        let defaultDescriptor = plan([exhausted], metric: .percentLeft, size: .compact)
        let countdownDescriptor = plan(
            [exhausted],
            metric: .percentLeft,
            size: .compact,
            showsExhaustedResetCountdown: true
        )

        XCTAssertEqual(defaultDescriptor.title, " 0%")
        XCTAssertEqual(countdownDescriptor.title, " 1h1m")
        XCTAssertEqual(
            countdownDescriptor.accessibilityLabel,
            "MeterBar Session resets in 1h 1m on Work (Claude Code)"
        )
    }

    func testStaleSingleAndCombinedModesNeverRenderCachedValues() {
        let staleDate = now.addingTimeInterval(-ProviderParseHealthRecord.staleAfter - 1)
        let session = candidate(
            windowID: "session",
            windowName: "Session",
            used: 42,
            resetIn: 3_600,
            windowSeconds: 5 * 60 * 60,
            lastUpdated: staleDate
        )
        let weekly = candidate(
            windowID: "weekly",
            windowName: "Weekly",
            used: 71,
            resetIn: 4 * 24 * 60 * 60,
            windowSeconds: 7 * 24 * 60 * 60,
            lastUpdated: staleDate,
            isAutoSelectable: false
        )

        let single = plan([session, weekly], metric: .percentLeft, size: .compact)
        let combined = plan(
            [session, weekly],
            metric: .pace,
            size: .regular,
            windowMode: .combined
        )

        XCTAssertEqual(single.title, " —")
        XCTAssertEqual(single.accessibilityLabel, "MeterBar Session data stale on Work (Claude Code)")
        XCTAssertEqual(combined.title, " S — · W —")
        XCTAssertEqual(
            combined.accessibilityLabel,
            "MeterBar Session data stale; Weekly data stale on Work (Claude Code)"
        )
    }

    func testCombinedModeWithoutMetricsKeepsBothUnknownWindowsVisible() {
        let descriptor = plan(
            [],
            metric: .percentLeft,
            size: .compact,
            windowMode: .combined
        )

        XCTAssertEqual(descriptor.title, " S— · W—")
        XCTAssertEqual(
            descriptor.accessibilityLabel,
            "MeterBar Session usage unavailable; Weekly usage unavailable"
        )
    }

    func testFontSizeAndContrastStyleAreCarriedByEveryDescriptor() {
        let descriptor = plan(
            candidates(),
            metric: .percentLeft,
            size: .compact,
            fontSize: .large,
            highContrast: true
        )

        XCTAssertEqual(descriptor.visualStyle.fontSize, .large)
        XCTAssertTrue(descriptor.visualStyle.highContrast)
        XCTAssertNil(StatusItemFontSize.standard.pointSize)
        XCTAssertEqual(StatusItemFontSize.small.pointSize, 11)
        XCTAssertEqual(StatusItemFontSize.large.pointSize, 15)
        XCTAssertEqual(StatusItemContrastPalette.tone(highContrast: true, appearance: .light), .black)
        XCTAssertEqual(StatusItemContrastPalette.tone(highContrast: true, appearance: .dark), .white)
        XCTAssertEqual(StatusItemContrastPalette.tone(highContrast: false, appearance: .light), .automatic)
        XCTAssertEqual(StatusItemContrastPalette.tone(highContrast: false, appearance: .dark), .automatic)
    }

    func testCombinedFormattingWorksForPerProviderAndPerAccountLayouts() {
        let perProvider = MenuBarStatusItemPlanner.plan(
            mode: .perProvider,
            candidates: candidates(),
            previousKey: nil,
            pinnedKey: nil,
            metric: .percentLeft,
            size: .compact,
            windowMode: .combined,
            now: now
        )
        let accountKey = "Claude Code:account"
        let scoped = candidates().map { value in
            candidate(
                windowID: value.windowID,
                windowName: value.windowName,
                used: value.limit.used,
                resetIn: value.limit.resetTime?.timeIntervalSince(now),
                windowSeconds: value.limit.windowSeconds,
                accountKey: accountKey,
                isAutoSelectable: value.isAutoSelectable
            )
        }
        let perAccount = MenuBarStatusItemPlanner.plan(
            mode: .perAccount,
            accountPlan: MenuBarAccountItemPlan(
                mode: .perAccount,
                entries: [
                    MenuBarAccountItemEntry(
                        id: accountKey,
                        accountKey: accountKey,
                        displayName: "Work",
                        badge: "W",
                        showsAccountSwitcher: false
                    )
                ]
            ),
            candidates: scoped,
            previousKey: nil,
            pinnedKey: nil,
            metric: .percentLeft,
            size: .compact,
            windowMode: .combined,
            now: now
        )

        XCTAssertEqual(perProvider.first?.title, " S58% · W29%")
        XCTAssertEqual(perAccount.first?.title, " W S58% · W29%")
    }

    private func candidates() -> [StatusLimitCandidate] {
        [
            candidate(
                windowID: "session",
                windowName: "Session",
                used: 42,
                resetIn: 3 * 60 * 60,
                windowSeconds: 5 * 60 * 60
            ),
            candidate(
                windowID: "weekly",
                windowName: "Weekly",
                used: 71,
                resetIn: 4 * 24 * 60 * 60,
                windowSeconds: 7 * 24 * 60 * 60,
                isAutoSelectable: false
            )
        ]
    }

    private func candidate(
        windowID: String,
        windowName: String,
        used: Double,
        resetIn: TimeInterval?,
        windowSeconds: TimeInterval?,
        lastUpdated: Date? = nil,
        accountKey: String? = nil,
        isAutoSelectable: Bool = true
    ) -> StatusLimitCandidate {
        StatusLimitCandidate(
            key: "claude:\(windowID)",
            pinKey: "Claude Code:account:\(windowID)",
            service: .claudeCode,
            accountKey: accountKey,
            displayName: "Work (Claude Code)",
            windowID: windowID,
            windowName: windowName,
            limit: UsageLimit(
                used: used,
                total: 100,
                resetTime: resetIn.map { now.addingTimeInterval($0) },
                windowSeconds: windowSeconds
            ),
            lastUpdated: lastUpdated ?? now,
            lastActivity: now.addingTimeInterval(-60),
            isAutoSelectable: isAutoSelectable
        )
    }

    private func plan(
        _ candidates: [StatusLimitCandidate],
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize,
        windowMode: StatusItemWindowMode = .selected,
        fontSize: StatusItemFontSize = .standard,
        highContrast: Bool = false,
        showsExhaustedResetCountdown: Bool = false
    ) -> MenuBarStatusItemDescriptor {
        MenuBarStatusItemPlanner.plan(
            mode: .merged,
            candidates: candidates,
            previousKey: nil,
            pinnedKey: nil,
            metric: metric,
            size: size,
            windowMode: windowMode,
            fontSize: fontSize,
            highContrast: highContrast,
            showsExhaustedResetCountdown: showsExhaustedResetCountdown,
            now: now
        )[0]
    }
}
