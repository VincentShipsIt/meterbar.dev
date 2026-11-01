import AppKit
import Foundation
import SwiftUI
@testable import MeterBar
import MeterBarShared
import XCTest

/// The Tiles popover: what each tile says, which provider leads, the control
/// tiles that replaced the footer pills, floating tiles and the Tiles widget.
final class PopoverTilesTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func snapshot(
        title: String,
        service: ServiceType,
        weeklyUsed: Double? = nil,
        sessionUsed: Double? = nil,
        weeklyResetIn: TimeInterval? = nil,
        hasMetrics: Bool = true,
        authNotice: ProviderAuthNotice? = nil
    ) -> ProviderSnapshot {
        let metrics = hasMetrics
            ? UsageMetrics(
                service: service,
                sessionLimit: sessionUsed.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
                weeklyLimit: weeklyUsed.map {
                    UsageLimit(used: $0, total: 100, resetTime: weeklyResetIn.map { now.addingTimeInterval($0) })
                },
                lastUpdated: now
            )
            : nil
        return ProviderSnapshotBuilder.snapshot(
            title: title,
            service: service,
            metrics: metrics,
            emptyDetail: "No data",
            authNotice: authNotice
        )
    }

    // MARK: - Tile content

    func testMeasuredTileSpellsOutLeftAndUsed() {
        let content = PopoverTileContent(
            snapshot: snapshot(title: "Grok", service: .xai, weeklyUsed: 48),
            now: now
        )

        XCTAssertEqual(content.percentLeft, 52)
        XCTAssertEqual(content.headline, "52% left", "a tile never shows a bare percentage")
        XCTAssertEqual(content.usedText, "48% used")
        XCTAssertEqual(content.figure?.number, "52")
        XCTAssertEqual(content.figure?.unit, "% left")
        XCTAssertEqual(content.fractionLeft ?? -1, 0.52, accuracy: 0.0001)
        XCTAssertEqual(content.tone, .healthy)
    }

    func testOtherWindowsAreLabelledAsLeft() {
        let content = PopoverTileContent(
            snapshot: snapshot(title: "Claude", service: .claudeCode, weeklyUsed: 48, sessionUsed: 19),
            now: now
        )

        XCTAssertEqual(content.percentLeft, 52, "the weekly window is the tighter one")
        XCTAssertEqual(content.otherWindows.map(\.valueText), ["81% left"])
    }

    func testTileWithoutMetricsShowsAStatusWordInsteadOfANumber() {
        let content = PopoverTileContent(
            snapshot: snapshot(title: "Codex", service: .codexCli, hasMetrics: false),
            now: now
        )

        XCTAssertNil(content.percentLeft)
        XCTAssertNil(content.figure)
        XCTAssertNil(content.usedText)
        XCTAssertEqual(content.tone, .neutral)
        XCTAssertFalse(content.headline.isEmpty)
    }

    func testAuthNoticeOutranksTheCachedPercentage() {
        let content = PopoverTileContent(
            snapshot: snapshot(title: "Codex", service: .codexCli, weeklyUsed: 10, authNotice: .loginRequired),
            now: now
        )

        XCTAssertNil(content.percentLeft, "a logged-out tile must not lead with a stale healthy number")
        XCTAssertEqual(content.tone, .neutral)
    }

    func testWindowWithAResetButNoCadenceSaysWhenItResets() {
        let content = PopoverTileContent(
            snapshot: snapshot(title: "Grok", service: .xai, weeklyUsed: 20, weeklyResetIn: 2 * 3_600 + 600),
            now: now
        )

        XCTAssertEqual(content.outlook, "Resets in 2h 10m")
        XCTAssertFalse(content.outlookIsShortfall)
    }

    // MARK: - Layout

    func testTightestMeasuredProviderTakesTheHeroTile() {
        let codex = snapshot(title: "Codex", service: .codexCli, weeklyUsed: 36)
        let claude = snapshot(title: "Claude", service: .claudeCode, weeklyUsed: 48)
        let grok = snapshot(title: "Grok", service: .xai, weeklyUsed: 10)

        let plan = PopoverTileLayout.plan(for: [codex, claude, grok], now: now)

        XCTAssertEqual(plan.heroID, claude.id)
        XCTAssertEqual(plan.gridIDs, [codex.id, grok.id], "the grid keeps display order")
    }

    func testProviderWithoutAReadingNeverTakesTheHero() {
        let offline = snapshot(title: "Codex", service: .codexCli, hasMetrics: false)
        let grok = snapshot(title: "Grok", service: .xai, weeklyUsed: 10)

        XCTAssertEqual(PopoverTileLayout.plan(for: [offline, grok], now: now).heroID, grok.id)
        XCTAssertNil(PopoverTileLayout.plan(for: [offline], now: now).heroID)
        XCTAssertEqual(PopoverTileLayout.plan(for: [offline], now: now).gridIDs, [offline.id])
    }

    func testHeroTieKeepsDisplayOrder() {
        let first = snapshot(title: "Codex", service: .codexCli, weeklyUsed: 50)
        let second = snapshot(title: "Grok", service: .xai, weeklyUsed: 50)

        XCTAssertEqual(PopoverTileLayout.plan(for: [first, second], now: now).heroID, first.id)
    }

    func testGridPairsTilesIntoRowsOfTwo() {
        let tiles = (0..<5).map { snapshot(title: "P\($0)", service: .xai, weeklyUsed: 10) }

        XCTAssertEqual(PopoverOverviewPanel.gridRows(tiles).map(\.count), [2, 2, 1])
        XCTAssertTrue(PopoverOverviewPanel.gridRows([]).isEmpty)
    }

    func testOnlyABlockedAccountWithABankedResetKeepsTheFullCard() {
        let healthy = snapshot(title: "Codex", service: .codexCli, weeklyUsed: 10)
        XCTAssertFalse(PopoverOverviewPanel.keepsFullCard(healthy))

        let blocked = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: UsageMetrics(
                service: .codexCli,
                weeklyLimit: UsageLimit(used: 100, total: 100, resetTime: now.addingTimeInterval(3_600)),
                resetCreditsAvailable: 1,
                lastUpdated: now
            ),
            emptyDetail: "No data"
        )
        XCTAssertTrue(PopoverOverviewPanel.keepsFullCard(blocked))
    }

    func testCurrencyLimitShowsTheRemainingAmount() {
        let content = PopoverTileContent(
            snapshot: ProviderSnapshotBuilder.snapshot(
                title: "OpenRouter",
                service: .openRouter,
                metrics: UsageMetrics(
                    service: .openRouter,
                    weeklyLimit: UsageLimit(used: 5.9, total: 10, resetTime: nil),
                    lastUpdated: now
                ),
                emptyDetail: "No data"
            ),
            now: now
        )

        XCTAssertEqual(content.headline, LocalizedUsageFormat.amountLeft(UsageFormat.cost(4.1)))
        XCTAssertNil(content.percentLeft, "a balance is not drawn as a percentage ring")
    }

    // MARK: - Rendering

    func testEveryTileStyleLaysOut() {
        let tile = snapshot(title: "Claude", service: .claudeCode, weeklyUsed: 48, sessionUsed: 19)
        for (style, width) in [(ProviderTile.Style.hero, 366.0), (.compact, 180.0), (.floating, 232.0)] {
            let host = NSHostingView(rootView: ProviderTile(snapshot: tile, style: style).frame(width: width))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0, "\(style) tile")
        }
    }

    func testStatusOnlyTileLaysOut() {
        let tile = snapshot(title: "Codex", service: .codexCli, hasMetrics: false)
        let host = NSHostingView(rootView: ProviderTile(snapshot: tile, style: .compact).frame(width: 180))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, ProviderTile.compactMinHeight)
    }

    func testFooterLineLaysOut() {
        let footer = PopoverFooterLine(updatedAt: now, isRefreshing: false, refresh: {}, openDashboard: {})
        let host = NSHostingView(rootView: footer.frame(width: 366))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertLessThanOrEqual(host.fittingSize.height, MenuBarPopoverGeometry.chromeHeight)
    }

    // MARK: - Tile copy

    func testCompactTitleAddsThePlanWhenKnown() {
        var tile = snapshot(title: "Codex", service: .codexCli, weeklyUsed: 10)
        XCTAssertEqual(ProviderTile.compactTitle(for: PopoverTileContent(snapshot: tile, now: now)), "Codex")

        tile.planLabel = "Pro"
        XCTAssertEqual(ProviderTile.compactTitle(for: PopoverTileContent(snapshot: tile, now: now)), "Codex · Pro")
    }

    func testAccessibilityValueReadsBothDirections() {
        let content = PopoverTileContent(snapshot: snapshot(title: "Grok", service: .xai, weeklyUsed: 48), now: now)
        let value = ProviderTile.accessibilityValue(for: content)

        XCTAssertTrue(value.contains("52% left"))
        XCTAssertTrue(value.contains("48% used"))
    }

    // MARK: - Control tiles

    func testStayAwakeTileCopy() {
        XCTAssertEqual(StayAwakeTileCopy.detail(isEnabled: false, isHeld: false, provider: nil), "Off")
        XCTAssertEqual(StayAwakeTileCopy.detail(isEnabled: true, isHeld: false, provider: nil), "On · waiting for quota")
        XCTAssertEqual(StayAwakeTileCopy.detail(isEnabled: true, isHeld: true, provider: "Claude"), "Awake · Claude")
    }

    private func report(_ service: ServiceType, indicator: ProviderStatusIndicator) -> ProviderStatusReport {
        ProviderStatusReport(
            service: service,
            pageName: service.statusPageDisplayName,
            pageURL: URL(string: "https://status.example.com")!,
            summary: ProviderStatusSummary(indicator: indicator, description: nil, updatedAt: nil),
            components: [],
            fetchedAt: now
        )
    }

    func testStatusTileSummary() {
        XCTAssertEqual(ProviderStatusTileSummary(reports: []).text, "Checking…")

        let healthy = ProviderStatusTileSummary(reports: [report(.claudeCode, indicator: .none)])
        XCTAssertEqual(healthy.text, "All operational")
        XCTAssertEqual(healthy.issueCount, 0)

        let degraded = ProviderStatusTileSummary(reports: [
            report(.claudeCode, indicator: .none),
            report(.codexCli, indicator: .minor),
        ])
        XCTAssertEqual(degraded.issueCount, 1)
        XCTAssertTrue(degraded.text.hasSuffix("degraded"))

        let several = ProviderStatusTileSummary(reports: [
            report(.claudeCode, indicator: .major),
            report(.codexCli, indicator: .minor),
        ])
        XCTAssertEqual(several.text, "2 issues")

        let partial = ProviderStatusTileSummary(
            reports: [report(.claudeCode, indicator: .none)],
            expectedCount: 3
        )
        XCTAssertEqual(partial.text, "1 of 3 checked", "a page that has not answered is not reported healthy")
        XCTAssertEqual(
            ProviderStatusTileSummary(reports: [report(.claudeCode, indicator: .none)], expectedCount: 1).text,
            "All operational"
        )
    }

    func testStableKeySurvivesTitleChange() {
        let original = snapshot(title: "Codex · Work", service: .codexCli, weeklyUsed: 10)
        let renamed = snapshot(title: "Codex · Office", service: .codexCli, weeklyUsed: 10)
        XCTAssertNotEqual(original.id, renamed.id)
        XCTAssertEqual(original.stableKey, renamed.stableKey)
    }

    func testRestoredFrameMustBeOnAConnectedScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        XCTAssertTrue(FloatingTileController.isReachable(CGRect(x: 100, y: 100, width: 232, height: 76), on: [screen]))
        XCTAssertFalse(
            FloatingTileController.isReachable(CGRect(x: 3_000, y: 100, width: 232, height: 76), on: [screen]),
            "a frame saved on a disconnected display is not reachable"
        )
    }

    func testDesktopWidgetGuideDoesNotOverpromise() {
        XCTAssertFalse(DesktopWidgetGuide.informativeText.contains("every provider"))
    }

    func testFooterFreshnessText() {
        XCTAssertEqual(PopoverFooterLine.freshnessText(updatedAt: nil, isRefreshing: false, now: now), "Not updated yet")
        XCTAssertEqual(PopoverFooterLine.freshnessText(updatedAt: now, isRefreshing: true, now: now), "Refreshing…")
        XCTAssertTrue(
            PopoverFooterLine.freshnessText(updatedAt: now.addingTimeInterval(-120), isRefreshing: false, now: now)
                .hasPrefix("Updated ")
        )
    }

    // MARK: - Right-click commands

    func testTilePlacementsLeadTheContextMenu() {
        var floated: [String] = []
        var desktopRequests = 0
        let tile = snapshot(title: "Codex", service: .codexCli, weeklyUsed: 10)
        let commands = ProviderCardCommands.make(
            snapshot: tile,
            refresh: { _ in },
            openStatusPage: { _ in },
            hide: { _ in },
            openInDashboard: {},
            addToDesktop: { desktopRequests += 1 },
            floatOnScreen: { floated.append($0) }
        )

        XCTAssertEqual(
            commands.map(\.id),
            [.addToDesktop, .floatOnScreen, .refresh, .openStatusPage, .openInDashboard, .hide]
        )
        commands.first { $0.id == .addToDesktop }?.action()
        commands.first { $0.id == .floatOnScreen }?.action()
        XCTAssertEqual(desktopRequests, 1)
        XCTAssertEqual(floated, [tile.stableKey], "the floated tile is the one that was right-clicked")
    }

    // MARK: - Floating tiles

    private func makeDefaults() -> UserDefaults {
        let suite = "PopoverTilesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRegistryAddsOnceRemovesAndPersists() {
        let defaults = makeDefaults()
        let registry = FloatingTileRegistry(userDefaults: defaults)

        XCTAssertTrue(registry.add("a"))
        XCTAssertFalse(registry.add("a"), "a tile floats once")
        XCTAssertTrue(registry.add("b"))
        XCTAssertEqual(FloatingTileRegistry(userDefaults: defaults).ids, ["a", "b"], "survives a relaunch")

        registry.remove("a")
        XCTAssertEqual(registry.ids, ["b"])
    }

    func testRegistryCapsTheNumberOfFloatingTiles() {
        let registry = FloatingTileRegistry(userDefaults: makeDefaults())
        for index in 0..<FloatingTileRegistry.maximumCount {
            XCTAssertTrue(registry.add("tile-\(index)"))
        }
        XCTAssertFalse(registry.add("one-too-many"))
        XCTAssertEqual(registry.ids.count, FloatingTileRegistry.maximumCount)
    }

    func testNewFloatingTilesStackDownTheTopRightCorner() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = CGSize(width: 232, height: 76)
        let first = FloatingTileRegistry.defaultOrigin(index: 0, tileSize: size, visibleFrame: screen)
        let second = FloatingTileRegistry.defaultOrigin(index: 1, tileSize: size, visibleFrame: screen)

        XCTAssertEqual(first.x, 1_440 - 232 - 16)
        XCTAssertEqual(first.y, 900 - 16 - 76)
        XCTAssertEqual(second.x, first.x)
        XCTAssertEqual(first.y - second.y, 76 + 10)
    }

    // MARK: - Hover window tiles

    private func limit(_ id: String, kind: SnapshotLimit.Kind, used: Double = 30) -> SnapshotLimit {
        SnapshotLimit(
            id: id,
            kind: kind,
            title: id,
            usageLimit: UsageLimit(used: used, total: 100, resetTime: now.addingTimeInterval(3_600))
        )
    }

    func testHoverOpensWithWindowTilesWhenAsked() {
        let limits = [limit("session", kind: .session), limit("weekly", kind: .weekly)]
        let cards = MenuBarProviderDetailContent.cards(
            limits: limits,
            hasExhaustedLimit: false,
            hasBadges: false,
            showsDailyUsage: false,
            showsWindowTiles: true,
            now: now
        )

        XCTAssertEqual(cards.first, .windowTiles)
    }

    func testIssuesStillLeadAboveTheWindowTiles() {
        let cards = MenuBarProviderDetailContent.cards(
            limits: [limit("session", kind: .session)],
            hasExhaustedLimit: false,
            hasBadges: false,
            showsDailyUsage: false,
            hasIssues: true,
            showsWindowTiles: true,
            now: now
        )

        XCTAssertEqual(Array(cards.prefix(2)), [.issues, .windowTiles])
    }

    func testBlockedHoverSkipsTheWindowTiles() {
        let cards = MenuBarProviderDetailContent.cards(
            limits: [limit("weekly", kind: .weekly, used: 100)],
            hasExhaustedLimit: true,
            hasBadges: false,
            showsDailyUsage: false,
            showsWindowTiles: true,
            now: now
        )

        XCTAssertFalse(cards.contains(.windowTiles), "a blocked provider leads with its reset, not its windows")
    }

    func testWindowTilesWrapAtThreeAcross() {
        let limits = (0..<4).map { limit("w\($0)", kind: .additional) }
        XCTAssertEqual(HoverWindowTiles.rows(limits).map(\.count), [3, 1])
    }

    func testWindowTileFigureSaysLeft() {
        XCTAssertEqual(HoverWindowTiles.figureText(for: limit("session", kind: .session, used: 19)), "81% left")
        XCTAssertEqual(
            HoverWindowTiles.detailLine(for: limit("model", kind: .additional), now: now)?.text,
            "Resets in 1h"
        )
    }

    // MARK: - Tiles widget

    func testTilesWidgetKindIsStableAndReloaded() {
        XCTAssertEqual(MeterBarWidgetKind.tiles, "TilesWidget")
        XCTAssertTrue(MeterBarWidgetKind.all.contains(MeterBarWidgetKind.tiles))
        XCTAssertEqual(Set(MeterBarWidgetKind.all).count, MeterBarWidgetKind.all.count)
    }

    func testTilesWidgetPutsTheTightestRowFirst() {
        let presentation = WidgetPresentationPlanner.makePresentation(
            metrics: [
                .codexCli: UsageMetrics(
                    service: .codexCli,
                    weeklyLimit: UsageLimit(used: 30, total: 100, resetTime: nil),
                    lastUpdated: now
                ),
                .claudeCode: UsageMetrics(
                    service: .claudeCode,
                    weeklyLimit: UsageLimit(used: 90, total: 100, resetTime: nil),
                    lastUpdated: now
                ),
                .xai: UsageMetrics(
                    service: .xai,
                    weeklyLimit: UsageLimit(used: 47, total: 100, resetTime: nil),
                    lastUpdated: now
                ),
            ],
            accountMetrics: [],
            preferences: .defaults,
            family: .medium,
            now: now
        )
        let ordered = WidgetTileOrdering.tightestFirst(presentation.rows)

        XCTAssertEqual(ordered.first?.service, .claudeCode)
        let percents = ordered.compactMap { $0.limit.map { QuotaMath.percentLeft(for: $0) } }
        XCTAssertEqual(percents, percents.sorted())
    }

    func testTightestProviderSurvivesTheRowBudgetEvenWhenFourth() {
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: UsageMetrics(
                service: .claudeCode,
                weeklyLimit: UsageLimit(used: 10, total: 100, resetTime: nil),
                lastUpdated: now
            ),
            .codexCli: UsageMetrics(
                service: .codexCli,
                weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
                lastUpdated: now
            ),
            .xai: UsageMetrics(
                service: .xai,
                weeklyLimit: UsageLimit(used: 30, total: 100, resetTime: nil),
                lastUpdated: now
            ),
            .kimiCode: UsageMetrics(
                service: .kimiCode,
                weeklyLimit: UsageLimit(used: 95, total: 100, resetTime: nil),
                lastUpdated: now
            ),
        ]
        let presentation = WidgetPresentationPlanner.makePresentation(
            metrics: metrics,
            accountMetrics: [],
            preferences: .defaults,
            family: .medium,
            now: now,
            rowOrdering: WidgetTileOrdering.tightestFirst
        )

        XCTAssertEqual(presentation.rows.first?.service, .kimiCode, "ranked before the budget cuts rows")
    }

    func testRankingUsesExactHeadroomNotTheRoundedPercent() {
        let tighter = UsageLimit(used: 98.9, total: 100, resetTime: nil)
        let looser = UsageLimit(used: 98.6, total: 100, resetTime: nil)
        XCTAssertEqual(QuotaMath.percentLeft(for: tighter), QuotaMath.percentLeft(for: looser), "rounded values tie")
        XCTAssertLessThan(100 - tighter.percentage, 100 - looser.percentage)
    }
}
