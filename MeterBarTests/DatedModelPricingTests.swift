@testable import MeterBar
import MeterBarShared
import XCTest

/// Issue #339 — events are priced at the rate in effect at their timestamp.
///
/// The schedule fixtures are built by hand rather than read from the shipped
/// table: the shipped entries are all open-ended backwards (see
/// `ModelPricing`), so only a synthetic schedule can exercise a boundary or a
/// pre-history event today. Locking the behaviour here means the first real
/// dated entry someone adds is a one-line table edit, not a redesign.
final class DatedModelPricingTests: XCTestCase {
    private let oldRate = TokenPricing(
        input: 2.0, output: 10.0, cacheCreation: 2.5, cacheRead: 0.20, cacheCreationOneHour: 4.0)
    private let newRate = TokenPricing(
        input: 4.0, output: 20.0, cacheCreation: 5.0, cacheRead: 0.40, cacheCreationOneHour: 8.0)

    private var firstEffective: Date { DatedTokenPricing.utcDay(2026, 1, 1) }
    private var secondEffective: Date { DatedTokenPricing.utcDay(2026, 7, 1) }

    private func makeSchedule() -> PricingSchedule {
        PricingSchedule([
            DatedTokenPricing(effectiveFrom: firstEffective, verifiedOn: "2026-01-05", pricing: oldRate),
            DatedTokenPricing(effectiveFrom: secondEffective, verifiedOn: "2026-07-02", pricing: newRate)
        ])
    }

    // MARK: - Range boundaries

    func testEventExactlyAtEffectiveFromUsesTheNewEntry() throws {
        let resolved = try XCTUnwrap(makeSchedule().resolve(at: secondEffective))

        XCTAssertEqual(resolved.pricing, newRate)
        XCTAssertEqual(resolved.effectiveFrom, secondEffective)
        XCTAssertEqual(resolved.verifiedOn, "2026-07-02")
        XCTAssertFalse(resolved.precedesFirstEntry)
    }

    func testEventOneSecondBeforeEffectiveFromUsesThePreviousEntry() throws {
        let resolved = try XCTUnwrap(makeSchedule().resolve(at: secondEffective.addingTimeInterval(-1)))

        XCTAssertEqual(resolved.pricing, oldRate)
        XCTAssertEqual(resolved.effectiveFrom, firstEffective)
        XCTAssertEqual(resolved.verifiedOn, "2026-01-05")
        XCTAssertFalse(resolved.precedesFirstEntry)
    }

    func testEventAfterTheNewestEntryKeepsUsingIt() throws {
        let resolved = try XCTUnwrap(makeSchedule().resolve(at: DatedTokenPricing.utcDay(2030, 3, 9)))

        XCTAssertEqual(resolved.pricing, newRate)
        XCTAssertEqual(resolved.verifiedOn, "2026-07-02")
    }

    func testEntriesResolveRegardlessOfConstructionOrder() throws {
        let reversed = PricingSchedule([
            DatedTokenPricing(effectiveFrom: secondEffective, verifiedOn: "2026-07-02", pricing: newRate),
            DatedTokenPricing(effectiveFrom: firstEffective, verifiedOn: "2026-01-05", pricing: oldRate)
        ])

        XCTAssertEqual(reversed.entries.map(\.effectiveFrom), [firstEffective, secondEffective])
        XCTAssertEqual(try XCTUnwrap(reversed.resolve(at: firstEffective)).pricing, oldRate)
        XCTAssertEqual(try XCTUnwrap(reversed.resolve(at: secondEffective)).pricing, newRate)
    }

    // MARK: - Pre-history

    func testEventBeforeEveryEntryPricesAtTheOldestEntryAndIsFlagged() throws {
        let resolved = try XCTUnwrap(makeSchedule().resolve(at: DatedTokenPricing.utcDay(2024, 6, 1)))

        // Not failing, not zero — the oldest known rate, flagged as a guess.
        XCTAssertEqual(resolved.pricing, oldRate)
        XCTAssertEqual(resolved.effectiveFrom, firstEffective)
        XCTAssertTrue(resolved.precedesFirstEntry)
    }

    func testEmptyScheduleResolvesToNothingRatherThanZeroRates() {
        XCTAssertNil(PricingSchedule([]).resolve(at: Date()))
    }

    // MARK: - Regression: a new dated entry must not move historical costs

    func testAddingALaterEntryLeavesEarlierCostsUnchanged() throws {
        let before = PricingSchedule([
            DatedTokenPricing(effectiveFrom: firstEffective, verifiedOn: "2026-01-05", pricing: oldRate)
        ])
        let after = makeSchedule()
        let historical = DatedTokenPricing.utcDay(2026, 3, 15)

        let costBefore = Self.cost(using: try XCTUnwrap(before.resolve(at: historical)).pricing)
        let costAfter = Self.cost(using: try XCTUnwrap(after.resolve(at: historical)).pricing)
        XCTAssertEqual(costBefore, costAfter, accuracy: 0.000_001)

        // ...and the new entry does apply once its effectiveFrom is reached.
        let costToday = Self.cost(using: try XCTUnwrap(after.resolve(at: secondEffective)).pricing)
        XCTAssertNotEqual(costAfter, costToday, accuracy: 0.000_001)
    }

    private static func cost(using pricing: TokenPricing) -> Double {
        TokenCostMath.calculateClaudeCost(
            input: 1_000_000,
            output: 2_000_000,
            cacheCreation: 500_000,
            cacheCreationOneHour: 100_000,
            cacheRead: 4_000_000,
            pricing: pricing
        )
    }

    // MARK: - Current-rate lookup against the shipped table

    func testShippedTableResolvesTodaysPublishedRates() {
        let now = Date()
        XCTAssertEqual(ModelPricing.claude(for: "claude-fable-5", at: now).input, 10.0)
        XCTAssertEqual(ModelPricing.claude(for: "claude-opus-4-8-20260101", at: now).input, 5.0)
        XCTAssertEqual(ModelPricing.claude(for: "claude-sonnet-4-6", at: now).cacheCreationOneHour, 6.0)
        XCTAssertEqual(ModelPricing.claude(for: "mystery-model", at: now).input, 3.0)
        XCTAssertEqual(ModelPricing.codex(for: "gpt-5.6-sol", at: now).input, 1.25)
    }

    func testShippedTableHasNoPreHistoryGap() {
        // Every seeded entry is open-ended backwards on purpose: we never
        // verified historical Anthropic/OpenAI rates, and inventing effective
        // dates would silently mis-price old sessions. So no timestamp, however
        // old, may come back flagged as pre-history from the shipped table.
        let ancient = DatedTokenPricing.utcDay(2019, 1, 1)
        for model in ["claude-fable-5", "claude-opus-4-8", "claude-haiku-4-5", "unknown-model", nil] {
            let resolved = ModelPricing.resolveClaude(for: model, at: ancient)
            XCTAssertFalse(resolved.precedesFirstEntry, "\(model ?? "nil") reported pre-history")
            XCTAssertEqual(resolved.pricing, ModelPricing.claude(for: model), "\(model ?? "nil") drifted by date")
        }
        XCTAssertFalse(ModelPricing.resolveCodex(for: "gpt-5.6-sol", at: ancient).precedesFirstEntry)
    }

    func testDefaultTimestampArgumentPricesAtTodaysRate() {
        XCTAssertEqual(ModelPricing.claude(for: "claude-opus"), ModelPricing.claude(for: "claude-opus", at: Date()))
        XCTAssertEqual(ModelPricing.codex, ModelPricing.codex(for: nil, at: Date()))
    }

    // MARK: - Provenance

    func testProvenanceCollectsVerificationDatesAndPreHistoryCount() throws {
        let schedule = makeSchedule()
        var provenance = PricingProvenance()
        provenance.record(try XCTUnwrap(schedule.resolve(at: DatedTokenPricing.utcDay(2024, 6, 1))))
        provenance.record(try XCTUnwrap(schedule.resolve(at: DatedTokenPricing.utcDay(2026, 3, 1))))
        provenance.record(try XCTUnwrap(schedule.resolve(at: secondEffective)))

        XCTAssertEqual(provenance.verificationDates, ["2026-01-05", "2026-07-02"])
        XCTAssertEqual(provenance.eventsBeforeFirstEntry, 1)
        XCTAssertEqual(provenance.label, "Rates verified 2026-01-05–2026-07-02")
        XCTAssertNotNil(provenance.diagnosticNote)
    }

    func testProvenanceLabelUsesASingleDateWhenAllEntriesAgree() throws {
        var provenance = PricingProvenance()
        provenance.record(try XCTUnwrap(makeSchedule().resolve(at: secondEffective)))

        XCTAssertEqual(provenance.label, "Rates verified 2026-07-02")
        XCTAssertNil(provenance.diagnosticNote)
        XCTAssertFalse(provenance.isEmpty)
    }

    func testProvenanceMergeUnionsDatesAndSumsPreHistory() {
        var left = PricingProvenance(verificationDates: ["2026-07-02"], eventsBeforeFirstEntry: 2)
        let right = PricingProvenance(verificationDates: ["2026-01-05", "2026-07-02"], eventsBeforeFirstEntry: 3)
        left.merge(right)

        XCTAssertEqual(left.verificationDates, ["2026-01-05", "2026-07-02"])
        XCTAssertEqual(left.eventsBeforeFirstEntry, 5)
    }

    func testEmptyProvenanceIsEmptyAndUnlabelled() {
        // Nothing was priced, so there is no entry to name. Call sites fall back
        // to `ModelPricing.tableProvenance` rather than showing this label.
        let provenance = PricingProvenance()
        XCTAssertTrue(provenance.isEmpty)
        XCTAssertNil(provenance.diagnosticNote)
        XCTAssertEqual(provenance.label, "Rates verified —")
    }

    func testTableProvenanceDescribesTheShippedEntries() {
        XCTAssertFalse(ModelPricing.tableProvenance.isEmpty)
        XCTAssertEqual(ModelPricing.tableProvenance.eventsBeforeFirstEntry, 0)
        XCTAssertEqual(ModelPricing.tableProvenance.label, "Rates verified 2026-07-02")
    }
}
