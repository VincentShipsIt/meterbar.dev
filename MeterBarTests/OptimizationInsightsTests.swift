import XCTest
import MeterBarShared
@testable import MeterBar

/// Coverage for the model-cost tiers and the recommendation rules (#72, #593).
///
/// The rules are pure and local-only: they consume token totals, model names
/// and derived stats only. The figures they read are cut per reporting window
/// by `UsageReport` and asserted in `UsageReportTests`; these tests pin the
/// tiering, the thresholds and the copy without any network or on-disk state.
final class OptimizationInsightsTests: XCTestCase {
    // MARK: - Model tier classification

    func testClassifyPremiumModels() {
        XCTAssertEqual(ModelTier.classify("claude-opus-4-8"), .premium)
        XCTAssertEqual(ModelTier.classify("claude-fable-5"), .premium)
        XCTAssertEqual(ModelTier.classify("gpt-5"), .premium)
        XCTAssertEqual(ModelTier.classify("gpt-6-astra"), .premium)
        XCTAssertEqual(ModelTier.classify("o3"), .premium)
        // Bedrock/date-suffixed variants still classify by family substring.
        XCTAssertEqual(ModelTier.classify("us.anthropic.claude-opus-4-8-20260101"), .premium)
    }

    func testClassifyStandardModels() {
        XCTAssertEqual(ModelTier.classify("claude-sonnet-4-5"), .standard)
        XCTAssertEqual(ModelTier.classify("codex"), .standard)
        XCTAssertEqual(ModelTier.classify("gpt-4o"), .standard)
        XCTAssertEqual(ModelTier.classify("grok-4.6-build"), .standard)
    }

    func testClassifyEconomyModels() {
        XCTAssertEqual(ModelTier.classify("claude-haiku-4-5"), .economy)
        // Economy markers win over the premium family (a mini variant is cheap).
        XCTAssertEqual(ModelTier.classify("gpt-5-mini"), .economy)
        XCTAssertEqual(ModelTier.classify("o4-mini"), .economy)
    }

    func testClassifyUnknownModels() {
        XCTAssertEqual(ModelTier.classify(""), .unknown)
        XCTAssertEqual(ModelTier.classify("Unknown model"), .unknown)
        XCTAssertEqual(ModelTier.classify("some-random-thing"), .unknown)
    }

    func testPremiumTierFlag() {
        XCTAssertTrue(ModelTier.premium.isPremium)
        XCTAssertFalse(ModelTier.standard.isPremium)
        XCTAssertFalse(ModelTier.economy.isPremium)
        XCTAssertFalse(ModelTier.unknown.isPremium)
    }

    func testModelCostTierIndicatorsUseNeutralRelativePriceScale() {
        XCTAssertEqual(ModelTier.economy.costIndicator, "$")
        XCTAssertEqual(ModelTier.standard.costIndicator, "$$")
        XCTAssertEqual(ModelTier.premium.costIndicator, "$$$")
        XCTAssertEqual(ModelTier.unknown.costIndicator, "—")

        XCTAssertEqual(ModelTier.economy.costAccessibilityLabel, "Low-cost model")
        XCTAssertEqual(ModelTier.standard.costAccessibilityLabel, "Mid-cost model")
        XCTAssertEqual(ModelTier.premium.costAccessibilityLabel, "High-cost model")
        XCTAssertEqual(ModelTier.unknown.costAccessibilityLabel, "Unknown cost tier")
    }

    func testHighCostDashboardMetricPreservesMarkerAndExposesSemanticLabel() {
        let tile = DashboardMetricTile(
            title: "$$$ model share",
            value: "68%",
            caption: "tokens routed to high-cost models",
            systemImage: "bolt.fill",
            accessibilityTitle: ModelTier.premium.costAccessibilityLabel
        )

        XCTAssertEqual(tile.title, "$$$ model share")
        XCTAssertEqual(tile.accessibilityLabelText, "High-cost model")
    }

    func testRecommendationRowsPreserveMarkersAndExposeEverySemanticCostTier() {
        let expectations: [(tier: ModelTier, marker: String, semanticLabel: String)] = [
            (.premium, "$$$", "High-cost model"),
            (.standard, "$$", "Mid-cost model"),
            (.economy, "$", "Low-cost model"),
        ]

        for expectation in expectations {
            let recommendation = OptimizationRecommendation(
                id: expectation.tier.rawValue,
                title: "Route routine work carefully",
                detail: "\(expectation.marker) models handled this work.",
                severity: .suggestion,
                systemImage: "bolt.badge.automatic"
            )
            let row = UsageInsightRow(recommendation: recommendation)

            XCTAssertTrue(recommendation.detail.contains(expectation.marker))
            XCTAssertTrue(
                row.accessibilityValueText.contains(expectation.semanticLabel),
                "\(expectation.tier) recommendation must announce its semantic cost tier"
            )
            XCTAssertFalse(row.accessibilityValueText.contains(expectation.marker))
        }
    }

    // MARK: - Recommendation rules

    private typealias Inputs = OptimizationInsights.Inputs

    private func recommendation(
        _ id: String,
        in inputs: Inputs
    ) -> OptimizationRecommendation? {
        OptimizationInsights(inputs: inputs).recommendations.first { $0.id == id }
    }

    func testHighPremiumShareProducesWarningWithItsSource() {
        // 90% premium tokens -> a premium-routing warning must appear.
        let inputs = Inputs(premiumTokens: 9_000_000, attributedModelTokens: 10_000_000)

        let premium = recommendation("premium-share", in: inputs)

        XCTAssertEqual(premium?.severity, .warning)
        XCTAssertEqual(premium?.title, "High-cost models are doing most of the work")
        XCTAssertEqual(premium?.detail.contains("$$$ models"), true)
        XCTAssertEqual(premium?.source, "90% · 9.0M of 10.0M tokens")
    }

    func testModeratePremiumShareProducesASuggestion() {
        let premium = recommendation("premium-share", in: Inputs(premiumTokens: 35, attributedModelTokens: 100))

        XCTAssertEqual(premium?.severity, .suggestion)
    }

    func testNoPremiumInsightBelowTheThresholdOrWithoutAttribution() {
        XCTAssertNil(recommendation("premium-share", in: Inputs(premiumTokens: 20, attributedModelTokens: 100)))
        XCTAssertNil(recommendation("premium-share", in: Inputs()))
        XCTAssertNil(OptimizationInsights(inputs: Inputs()).premiumTokenShare)
        XCTAssertEqual(OptimizationInsights(inputs: Inputs()).formattedPremiumShare, "—")
    }

    func testLowCacheReuseProducesWarning() {
        let inputs = Inputs(cacheUse: .init(readTokens: 1_000_000, writeTokens: 9_000_000))

        let cache = recommendation("cache-reuse", in: inputs)

        XCTAssertEqual(cache?.severity, .warning)
        XCTAssertEqual(cache?.source, "1.0M read · 9.0M written")
    }

    func testHealthyCacheReuseIsPositive() {
        let inputs = Inputs(cacheUse: .init(readTokens: 9_000_000, writeTokens: 1_000_000))

        XCTAssertEqual(recommendation("cache-reuse", in: inputs)?.severity, .positive)
    }

    func testMissingCacheUseProducesNoCacheInsight() {
        XCTAssertNil(recommendation("cache-reuse", in: Inputs()))
        XCTAssertNil(OptimizationInsights(inputs: Inputs()).cacheReuseRatio)
    }

    func testInputDwarfingOutputIsFlaggedOnlyPastTheThreshold() {
        let heavy = recommendation("input-output-ratio", in: Inputs(inputTokens: 25_000, outputTokens: 1_000))
        XCTAssertEqual(heavy?.severity, .suggestion)
        XCTAssertEqual(heavy?.source, "25.0K input · 1.0K output")

        XCTAssertNil(recommendation("input-output-ratio", in: Inputs(inputTokens: 8_000, outputTokens: 1_000)))
        XCTAssertNil(recommendation("input-output-ratio", in: Inputs(inputTokens: 8_000, outputTokens: 0)))
    }

    func testOriginConcentrationNeedsHalfTheTokens() {
        let concentrated = Inputs(topOrigin: .init(name: "Agents", tokens: 700, groupTokens: 1_000))
        XCTAssertEqual(recommendation("origin-concentration", in: concentrated)?.title, "Agents is your biggest token driver")

        let spread = Inputs(topOrigin: .init(name: "Agents", tokens: 400, groupTokens: 1_000))
        XCTAssertNil(recommendation("origin-concentration", in: spread))
    }

    func testTrendNeedsTheRecentRateToRunTwentyPercentAboveTheWindow() {
        let hot = Inputs(trend: .init(recentDailyTokens: 130, windowDailyTokens: 100, recentDays: 7))
        XCTAssertNotNil(recommendation("trend-up", in: hot))

        let steady = Inputs(trend: .init(recentDailyTokens: 110, windowDailyTokens: 100, recentDays: 7))
        XCTAssertNil(recommendation("trend-up", in: steady))
    }

    func testLeanFallbackAppearsWhenNothingIsFlaggedAndHasNoSource() {
        let insights = OptimizationInsights(inputs: Inputs(
            premiumTokens: 0,
            attributedModelTokens: 100,
            cacheUse: .init(readTokens: 50, writeTokens: 50)
        ))

        XCTAssertEqual(insights.recommendations.map(\.id), ["lean"])
        XCTAssertNil(insights.recommendations.first?.source)
    }

    func testNoRecommendationsWithoutData() {
        XCTAssertTrue(OptimizationInsights(inputs: Inputs(), hasData: false).recommendations.isEmpty)
    }

    func testRecommendationsAreSortedBySeverityDescending() {
        let insights = OptimizationInsights(inputs: Inputs(
            premiumTokens: 90,
            attributedModelTokens: 100,
            inputTokens: 30_000,
            outputTokens: 1_000,
            cacheUse: .init(readTokens: 900, writeTokens: 100)
        ))

        let severities = insights.recommendations.map(\.severity.rawValue)
        XCTAssertEqual(severities, severities.sorted(by: >))
        XCTAssertGreaterThan(insights.recommendations.count, 1)
    }

    func testFormattedRatios() {
        let insights = OptimizationInsights(inputs: Inputs(
            inputTokens: 6_000,
            outputTokens: 1_500,
            cacheUse: .init(readTokens: 8, writeTokens: 2)
        ))

        XCTAssertEqual(insights.formattedInputOutputRatio, "4.0 : 1")
        XCTAssertEqual(insights.formattedCacheReuse, "80%")
    }
}
