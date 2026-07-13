@testable import MeterBar
import MeterBarShared
import XCTest

final class ModelPricingTests: XCTestCase {
    func testSharedTableOwnsRevisionAndProviderRates() {
        XCTAssertEqual(ModelPricing.revision, "2026-07-02")
        XCTAssertEqual(ModelPricing.claude(for: "claude-fable-5").input, 10.0)
        XCTAssertEqual(ModelPricing.claude(for: "claude-opus-4-8-20260101").input, 5.0)
        XCTAssertEqual(ModelPricing.claude(for: "mystery-model").input, 3.0)
        XCTAssertEqual(ModelPricing.codex.input, 1.25)
        XCTAssertEqual(ModelPricing.codex.cacheRead, 0.125)
    }

    func testCostTrackerUsesTheSharedLookup() {
        let models = [nil, "claude-fable-9", "claude-opus-4-7", "claude-haiku-4-5", "unknown"]
        for model in models {
            XCTAssertEqual(CostTracker.claudePricing(for: model), ModelPricing.claude(for: model))
        }
    }

    func testSharedPricingProducesStableFixtureTotal() {
        let pricing = ModelPricing.claude(for: "claude-sonnet-4-6")
        let total = CostTracker.calculateClaudeCost(
            input: 1_000_000,
            output: 2_000_000,
            cacheCreation: 500_000,
            cacheCreationOneHour: 100_000,
            cacheRead: 4_000_000,
            pricing: pricing
        )

        XCTAssertEqual(total, 36.3, accuracy: 0.000_001)
    }
}
