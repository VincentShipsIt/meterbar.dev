import XCTest
import MeterBarShared
@testable import MeterBar

final class SocialCardRendererTests: XCTestCase {
    func testContentAggregatesSessionsAndUsesCostProviders() {
        let generatedAt = Date(timeIntervalSince1970: 10_000)
        let codexCost = makeCost(
            provider: .codexCli,
            inputTokens: 100,
            outputTokens: 50,
            sessionCount: 3
        )
        let claudeCost = makeCost(
            provider: .claudeCode,
            inputTokens: 400,
            outputTokens: 200,
            sessionCount: 7
        )
        let costs = [codexCost, claudeCost]
        let summary = CostSummary(
            costs: costs,
            totalCostUSD: 1.5,
            totalTokens: costs.reduce(0) { $0 + $1.totalTokens },
            periodDays: 30
        )

        let content = SocialCardRenderer.content(
            costSummary: summary,
            providerSnapshotTitles: ["Snapshot"],
            enabledSourceLabels: ["Enabled"],
            generatedAt: generatedAt
        )

        XCTAssertEqual(content.sessionCount, 10)
        XCTAssertEqual(content.topProviderName, ServiceType.claudeCode.displayName)
        XCTAssertEqual(content.providerNames, costs.map(\.provider.displayName))
    }

    func testContentWithoutSummaryUsesEnabledSourceLabels() {
        let content = SocialCardRenderer.content(
            costSummary: nil,
            providerSnapshotTitles: [],
            enabledSourceLabels: ["Codex logs", "Claude JSONL"],
            generatedAt: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertNil(content.tokenTotal)
        XCTAssertNil(content.sessionCount)
        XCTAssertEqual(content.providerNames, ["Codex logs", "Claude JSONL"])
        XCTAssertEqual(content.dailyTokenTotals, [])
    }

    func testContentWithEmptyCostsUsesProviderSnapshotTitles() {
        let summary = CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: 30
        )

        let content = SocialCardRenderer.content(
            costSummary: summary,
            providerSnapshotTitles: ["Codex", "Claude"],
            enabledSourceLabels: ["Enabled"],
            generatedAt: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(content.providerNames, ["Codex", "Claude"])
    }

    func testContentBuildsDailyTokenTotalsFromSummary() {
        let generatedAt = Date(timeIntervalSince1970: 86400 * 10)
        let dailyUsage = [
            DailyTokenUsage(
                date: generatedAt.addingTimeInterval(-86400),
                provider: .codexCli,
                inputTokens: 100,
                outputTokens: 50,
                cacheReadTokens: 25,
                estimatedCostUSD: 0.1
            ),
            DailyTokenUsage(
                date: generatedAt,
                provider: .claudeCode,
                inputTokens: 200,
                outputTokens: 75,
                cacheReadTokens: 10,
                estimatedCostUSD: 0.2
            ),
        ]
        let summary = CostSummary(
            costs: [],
            totalCostUSD: 0.3,
            totalTokens: dailyUsage.reduce(0) { $0 + $1.totalTokens },
            periodDays: 30,
            dailyUsage: dailyUsage
        )

        let content = SocialCardRenderer.content(
            costSummary: summary,
            providerSnapshotTitles: [],
            enabledSourceLabels: [],
            generatedAt: generatedAt
        )

        XCTAssertEqual(
            content.dailyTokenTotals,
            SocialShareCardContent.dailyTokenTotals(from: summary.dailyUsage, now: generatedAt)
        )
    }

    /// The card's model rows answer for the same 30-day window its hero number
    /// does, so they come from the summary's provider rollups rather than from
    /// the chart week beside them.
    func testContentTakesModelRowsFromTheThirtyDayRollup() {
        var claudeCost = makeCost(
            provider: .claudeCode,
            inputTokens: 900,
            outputTokens: 100,
            sessionCount: 4
        )
        claudeCost.modelBreakdowns = [
            makeBreakdown(provider: .claudeCode, name: "claude-fable-5", tokens: 800),
            makeBreakdown(provider: .claudeCode, name: "claude-haiku-4-5", tokens: 200),
        ]
        let summary = CostSummary(
            costs: [claudeCost],
            totalCostUSD: 1,
            totalTokens: claudeCost.totalTokens,
            periodDays: 30
        )

        let content = SocialCardRenderer.content(
            costSummary: summary,
            providerSnapshotTitles: [],
            enabledSourceLabels: [],
            generatedAt: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(content.modelSlices.map(\.name), ["claude-fable-5", "claude-haiku-4-5"])
        XCTAssertEqual(content.modelSlices.map(\.providerRank), [0, 1])
        XCTAssertEqual(content.largestModelTokens, 800)
    }

    /// A cache written before model attribution has no model rows, and the card
    /// must come back without them rather than refusing to render.
    func testContentWithoutModelAttributionStillRenders() {
        let summary = CostSummary(
            costs: [makeCost(provider: .grok, inputTokens: 10, outputTokens: 5, sessionCount: 1)],
            totalCostUSD: 1,
            totalTokens: 15,
            periodDays: 30
        )

        let content = SocialCardRenderer.content(
            costSummary: summary,
            providerSnapshotTitles: [],
            enabledSourceLabels: [],
            generatedAt: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertFalse(content.hasModelBreakdown)
    }

    @MainActor
    func testImageAndPNGRendering() {
        let content = SocialShareCardContent(
            tokenTotal: 1_000_000,
            sessionCount: 10,
            providerNames: ["Codex", "Claude"],
            topProviderName: "Claude",
            dailyBurn: (0 ..< 30).map { _ in
                SocialShareDayBurn(slices: [
                    SocialShareProviderSlice(provider: .claudeCode, tokens: 70),
                    SocialShareProviderSlice(provider: .codexCli, tokens: 30),
                ])
            },
            modelSlices: [
                SocialShareModelSlice(
                    provider: .claudeCode,
                    name: "claude-fable-5",
                    tokens: 600_000,
                    providerRank: 0
                ),
                SocialShareModelSlice(
                    provider: .claudeCode,
                    name: "claude-haiku-4-5",
                    tokens: 250_000,
                    providerRank: 1
                ),
                SocialShareModelSlice(
                    provider: .codexCli,
                    name: "gpt-5.6-sol",
                    tokens: 150_000,
                    providerRank: 0
                ),
            ],
            generatedAt: Date(timeIntervalSince1970: 10_000)
        )

        guard let image = SocialCardRenderer.image(for: content) else {
            XCTFail("Expected share-card image")
            return
        }
        XCTAssertEqual(image.size, SocialShareCardLayout.exportSize)

        guard let pngData = SocialCardRenderer.pngData(for: content) else {
            XCTFail("Expected share-card PNG data")
            return
        }
        XCTAssertEqual(
            Array(pngData.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        )
    }

    @MainActor
    func testLimitsImageAndPNGRenderAtExportSize() {
        let now = Date(timeIntervalSince1970: 100_000)
        let snapshot = ProviderSnapshot(
            id: "claude",
            title: "Claude Code",
            service: .claudeCode,
            updatedAt: now,
            limits: [
                SnapshotLimit(
                    id: "session",
                    kind: .session,
                    title: "Session",
                    usageLimit: UsageLimit(
                        used: 81,
                        total: 100,
                        resetTime: now.addingTimeInterval(3_600),
                        windowSeconds: 18_000
                    )
                ),
                SnapshotLimit(
                    id: "weekly",
                    kind: .weekly,
                    title: "Weekly",
                    usageLimit: UsageLimit(
                        used: 47,
                        total: 100,
                        resetTime: now.addingTimeInterval(198_000),
                        windowSeconds: 604_800
                    )
                ),
            ],
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
        let content = SocialLimitsCardContent(snapshot: snapshot, now: now, generatedAt: now)

        guard let image = SocialCardRenderer.image(for: content) else {
            XCTFail("Expected limits-card image")
            return
        }
        XCTAssertEqual(image.size, SocialShareCardLayout.exportSize)

        guard let pngData = SocialCardRenderer.pngData(for: content) else {
            XCTFail("Expected limits-card PNG data")
            return
        }
        XCTAssertEqual(
            Array(pngData.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        )
    }

    @MainActor
    func testEmptyLimitsCardStillRenders() {
        let content = SocialLimitsCardContent(
            providerName: "Codex",
            updatedText: "No data",
            headline: nil,
            rows: [],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNotNil(SocialCardRenderer.pngData(for: content))
    }

    private func makeBreakdown(
        provider: ServiceType,
        name: String,
        tokens: Int
    ) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            provider: provider,
            name: name,
            inputTokens: tokens,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0.1,
            sessionCount: 1
        )
    }

    private func makeCost(
        provider: ServiceType,
        inputTokens: Int,
        outputTokens: Int,
        sessionCount: Int
    ) -> TokenCost {
        TokenCost(
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0.5,
            sessionCount: sessionCount,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 10_000)
        )
    }
}
