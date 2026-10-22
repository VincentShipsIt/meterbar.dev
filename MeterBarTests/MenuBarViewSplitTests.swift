import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

/// Coverage for the logic lifted out of the 958-line `MenuBarView.swift` when it
/// was split into a shell plus focused collaborators. Everything asserted here
/// used to be a `private` computed property or method on a `View`, reachable only
/// through a hosting view; extracting the pure rules first makes the popover's
/// sizing math, status copy, and reset-credit error mapping directly testable.
@MainActor
final class MenuBarPopoverGeometryTests: XCTestCase {
    // MARK: - Window with a hover open

    func testWindowIsJustThePopoverWhileNoHoverIsOpen() {
        let popover = NSSize(width: 390, height: 500)
        let size = MenuBarPopoverGeometry.windowSize(
            popover: popover,
            hasDetail: false,
            maximumHeight: 760
        )
        XCTAssertEqual(size, popover)
    }

    func testOpenHoverWidensTheWindowOnTheLeftOnly() {
        let size = MenuBarPopoverGeometry.windowSize(
            popover: NSSize(width: 390, height: 500),
            hasDetail: true,
            maximumHeight: 760
        )
        XCTAssertEqual(size.width, 390 + MenuBarPopoverGeometry.detailExtension)
        XCTAssertEqual(size.height, 760)
    }

    func testHoverCanvasReservesTheScreenCeiling() {
        let tall = MenuBarPopoverGeometry.windowSize(
            popover: NSSize(width: 390, height: 500),
            hasDetail: true,
            maximumHeight: 760
        )
        XCTAssertEqual(tall.height, 760)

        let clamped = MenuBarPopoverGeometry.windowSize(
            popover: NSSize(width: 390, height: 500),
            hasDetail: true,
            maximumHeight: 584
        )
        XCTAssertEqual(clamped.height, 584)
    }

    /// The column tucks into the popover's card inset: the visible gap between
    /// the hover and the popover cards is `detailGap`, not 18pt.
    func testHoverSitsOneGapFromThePopoverCards() {
        let gap = MenuBarPopoverGeometry.popoverCardMinX - MenuBarPopoverGeometry.detailWidth
        XCTAssertEqual(gap, MenuBarPopoverGeometry.detailGap)
    }

    /// The hover lines up with its card, and a tall hover for a low card moves
    /// up just enough to stay whole instead of being cut at the bottom.
    func testHoverColumnStaysLevelWithItsCardUnlessItWouldOverflow() {
        XCTAssertEqual(MenuBarPopoverGeometry.detailTop(sourceTop: 120, detailHeight: 300, maximumHeight: 760), 120)
        XCTAssertEqual(MenuBarPopoverGeometry.detailTop(sourceTop: 600, detailHeight: 300, maximumHeight: 760), 460)
        XCTAssertEqual(MenuBarPopoverGeometry.detailTop(sourceTop: 600, detailHeight: 900, maximumHeight: 760), 0)
    }

    func testMaximumHeightClampsToTheHardCapOnTallScreens() {
        XCTAssertEqual(MenuBarPopoverGeometry.maximumHeight(visibleScreenHeight: 2000), 760)
    }

    func testHoverUsesScreenSpaceBeyondTheMainPopoverCap() {
        let ceiling = MenuBarPopoverGeometry.maximumDetailHeight(visibleScreenHeight: 1200)
        XCTAssertEqual(ceiling, 1184)
        let size = MenuBarPopoverGeometry.windowSize(
            popover: NSSize(width: 390, height: 500), hasDetail: true, maximumHeight: ceiling
        )
        XCTAssertEqual(size.height, 1184)
        XCTAssertEqual(MenuBarPopoverGeometry.detailTop(sourceTop: 400, detailHeight: 900, maximumHeight: ceiling), 284)
    }

    func testHoverViewportFitsContentAndScrollsOnlyAtTheScreenBoundary() {
        typealias Viewport = HoverColumnViewport<EmptyView>
        XCTAssertEqual(Viewport.height(contentHeight: 900, maximumHeight: 1184), 900)
        XCTAssertEqual(Viewport.height(contentHeight: 1400, maximumHeight: 1184), 1184)
        XCTAssertEqual(Viewport.height(contentHeight: 300, maximumHeight: 584), 300)
        XCTAssertEqual(MenuBarPopoverGeometry.maximumDetailHeight(visibleScreenHeight: 100), 84)
    }

    func testTallHoverRendersItsFooterBelowTheOldCeiling() throws {
        let host = NSHostingView(rootView: HoverColumnViewport(maximumHeight: 1184) {
            VStack(spacing: 0) {
                Color.red.frame(height: 900)
                Color.green.frame(height: 30)
            }
        }.frame(width: 340))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 1184)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 760)
        let footerIsVisible = (0..<bitmap.pixelsHigh).contains { y in
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB) else {
                return false
            }
            return color.alphaComponent > 0.5 && color.greenComponent > 0.6
                && color.redComponent < 0.4 && color.blueComponent < 0.4
        }
        XCTAssertTrue(footerIsVisible, "The footer below 900 points must render instead of being clipped at 760")
    }

    func testMaximumHeightSubtractsScreenPaddingOnBothEdges() {
        // 600 - (8 * 2) = 584, below the 760 cap and above the 180 floor.
        XCTAssertEqual(MenuBarPopoverGeometry.maximumHeight(visibleScreenHeight: 600), 584)
    }

    func testMaximumHeightNeverDropsBelowTheMinimumPopoverHeight() {
        XCTAssertEqual(MenuBarPopoverGeometry.maximumHeight(visibleScreenHeight: 100), 180)
    }

    func testScrollHeightFloorsAtTheMinimumScrollHeight() {
        let scroll = MenuBarPopoverGeometry.scrollHeight(contentHeight: 10, maximumHeight: 760)
        XCTAssertEqual(scroll, MenuBarPopoverGeometry.minimumScrollHeight)
    }

    func testScrollHeightLeavesRoomForTheChrome() {
        let scroll = MenuBarPopoverGeometry.scrollHeight(contentHeight: 5000, maximumHeight: 760)
        XCTAssertEqual(scroll, 760 - MenuBarPopoverGeometry.chromeHeight)
    }

    func testScrollHeightPassesThroughMeasuredContent() {
        XCTAssertEqual(MenuBarPopoverGeometry.scrollHeight(contentHeight: 320, maximumHeight: 760), 320)
    }

    func testPopoverHeightAddsChromeAndClampsToTheMinimum() {
        let height = MenuBarPopoverGeometry.popoverHeight(scrollHeight: 80, maximumHeight: 760)
        XCTAssertEqual(height, MenuBarPopoverGeometry.minimumHeight, "The compact footer plus 80 is below the 180 floor")
    }

    func testPopoverHeightClampsToTheMaximum() {
        let height = MenuBarPopoverGeometry.popoverHeight(scrollHeight: 740, maximumHeight: 760)
        XCTAssertEqual(height, 760)
    }

    func testContentSizeKeepsTheFixedPopoverWidth() {
        let size = MenuBarPopoverGeometry.contentSize(contentHeight: 320, maximumHeight: 760)
        XCTAssertEqual(size.width, MenuBarPopoverGeometry.width)
        XCTAssertEqual(size.height, MenuBarPopoverGeometry.chromeHeight + 320)
    }

    func testContentSizeMatchesTheRenderedPopoverHeight() {
        // The size reported to the menu-bar controller and the size the view
        // renders at must agree, otherwise the window clips or leaves a gap.
        for contentHeight in [0, 40, 180, 320, 900, 5000] as [CGFloat] {
            let maximumHeight = MenuBarPopoverGeometry.maximumHeight(visibleScreenHeight: 900)
            let scroll = MenuBarPopoverGeometry.scrollHeight(
                contentHeight: contentHeight,
                maximumHeight: maximumHeight
            )
            let rendered = MenuBarPopoverGeometry.popoverHeight(scrollHeight: scroll, maximumHeight: maximumHeight)
            let reported = MenuBarPopoverGeometry.contentSize(
                contentHeight: contentHeight,
                maximumHeight: maximumHeight
            )
            XCTAssertEqual(reported.height, rendered, "content height \(contentHeight) disagreed")
        }
    }
}

@MainActor
final class ProviderStatusDotsSummaryTests: XCTestCase {
    func testNoIssuesReadsAsFullyOperational() {
        XCTAssertEqual(ProviderStatusDotsSummary.text(issueCount: 0), "All provider pages operational")
    }

    func testSingleIssueUsesSingularCopy() {
        XCTAssertEqual(ProviderStatusDotsSummary.text(issueCount: 1), "1 provider needs attention")
    }

    func testMultipleIssuesUsePluralCopy() {
        XCTAssertEqual(ProviderStatusDotsSummary.text(issueCount: 3), "3 providers need attention")
    }
}

@MainActor
final class ProviderCardPresentationTests: XCTestCase {
    private func snapshot(
        updatedAt: Date? = Date(),
        used: Double = 40,
        resetCreditsAvailable: Int? = nil,
        service: ServiceType = .codexCli
    ) -> ProviderSnapshot {
        let weekly = UsageLimit(
            used: used,
            total: 100,
            resetTime: Date().addingTimeInterval(7200),
            windowSeconds: 604_800
        )
        return ProviderSnapshot(
            id: "codex",
            title: "Codex",
            service: service,
            updatedAt: updatedAt,
            limits: updatedAt == nil ? [] : [
                SnapshotLimit(id: "weekly", kind: .weekly, title: "Weekly", usageLimit: weekly)
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: resetCreditsAvailable,
            accountID: nil
        )
    }

    func testStatusTextFallsBackToOfflineWithoutABand() {
        XCTAssertEqual(ProviderCardPresentation.statusText(for: snapshot(updatedAt: nil)), "Offline")
    }

    func testStatusTextUsesTheBandLabel() {
        let ready = snapshot()
        XCTAssertEqual(ProviderCardPresentation.statusText(for: ready), ready.band?.shortLabel)
    }

    func testStatusColorFallsBackToSecondaryWithoutABand() {
        XCTAssertEqual(ProviderCardPresentation.statusColor(for: snapshot(updatedAt: nil)), Color.secondary)
    }

    func testDetailNavigationRequiresASelectionHandler() {
        XCTAssertFalse(
            ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: false, snapshot: snapshot())
        )
        XCTAssertTrue(
            ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: true, snapshot: snapshot())
        )
    }

    func testDetailNavigationIsDeniedWithoutMetrics() {
        XCTAssertFalse(
            ProviderCardPresentation.allowsDetailNavigation(
                hasSelectionHandler: true,
                snapshot: snapshot(updatedAt: nil)
            )
        )
    }

    func testDetailNavigationIsDeniedOnExhaustedCards() {
        let exhausted = snapshot(used: 100)
        XCTAssertTrue(exhausted.hasExhaustedLimit, "fixture should be exhausted")
        XCTAssertFalse(
            ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: true, snapshot: exhausted)
        )
    }

    func testResetCreditActionRequiresCodexAnExhaustedWindowCreditsAndAuth() {
        let exhausted = snapshot(used: 100, resetCreditsAvailable: 1)
        XCTAssertTrue(
            ProviderCardPresentation.showsResetCreditAction(
                snapshot: exhausted,
                hasPendingConsumption: false,
                isAuthenticated: true,
                hasResolvedAccount: true
            )
        )
        XCTAssertFalse(
            ProviderCardPresentation.showsResetCreditAction(
                snapshot: exhausted,
                hasPendingConsumption: true,
                isAuthenticated: true,
                hasResolvedAccount: true
            ),
            "a credit spent but not yet reflected in this count must not be offered again"
        )
        XCTAssertFalse(
            ProviderCardPresentation.showsResetCreditAction(
                snapshot: exhausted,
                hasPendingConsumption: false,
                isAuthenticated: false,
                hasResolvedAccount: true
            )
        )
        XCTAssertFalse(
            ProviderCardPresentation.showsResetCreditAction(
                snapshot: snapshot(used: 100, resetCreditsAvailable: 0),
                hasPendingConsumption: false,
                isAuthenticated: true,
                hasResolvedAccount: true
            )
        )
        XCTAssertFalse(
            ProviderCardPresentation.showsResetCreditAction(
                snapshot: snapshot(used: 100, resetCreditsAvailable: 1, service: .claudeCode),
                hasPendingConsumption: false,
                isAuthenticated: true,
                hasResolvedAccount: true
            ),
            "reset credits are Codex CLI and Grok only"
        )
        XCTAssertTrue(
            ProviderCardPresentation.showsResetCreditAction(
                snapshot: snapshot(used: 100, resetCreditsAvailable: 1, service: .xai),
                hasPendingConsumption: false,
                isAuthenticated: true,
                hasResolvedAccount: true
            )
        )
        XCTAssertFalse(
            ProviderCardPresentation.showsResetCreditAction(
                snapshot: exhausted,
                hasPendingConsumption: false,
                isAuthenticated: true,
                hasResolvedAccount: false
            ),
            "redemption targets a specific CODEX_HOME, so an unresolved account cannot be spent"
        )
    }
}

@MainActor
final class ProviderCardResetCreditOutcomeTests: XCTestCase {
    func testThrownErrorsUseTheFailureTitleAndTheirOwnDescription() {
        let alert = ProviderCardResetCreditOutcome.alert(for: CodexResetCreditError.noAvailableCredit)
        XCTAssertEqual(alert.title, ProviderCardResetCreditOutcome.failureTitle)
        XCTAssertEqual(alert.message, CodexResetCreditError.noAvailableCredit.localizedDescription)
    }

    func testACleanConsumptionRaisesNoAlert() {
        let consumption = CodexResetCreditConsumption(
            windowsReset: 1,
            refreshedMetrics: nil,
            usageRefreshErrorDescription: nil
        )
        XCTAssertNil(ProviderCardResetCreditOutcome.alert(for: consumption))
    }

    func testAFailedPostResetRefreshWarnsWithoutClaimingFailure() {
        let consumption = CodexResetCreditConsumption(
            windowsReset: 1,
            refreshedMetrics: nil,
            usageRefreshErrorDescription: "timed out"
        )
        let alert = ProviderCardResetCreditOutcome.alert(for: consumption)
        XCTAssertEqual(alert?.title, ProviderCardResetCreditOutcome.partialSuccessTitle)
        XCTAssertNotEqual(
            alert?.title,
            ProviderCardResetCreditOutcome.failureTitle,
            "the credit was spent — the copy must not read as a failure"
        )
        XCTAssertEqual(alert?.message?.contains("timed out"), true)
        XCTAssertEqual(alert?.message?.contains("Do not retry"), true)
    }
}

/// The split moved four view types into their own files. These guard the public
/// surface the popover, the dashboard, and the existing test suites construct.
@MainActor
final class MenuBarViewSplitSmokeTests: XCTestCase {
    func testMenuBarViewStillRenders() {
        let host = NSHostingView(rootView: MenuBarView())
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testPopoverOverviewPanelStillConstructsFromItsExplicitInitializer() {
        let panel = PopoverOverviewPanel(
            snapshots: [],
            openDashboard: {},
            openStatusDetail: {},
            openProviderOverview: { _ in }
        )
        let host = NSHostingView(rootView: panel.frame(width: 360))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.snapshots.isEmpty)
    }

    func testCardUsesTheSharedSnapshotUpdatedTextRatherThanAPrivateCopy() {
        let updatedAt = Date().addingTimeInterval(-120)
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "shipshitdev",
            service: .claudeCode,
            metrics: nil,
            emptyDetail: "Run claude login"
        )
        XCTAssertEqual(snapshot.updatedText, "No data")

        let dated = ProviderSnapshot(
            id: "claude",
            title: "Claude",
            service: .claudeCode,
            updatedAt: updatedAt,
            limits: [],
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
        XCTAssertEqual(dated.updatedText, "Updated \(UsageFormat.relative(updatedAt))")
    }

    func testReportPopoverCardFrameKeepsTheStatusCardIdentifier() {
        XCTAssertEqual(PopoverCardID.providerStatus, "popover-provider-status")

        var frames: [String: CGRect] = ["a": .zero]
        PopoverCardFramesPreferenceKey.reduce(value: &frames) { ["b": CGRect(x: 1, y: 2, width: 3, height: 4)] }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames["b"]?.width, 3)
    }
}

@MainActor
final class PopoverInteractionTests: XCTestCase {
    func testEnteringAnotherSourceDismissesPreviousDetailsEvenInsidePopover() {
        var ownership = PopoverHoverOwnership()
        ownership.isOverPopover = true
        ownership.updateSource(id: "codex", isHovered: true)
        ownership.updateDetail(id: "codex", isHovered: true)
        ownership.updateSource(id: "terminal-cursor", isHovered: true)
        XCTAssertTrue(ownership.shouldDismiss(detailID: "codex"))
    }

    func testGapBetweenSourceCardsKeepsCurrentDetailsOpen() {
        var ownership = PopoverHoverOwnership()
        ownership.isOverPopover = true
        ownership.updateSource(id: "first", isHovered: true)
        ownership.updateSource(id: "first", isHovered: false)
        XCTAssertFalse(ownership.shouldDismiss(detailID: "first"))
        ownership.updateSource(id: "second", isHovered: true)
        XCTAssertFalse(ownership.shouldDismiss(detailID: "second"))
        ownership.updateSource(id: "second", isHovered: false)
        ownership.isOverPopover = false
        XCTAssertTrue(ownership.shouldDismiss(detailID: "second"))
    }

    func testLateExitFromOldCardDoesNotDismissNewHover() {
        var ownership = PopoverHoverOwnership()
        ownership.updateSource(id: "old", isHovered: true)
        ownership.updateSource(id: "new", isHovered: true)
        ownership.updateSource(id: "old", isHovered: false)
        XCTAssertFalse(ownership.shouldDismiss(detailID: "new"))
        ownership.updateSource(id: "new", isHovered: false)
        XCTAssertTrue(ownership.shouldDismiss(detailID: "new"))
    }

    func testEnteringDetailKeepsItOpenAfterLeavingSource() {
        var ownership = PopoverHoverOwnership()
        ownership.updateSource(id: "provider", isHovered: true)
        ownership.updateDetail(id: "provider", isHovered: true)
        ownership.updateSource(id: "provider", isHovered: false)
        XCTAssertFalse(ownership.shouldDismiss(detailID: "provider"))
        ownership.updateDetail(id: "provider", isHovered: false)
        XCTAssertTrue(ownership.shouldDismiss(detailID: "provider"))
    }

    func testLateDetailExitDoesNotDismissAReplacementHover() {
        var ownership = PopoverHoverOwnership()
        ownership.updateDetail(id: "old", isHovered: true)
        ownership.updateDetail(id: "new", isHovered: true)
        ownership.updateDetail(id: "old", isHovered: false)
        XCTAssertFalse(ownership.shouldDismiss(detailID: "new"))
    }

    func testConnectionFailuresAreGroupedButQuotaAndStalenessAreNot() {
        func snapshot(_ title: String, notice: ProviderAuthNotice? = nil) -> ProviderSnapshot {
            ProviderSnapshotBuilder.snapshot(
                title: title, service: .codexCli,
                metrics: UsageMetrics(service: .codexCli, weeklyLimit: UsageLimit(used: 100, total: 100, resetTime: nil)),
                emptyDetail: "No data", authNotice: notice
            )
        }
        let login = snapshot("Login", notice: .loginRequired)
        var failure = snapshot("Failed")
        failure.issues = [.init(id: "auth", title: "Credentials", level: .fail, detail: "Login needed")]
        let stale = snapshot("Stale", notice: .stale(since: Date()))
        let exhausted = snapshot("Out")
        let unavailable = snapshot("Missing", notice: .notConnected)
        XCTAssertEqual(
            PopoverOverviewPanel.errorSnapshots(in: [login, failure, stale, exhausted, unavailable]).map(\.id),
            [login.id, failure.id, unavailable.id]
        )
    }
}
