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

    @MainActor
    func testImageAndPNGRendering() {
        let content = SocialShareCardContent(
            tokenTotal: 1_000_000,
            sessionCount: 10,
            providerNames: ["Codex", "Claude"],
            topProviderName: "Claude",
            dailyTokenTotals: Array(repeating: 100, count: 30),
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
