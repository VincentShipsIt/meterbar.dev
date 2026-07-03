import XCTest
import MeterBarShared
@testable import MeterBar

/// TDD coverage for the token-optimization recommendation engine (#72).
///
/// The engine is a pure, local-only analytics layer over the cached
/// `CostSummary` — it consumes token totals, model names, and derived stats
/// only. These tests assert the math and the plain-English recommendation
/// thresholds without any network or on-disk state, mirroring the
/// `SocialShareCardContent` pattern.
final class OptimizationInsightsTests: XCTestCase {

    // MARK: - Model tier classification

    func testClassifyPremiumModels() {
        XCTAssertEqual(ModelTier.classify("claude-opus-4-8"), .premium)
        XCTAssertEqual(ModelTier.classify("claude-fable-5"), .premium)
        XCTAssertEqual(ModelTier.classify("gpt-5"), .premium)
        XCTAssertEqual(ModelTier.classify("o3"), .premium)
        // Bedrock/date-suffixed variants still classify by family substring.
        XCTAssertEqual(ModelTier.classify("us.anthropic.claude-opus-4-8-20260101"), .premium)
    }

    func testClassifyStandardModels() {
        XCTAssertEqual(ModelTier.classify("claude-sonnet-4-5"), .standard)
        XCTAssertEqual(ModelTier.classify("codex"), .standard)
        XCTAssertEqual(ModelTier.classify("gpt-4o"), .standard)
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

    // MARK: - Optimization score

    func testScoreBestCaseIsHundred() {
        let score = OptimizationInsights.computeScore(
            premiumShare: 0.0,
            inputOutputRatio: 4.0,
            cacheReuseRatio: 1.0,
            topOriginShare: 0.2
        )
        XCTAssertEqual(score, 100)
    }

    func testScoreWorstCaseIsZero() {
        let score = OptimizationInsights.computeScore(
            premiumShare: 1.0,
            inputOutputRatio: 40.0,
            cacheReuseRatio: 0.0,
            topOriginShare: 1.0
        )
        XCTAssertEqual(score, 0)
    }

    func testScoreIsClampedToRange() {
        let score = OptimizationInsights.computeScore(
            premiumShare: 2.0,          // out-of-range inputs are clamped
            inputOutputRatio: 500.0,
            cacheReuseRatio: -1.0,
            topOriginShare: 5.0
        )
        XCTAssertTrue((0...100).contains(score))
    }

    func testScoreFallsAsPremiumShareRises() {
        let lean = OptimizationInsights.computeScore(
            premiumShare: 0.1, inputOutputRatio: 8.0, cacheReuseRatio: 0.6, topOriginShare: 0.4
        )
        let heavy = OptimizationInsights.computeScore(
            premiumShare: 0.9, inputOutputRatio: 8.0, cacheReuseRatio: 0.6, topOriginShare: 0.4
        )
        XCTAssertGreaterThan(lean, heavy)
    }

    func testScoreFallsAsCacheReuseDrops() {
        let goodReuse = OptimizationInsights.computeScore(
            premiumShare: 0.3, inputOutputRatio: 8.0, cacheReuseRatio: 0.9, topOriginShare: 0.4
        )
        let poorReuse = OptimizationInsights.computeScore(
            premiumShare: 0.3, inputOutputRatio: 8.0, cacheReuseRatio: 0.1, topOriginShare: 0.4
        )
        XCTAssertGreaterThan(goodReuse, poorReuse)
    }

    func testScoreTreatsMissingSignalsAsNeutral() {
        // nil cache + nil ratio must not crash and must stay mid-range, not 0/100.
        let score = OptimizationInsights.computeScore(
            premiumShare: 0.5, inputOutputRatio: nil, cacheReuseRatio: nil, topOriginShare: 0.5
        )
        XCTAssertTrue((30...70).contains(score), "neutral score was \(score)")
    }

    // MARK: - Full pipeline from CostSummary

    func testInsightsFromPopulatedSummary() {
        let insights = OptimizationInsights(summary: Self.populatedSummary(), now: Self.referenceNow)

        XCTAssertTrue(insights.hasData)
        XCTAssertEqual(insights.totalTokens, Self.populatedSummary().totalTokens)

        // Ranked model breakdown: opus (biggest) ranks first, descending tokens.
        XCTAssertFalse(insights.topModels.isEmpty)
        XCTAssertEqual(insights.topModels.first?.name, "claude-opus-4-8")
        let modelTokens = insights.topModels.map(\.totalTokens)
        XCTAssertEqual(modelTokens, modelTokens.sorted(by: >))

        // Ranked origin breakdown exists and is descending.
        XCTAssertFalse(insights.topOrigins.isEmpty)
        XCTAssertEqual(insights.topOrigins.first?.name, "Agents")

        // Premium share = opus tokens / all model tokens.
        // opus 3,000,000 of (3,000,000 + 1,000,000 + 400,000) = 0.6818...
        XCTAssertEqual(insights.premiumTokenShare, 3_000_000.0 / 4_400_000.0, accuracy: 0.0001)
    }

    func testSevenAndThirtyDayWindows() {
        let insights = OptimizationInsights(summary: Self.populatedSummary(), now: Self.referenceNow)
        // Fixture places 100k tokens/day for 40 days. The 7-day window counts the
        // most recent 7 calendar days (today + 6 back); 30-day counts 30.
        XCTAssertEqual(insights.tokens7Day, 700_000)
        XCTAssertEqual(insights.tokens30Day, 3_000_000)
        XCTAssertGreaterThan(insights.tokens30Day, insights.tokens7Day)
    }

    func testCacheReuseRatioFromSummary() {
        let insights = OptimizationInsights(summary: Self.populatedSummary(), now: Self.referenceNow)
        // Aggregate cacheRead 8,000,000 / (cacheRead 8,000,000 + cacheCreation 2,000,000) = 0.8
        XCTAssertNotNil(insights.cacheReuseRatio)
        XCTAssertEqual(insights.cacheReuseRatio ?? 0, 0.8, accuracy: 0.0001)
    }

    func testInputOutputRatioFromSummary() {
        let insights = OptimizationInsights(summary: Self.populatedSummary(), now: Self.referenceNow)
        // input 6,000,000 / output 1,500,000 = 4.0
        XCTAssertNotNil(insights.inputOutputRatio)
        XCTAssertEqual(insights.inputOutputRatio ?? 0, 4.0, accuracy: 0.0001)
    }

    // MARK: - Recommendations

    func testHighPremiumShareProducesWarning() {
        // 90% premium tokens -> a premium-routing warning must appear.
        let summary = Self.summary(models: [
            Self.model(name: "claude-opus-4-8", provider: .claudeCode, total: 9_000_000),
            Self.model(name: "claude-haiku-4-5", provider: .claudeCode, total: 1_000_000)
        ])
        let insights = OptimizationInsights(summary: summary, now: Self.referenceNow)

        let premiumRec = insights.recommendations.first { $0.title.localizedCaseInsensitiveContains("premium") }
        XCTAssertNotNil(premiumRec)
        XCTAssertEqual(premiumRec?.severity, .warning)
    }

    func testLowCacheReuseProducesWarning() {
        let summary = Self.summary(models: [
            Self.model(
                name: "claude-sonnet-4-5",
                provider: .claudeCode,
                input: 1_000_000,
                output: 1_000_000,
                cacheCreation: 9_000_000,   // churning cache
                cacheRead: 1_000_000        // reuse ratio 0.1
            )
        ])
        let insights = OptimizationInsights(summary: summary, now: Self.referenceNow)

        let cacheRec = insights.recommendations.first { $0.title.localizedCaseInsensitiveContains("cache") }
        XCTAssertNotNil(cacheRec)
        XCTAssertEqual(cacheRec?.severity, .warning)
    }

    func testLeanUsageProducesPositiveNotWarning() {
        let summary = Self.summary(models: [
            Self.model(
                name: "claude-haiku-4-5",
                provider: .claudeCode,
                input: 1_000_000,
                output: 500_000,
                cacheCreation: 500_000,
                cacheRead: 4_500_000        // reuse ratio 0.9
            )
        ])
        let insights = OptimizationInsights(summary: summary, now: Self.referenceNow)

        XCTAssertFalse(insights.recommendations.isEmpty)
        XCTAssertFalse(
            insights.recommendations.contains { $0.severity == .warning },
            "lean usage should not raise warnings"
        )
    }

    func testRecommendationsSortedBySeverityDescending() {
        let insights = OptimizationInsights(summary: Self.populatedSummary(), now: Self.referenceNow)
        let severities = insights.recommendations.map(\.severity.rawValue)
        XCTAssertEqual(severities, severities.sorted(by: >))
    }

    // MARK: - Empty state

    func testEmptySummaryHasNoData() {
        let empty = CostSummary(costs: [], totalCostUSD: 0, totalTokens: 0, periodDays: 30, dailyUsage: [])
        let insights = OptimizationInsights(summary: empty, now: Self.referenceNow)

        XCTAssertFalse(insights.hasData)
        XCTAssertTrue(insights.topModels.isEmpty)
        XCTAssertTrue(insights.topOrigins.isEmpty)
        XCTAssertTrue(insights.recommendations.isEmpty)
    }

    // MARK: - Fixtures

    /// Fixed "now" so daily-window math is deterministic.
    private static let referenceNow: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 3
        components.hour = 12
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 1_783_080_000)
    }()

    private static func model(
        name: String,
        provider: ServiceType,
        input: Int = 0,
        output: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        total: Int? = nil,
        sessionCount: Int = 1
    ) -> TokenUsageBreakdown {
        // When `total` is supplied, stuff it into input so totalTokens matches
        // without callers specifying every bucket.
        let resolvedInput = total ?? input
        return TokenUsageBreakdown(
            provider: provider,
            name: name,
            inputTokens: resolvedInput,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: Double(resolvedInput + output + cacheCreation + cacheRead) / 1_000_000.0,
            sessionCount: sessionCount
        )
    }

    private static func origin(
        name: String,
        provider: ServiceType,
        total: Int,
        sessionCount: Int = 1
    ) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            provider: provider,
            name: name,
            inputTokens: total,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: Double(total) / 1_000_000.0,
            sessionCount: sessionCount
        )
    }

    /// Build a single-provider summary from model breakdowns, deriving the
    /// top-level token buckets so aggregates line up with the breakdowns.
    private static func summary(models: [TokenUsageBreakdown]) -> CostSummary {
        let input = models.reduce(0) { $0 + $1.inputTokens }
        let output = models.reduce(0) { $0 + $1.outputTokens }
        let cacheCreation = models.reduce(0) { $0 + $1.cacheCreationTokens }
        let cacheRead = models.reduce(0) { $0 + $1.cacheReadTokens }
        let cost = models.reduce(0) { $0 + $1.estimatedCostUSD }

        let tokenCost = TokenCost(
            provider: models.first?.provider ?? .claudeCode,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: cost,
            sessionCount: 1,
            periodStart: referenceNow.addingTimeInterval(-30 * 86_400),
            periodEnd: referenceNow,
            modelBreakdowns: models,
            originBreakdowns: []
        )
        let total = input + output + cacheCreation + cacheRead
        return CostSummary(
            costs: [tokenCost],
            totalCostUSD: cost,
            totalTokens: total,
            periodDays: 30,
            dailyUsage: []
        )
    }

    /// A realistic multi-model, multi-origin, 40-day summary.
    ///
    /// Model breakdowns use single-bucket totals so the premium-share assertion
    /// (opus / all-models) reads cleanly; the provider's aggregate token buckets
    /// are set independently below to drive the input/output and cache ratios.
    private static func populatedSummary() -> CostSummary {
        let shareModels = [
            model(name: "claude-opus-4-8", provider: .claudeCode, total: 3_000_000),
            model(name: "claude-sonnet-4-5", provider: .claudeCode, total: 1_000_000),
            model(name: "claude-haiku-4-5", provider: .claudeCode, total: 400_000)
        ]

        let origins = [
            origin(name: "Agents", provider: .claudeCode, total: 2_500_000),
            origin(name: "Main chat", provider: .claudeCode, total: 1_200_000),
            origin(name: "Tool use", provider: .claudeCode, total: 700_000)
        ]

        // Aggregate buckets: input 6.0M / output 1.5M (ratio 4.0);
        // cacheRead 8.0M / cacheCreation 2.0M (reuse 0.8).
        let tokenCost = TokenCost(
            provider: .claudeCode,
            inputTokens: 6_000_000,
            outputTokens: 1_500_000,
            cacheCreationTokens: 2_000_000,
            cacheReadTokens: 8_000_000,
            estimatedCostUSD: 42.0,
            sessionCount: 12,
            periodStart: referenceNow.addingTimeInterval(-40 * 86_400),
            periodEnd: referenceNow,
            modelBreakdowns: shareModels,
            originBreakdowns: origins
        )

        // 40 days of daily rows at 100k tokens/day (70k input + 30k read).
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceNow)
        let daily: [DailyTokenUsage] = (0..<40).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DailyTokenUsage(
                date: date,
                provider: .claudeCode,
                inputTokens: 70_000,
                outputTokens: 0,
                cacheReadTokens: 30_000,
                estimatedCostUSD: 0.5
            )
        }

        return CostSummary(
            costs: [tokenCost],
            totalCostUSD: 42.0,
            totalTokens: 17_500_000,
            periodDays: 40,
            dailyUsage: daily
        )
    }
}
