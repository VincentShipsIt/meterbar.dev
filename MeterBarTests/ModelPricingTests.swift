@testable import MeterBar
import MeterBarShared
import XCTest

final class ModelPricingTests: XCTestCase {
    func testSharedTableOwnsRevisionAndProviderRates() {
        // Each entry now carries its own verification date (issue #339); the
        // table's provenance is the span across every shipped entry. The
        // OpenAI admin-usage-API entries (issue #554) were verified later
        // than the Anthropic/Codex seed, so the span now covers both dates.
        XCTAssertEqual(ModelPricing.tableProvenance.verificationDates, ["2026-07-02", "2026-09-08"])
        XCTAssertEqual(ModelPricing.claude(for: "claude-fable-5").input, 10.0)
        XCTAssertEqual(ModelPricing.claude(for: "claude-opus-4-8-20260101").input, 5.0)
        XCTAssertEqual(ModelPricing.claude(for: "mystery-model").input, 3.0)
        XCTAssertEqual(ModelPricing.codex.input, 1.25)
        XCTAssertEqual(ModelPricing.codex.cacheRead, 0.125)
    }

    // MARK: - OpenAI admin-usage-API models (issue #554)

    func testOpenAIExactMatchingNeverLetsAShorterSlugShadowAMoreSpecificOne() {
        // "gpt-4" is a prefix of "gpt-4o", "gpt-4.1", and "gpt-4-turbo" — the
        // exact defect class (linear substring-in-list-order matching) that
        // mispriced Anthropic's Opus 4 before #537. Exact/most-specific-first
        // matching must keep every one of these at its own rate.
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4").input, 30.0)
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4o").input, 2.50)
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4o-mini").input, 0.15)
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4.1").input, 2.0)
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4.1-mini").input, 0.40)
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4-turbo").input, 10.0)
        XCTAssertEqual(ModelPricing.openAI(for: "o1").input, 15.0)
        XCTAssertEqual(ModelPricing.openAI(for: "o1-mini").input, 1.10)
        XCTAssertEqual(ModelPricing.openAI(for: "o3-mini").input, 1.10)
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-3.5-turbo").input, 0.50)
    }

    /// Cached input for the gpt-4.1 family is a 75% discount, not the 50%
    /// uniform discount the pre-#554 local table guessed for every model.
    func testOpenAIGpt41FamilyUsesItsOwnCachedInputDiscount() {
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4.1").cacheRead, 0.50)
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4.1-mini").cacheRead, 0.10)
        // gpt-4o family stays at its verified 50% discount.
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4o").cacheRead, 1.25)
    }

    /// Models whose pricing page lists no cached-input tier (they predate
    /// prompt caching) must not be given an invented discount.
    func testOpenAIModelsWithoutACachedTierPriceCacheReadAtTheFullInputRate() {
        for model in ["gpt-4-turbo", "gpt-4", "gpt-3.5-turbo"] {
            let pricing = ModelPricing.openAI(for: model)
            XCTAssertEqual(pricing.cacheRead, pricing.input, "\(model) should have no cache discount")
        }
    }

    func testOpenAIDatedSnapshotsNormalizeToTheirBaseModel() {
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4o-2024-08-06"), ModelPricing.openAI(for: "gpt-4o"))
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-4o-mini-2024-07-18"), ModelPricing.openAI(for: "gpt-4o-mini"))
        XCTAssertEqual(ModelPricing.openAI(for: "o1-2024-12-17"), ModelPricing.openAI(for: "o1"))
        XCTAssertEqual(ModelPricing.openAI(for: "o1-mini-2024-09-12"), ModelPricing.openAI(for: "o1-mini"))
        XCTAssertEqual(ModelPricing.openAI(for: "  GPT-4.1-2025-04-14  "), ModelPricing.openAI(for: "gpt-4.1"))
        XCTAssertEqual(ModelPricing.openAI(for: "gpt-3.5-turbo-0125"), ModelPricing.openAI(for: "gpt-3.5-turbo"))
    }

    func testUnknownOpenAIModelIsNotMarkedKnownAndFallsBackToTheDefaultRate() {
        XCTAssertTrue(ModelPricing.isKnownOpenAIModel("gpt-4o"))
        XCTAssertTrue(ModelPricing.isKnownOpenAIModel("gpt-4o-2024-08-06"))
        XCTAssertFalse(ModelPricing.isKnownOpenAIModel("gpt-9-unreleased"))
        XCTAssertFalse(ModelPricing.isKnownOpenAIModel(nil))

        XCTAssertEqual(ModelPricing.openAI(for: "gpt-9-unreleased"), ModelPricing.openAI)
        XCTAssertEqual(ModelPricing.openAI(for: nil), ModelPricing.openAI)
    }

    func testCodexLookupResolvesNamedModelsAndFallsBack() {
        // Every Codex slug bills at the same published rate today, so the named
        // rows exist to make a future divergence a one-line table edit rather
        // than a re-plumb — and so unknown slugs never price at zero.
        XCTAssertEqual(ModelPricing.codex(for: "gpt-5.6-sol"), ModelPricing.codex)
        XCTAssertEqual(ModelPricing.codex(for: "gpt-5.6-terra"), ModelPricing.codex)
        XCTAssertEqual(ModelPricing.codex(for: "gpt-5.6-luna"), ModelPricing.codex)
        XCTAssertEqual(ModelPricing.codex(for: "  GPT-5.6-Sol  "), ModelPricing.codex)
        XCTAssertEqual(ModelPricing.codex(for: "gpt-9-unreleased"), ModelPricing.codex)
        XCTAssertEqual(ModelPricing.codex(for: nil), ModelPricing.codex)
    }

    func testCostTrackerUsesTheSharedLookup() {
        let models = [nil, "claude-fable-9", "claude-opus-4-7", "claude-haiku-4-5", "unknown"]
        for model in models {
            XCTAssertEqual(ClaudeCostScanner.pricing(for: model), ModelPricing.claude(for: model))
        }
    }

    func testSharedPricingProducesStableFixtureTotal() {
        let pricing = ModelPricing.claude(for: "claude-sonnet-4-6")
        let total = TokenCostMath.calculateClaudeCost(
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
