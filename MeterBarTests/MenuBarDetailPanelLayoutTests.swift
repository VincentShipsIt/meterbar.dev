import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

final class MenuBarDetailPanelLayoutTests: XCTestCase {
    // A 1512x950 visible frame with the popover anchored near the top right,
    // mirroring the real menu-bar panel placement (AppKit bottom-left origin).
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 950)
    private let anchorFrame = CGRect(x: 1100, y: 300, width: 390, height: 600)

    func testHoverPolicyDismissesOnlyAfterLeavingBothPanels() {
        XCTAssertFalse(MeterBarMenuDetailHoverPolicy.shouldDismiss(
            sourceIsHovered: true,
            detailIsHovered: false
        ))
        XCTAssertFalse(MeterBarMenuDetailHoverPolicy.shouldDismiss(
            sourceIsHovered: false,
            detailIsHovered: true
        ))
        XCTAssertTrue(MeterBarMenuDetailHoverPolicy.shouldDismiss(
            sourceIsHovered: false,
            detailIsHovered: false
        ))
    }

    func testDefaultAlignsPanelTopToAnchorTop() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400
        )

        XCTAssertEqual(frame.maxY, anchorFrame.maxY)
        XCTAssertEqual(frame.height, 400)
    }

    func testPanelIsPlacedLeftOfAnchorWithGap() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400
        )

        XCTAssertEqual(frame.width, MeterBarMenuDetailPanelLayout.detailWidth)
        XCTAssertEqual(
            frame.maxX,
            anchorFrame.minX - MeterBarMenuDetailPanelLayout.panelGap
        )
    }

    func testPreferredTopAlignsPanelTopToClickedCard() {
        // A provider card whose top sits 280pt below the popover top.
        let cardTopY = anchorFrame.maxY - 280

        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400,
            preferredTopY: cardTopY
        )

        XCTAssertEqual(frame.maxY, cardTopY)
    }

    func testShortContentIsClampedToMinimumHeight() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 40
        )

        XCTAssertEqual(frame.height, MeterBarMenuDetailPanelLayout.minDetailHeight)
    }

    func testTallContentIsClampedToVisibleFrame() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 5000
        )

        let padding = MeterBarMenuDetailPanelLayout.screenPadding
        XCTAssertEqual(frame.height, visibleFrame.height - padding * 2)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + padding)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY - padding)
    }

    func testLowCardShiftsPanelUpToStayOnScreen() {
        // Card near the bottom of the screen: aligning tops would push the
        // panel below the visible frame, so it shifts up instead.
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400,
            preferredTopY: visibleFrame.minY + 200
        )

        XCTAssertEqual(frame.minY, visibleFrame.minY + MeterBarMenuDetailPanelLayout.screenPadding)
    }

    func testPreferredTopAboveScreenIsClampedToPadding() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400,
            preferredTopY: visibleFrame.maxY + 100
        )

        XCTAssertEqual(frame.maxY, visibleFrame.maxY - MeterBarMenuDetailPanelLayout.screenPadding)
    }
}

/// Guards the hover detail panel against drifting from the popover card it opens
/// from. The two surfaces hand-rolled separate headers and the panel grew a
/// divider, a section heading and per-row card surfaces the card never had, so
/// hovering a card swapped in something that read like a different provider.
@MainActor
final class MenuBarProviderDetailParityTests: XCTestCase {
    private func snapshot(hoursSinceRefresh: Double = 0) -> ProviderSnapshot {
        let weekly = UsageLimit(
            used: 40,
            total: 100,
            resetTime: Date().addingTimeInterval(3600),
            windowSeconds: 604_800
        )
        return ProviderSnapshot(
            id: "codex",
            title: "Codex",
            service: .codexCli,
            updatedAt: Date().addingTimeInterval(-hoursSinceRefresh * 3600),
            limits: [
                SnapshotLimit(id: "weekly", kind: .weekly, title: "Weekly", usageLimit: weekly)
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
    }

    private func cursorSnapshot() -> ProviderSnapshot {
        let weekly = UsageLimit(
            used: 40,
            total: 100,
            resetTime: Date().addingTimeInterval(3600),
            windowSeconds: 604_800
        )
        return ProviderSnapshot(
            id: "cursor",
            title: "Cursor",
            service: .cursor,
            updatedAt: Date(),
            limits: [
                SnapshotLimit(id: "weekly", kind: .weekly, title: "Weekly", usageLimit: weekly)
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
    }

    /// The parity that matters: both surfaces derive their identity row from the
    /// same component, so neither can quietly start showing a different field.
    func testDetailPanelHeaderMatchesTheCardHeader() {
        let snapshot = snapshot()

        XCTAssertEqual(
            MenuBarProviderDetailContent(snapshot: snapshot).headerContent,
            ProviderStatusCard(snapshot: snapshot).headerContent
        )
    }

    /// The panel used to label itself with the service name, which the card
    /// already shows as its title. The refresh time is the field that adds
    /// something.
    func testHeaderShowsRefreshTimeRatherThanServiceName() {
        let snapshot = snapshot(hoursSinceRefresh: 2)
        let content = ProviderCardHeader.Content(snapshot: snapshot)

        XCTAssertEqual(content.title, snapshot.title)
        XCTAssertEqual(content.subtitle, snapshot.updatedText)
        XCTAssertNotEqual(content.subtitle, snapshot.service.displayName)
    }

    private func quotaSnapshot(used: Double, notice: ProviderAuthNotice?) -> ProviderSnapshot {
        ProviderSnapshotBuilder.snapshot(
            title: "Work",
            service: .claudeCode,
            metrics: UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: used, total: 100, resetTime: nil)
            ),
            emptyDetail: "Run claude login",
            accountID: UUID(),
            authNotice: notice
        )
    }

    /// A working provider needs no badge. Quota health is already in the bars and charts, so
    /// "Healthy", "Tight" and "Critical" are noise on the header.
    func testHeaderStaysQuietWhileTheConnectionIsHealthy() {
        XCTAssertNil(ProviderCardHeader.Content(snapshot: snapshot()).statusText)
        XCTAssertNil(ProviderCardHeader.Content(snapshot: quotaSnapshot(used: 12, notice: nil)).statusText)
        XCTAssertNil(ProviderCardHeader.Content(snapshot: quotaSnapshot(used: 80, notice: nil)).statusText)
        XCTAssertNil(ProviderCardHeader.Content(snapshot: quotaSnapshot(used: 95, notice: nil)).statusText)
    }

    /// The panel once dropped the status word entirely, so a logged-out provider looked healthy the
    /// moment the pointer landed on it. The header speaks up for exactly these states, on both surfaces.
    func testHeaderNamesABrokenOrStaleConnection() {
        let notices: [ProviderAuthNotice] = [
            .loginRequired,
            .stale(since: Date(timeIntervalSince1970: 1_720_000_000)),
            .attention("boom"),
            .notConnected
        ]
        for notice in notices {
            let broken = quotaSnapshot(used: 12, notice: notice)
            XCTAssertEqual(ProviderCardHeader.Content(snapshot: broken).statusText, notice.shortLabel)
            XCTAssertEqual(
                ProviderCardHeader.Content(snapshot: broken).statusText,
                ProviderCardPresentation.statusText(for: broken)
            )
        }
    }

    /// The panel's own freshness note (#530) must reflect the cost scan it was
    /// given, not the quota poll the header already speaks for — asserted
    /// directly on the computed property rather than a rendered strip.
    func testCostScanFreshnessNoteComparesTheInjectedScanDateToTheSnapshotsPoll() {
        let providerSnapshot = snapshot()
        guard let pollTime = providerSnapshot.updatedAt else {
            return XCTFail("snapshot() should always report a quota-poll time")
        }
        let staleScan = pollTime.addingTimeInterval(-(CostScanFreshnessNote.materiallyOlderThreshold + 60))
        let content = MenuBarProviderDetailContent(snapshot: providerSnapshot, costScanDate: staleScan)

        XCTAssertEqual(
            content.costScanFreshnessNote,
            CostScanFreshnessNote(quotaPollUpdatedAt: pollTime, costScanDate: staleScan)
        )
        XCTAssertNotNil(content.costScanFreshnessNote.text)
    }

    /// No cost scan was ever wired in (the default): the note says so rather
    /// than silently agreeing with a fresh header.
    func testCostScanFreshnessNoteDefaultsToNeverScannedWhenNoScanDateIsProvided() {
        let content = MenuBarProviderDetailContent(snapshot: snapshot())
        XCTAssertEqual(content.costScanFreshnessNote.text, "Not scanned yet")
    }

    func testDetailPanelRendersAtPanelWidth() {
        let content = MenuBarProviderDetailContent(snapshot: snapshot())
        let host = NSHostingView(
            rootView: content.frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// The panel's height is measured from its hosted content, so anything added
    /// to it grows the window. Seven bars is the reason the size was chosen over
    /// ``DailyUsageChart``'s thirty, and this pins that it stays a strip: 600pt
    /// is comfortably inside the visible frame of the smallest display MeterBar
    /// runs on (1280×800), so the panel never has to fall back to its scrolling
    /// variant just because the chart is present.
    func testTheSevenDayStripKeepsThePanelWithinASmallScreen() {
        let content = MenuBarProviderDetailContent(
            snapshot: snapshot(),
            dailyUsage: ProviderDailyUsageSeries(
                service: .codexCli,
                dailyUsage: (0..<7).map { offset in
                    DailyTokenUsage(
                        date: Date().addingTimeInterval(Double(-offset) * 86_400),
                        provider: .codexCli,
                        inputTokens: 900_000,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        estimatedCostUSD: 12
                    )
                }
            )
        )
        let host = NSHostingView(
            rootView: content.frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThan(host.fittingSize.height, 600)
    }

    /// The whole point of the change: hovering has to return something the card
    /// could not already show. If the strip ever stops rendering, the panel
    /// silently goes back to being a wider copy of the card.
    func testTheStripAddsHeightTheCardCopyDidNotHave() {
        let plain = NSHostingView(
            rootView: MenuBarProviderDetailContent(snapshot: snapshot())
                .frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        let charted = NSHostingView(
            rootView: MenuBarProviderDetailContent(
                snapshot: snapshot(),
                dailyUsage: ProviderDailyUsageSeries(service: .codexCli, dailyUsage: [])
            )
            .frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        plain.layoutSubtreeIfNeeded()
        charted.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(charted.fittingSize.height, plain.fittingSize.height)
    }

    func testCursorWithoutLedgerHistoryOmitsTheStripEntirely() {
        let plain = NSHostingView(
            rootView: MenuBarProviderDetailContent(snapshot: cursorSnapshot())
                .frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        let withEmptySeries = NSHostingView(
            rootView: MenuBarProviderDetailContent(
                snapshot: cursorSnapshot(),
                dailyUsage: ProviderDailyUsageSeries.make(
                    service: .cursor,
                    dailyUsage: [],
                    ledger: ProviderUsageLedger(),
                    accountCount: 1
                )
            )
            .frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        plain.layoutSubtreeIfNeeded()
        withEmptySeries.layoutSubtreeIfNeeded()

        XCTAssertEqual(plain.fittingSize.height, withEmptySeries.fittingSize.height)
    }

    func testHeaderRendersABrokenConnectionInline() {
        let currentSnapshot = quotaSnapshot(used: 12, notice: .loginRequired)
        let expectedStatus = ProviderCardPresentation.statusText(for: currentSnapshot)
        let headerHost = NSHostingView(rootView: ProviderCardHeader(snapshot: currentSnapshot))
        let identityHost = NSHostingView(
            rootView: HStack(spacing: 7) {
                ProviderLogoView(
                    kind: currentSnapshot.logoKind,
                    size: 17,
                    foregroundColor: currentSnapshot.accentColor
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(currentSnapshot.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(currentSnapshot.updatedText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        )
        let statusHost = NSHostingView(rootView: ProviderCardStatusLabel(snapshot: currentSnapshot))

        XCTAssertEqual(ProviderCardHeader.Content(snapshot: currentSnapshot).statusText, expectedStatus)
        XCTAssertGreaterThanOrEqual(
            headerHost.fittingSize.width,
            identityHost.fittingSize.width + statusHost.fittingSize.width,
            "Provider header should include identity and status"
        )
        XCTAssertEqual(
            headerHost.fittingSize.height,
            max(identityHost.fittingSize.height, statusHost.fittingSize.height),
            accuracy: 1,
            "Provider identity and status should stay on one row"
        )
        XCTAssertGreaterThan(headerHost.fittingSize.height, 0)
    }

    // MARK: - Runway rows

    private let rowsNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func rowLimit(
        _ id: String,
        kind: SnapshotLimit.Kind,
        window: TimeInterval? = 5 * 3_600,
        isEstimated: Bool = false
    ) -> SnapshotLimit {
        SnapshotLimit(
            id: id,
            kind: kind,
            title: id,
            usageLimit: UsageLimit(
                used: 30,
                total: 100,
                resetTime: rowsNow.addingTimeInterval(3_600),
                windowSeconds: window,
                isEstimated: isEstimated
            )
        )
    }

    /// The hover shows charts, one per window. The popover card keeps the bars.
    func testSessionAndWeeklyRenderAsRunwaysInTheirOwnOrder() {
        let rows = MenuBarProviderDetailContent.rows(
            for: [rowLimit("session", kind: .session), rowLimit("weekly", kind: .weekly, window: 604_800)],
            now: rowsNow
        )

        XCTAssertEqual(rows.map(\.limit.id), ["session", "weekly"])
        XCTAssertEqual(rows.map(\.isRunway), [true, true])
    }

    func testWindowsThatCannotBeChartedFallBackToTheirBar() {
        let rows = MenuBarProviderDetailContent.rows(
            for: [
                rowLimit("session", kind: .session),
                rowLimit("model", kind: .additional),
                rowLimit("estimated", kind: .weekly, window: 604_800, isEstimated: true),
                rowLimit("no-window", kind: .weekly, window: nil)
            ],
            now: rowsNow
        )

        XCTAssertEqual(rows.map(\.isRunway), [true, false, false, false])
    }

    func testLegendAppearsOnlyWhenARunwayIsShown() {
        let charted = MenuBarProviderDetailContent.rows(for: [rowLimit("session", kind: .session)], now: rowsNow)
        let barsOnly = MenuBarProviderDetailContent.rows(for: [rowLimit("model", kind: .additional)], now: rowsNow)

        XCTAssertTrue(MenuBarProviderDetailContent.showsRunwayLegend(for: charted))
        XCTAssertFalse(MenuBarProviderDetailContent.showsRunwayLegend(for: barsOnly))
        XCTAssertFalse(MenuBarProviderDetailContent.showsRunwayLegend(for: []))
    }
}
