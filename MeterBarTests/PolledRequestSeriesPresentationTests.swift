import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Coverage for the only view-facing surface a request-denominated provider
/// gets.
///
/// `ProviderUsageCostBuilder` deliberately refuses to give Cursor a row in
/// `costs[]`, because its counter is not money. This presentation is the other
/// half of that decision: the series still exists and is still shown, labelled
/// in the unit it was actually measured in.
final class PolledRequestSeriesPresentationTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    // MARK: - Units

    /// A dollar provider already appears in the spend chart, the dashboard total
    /// and the share card. Repeating it here would double-count it on screen.
    func testDollarProvidersAreExcluded() {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.openRouter, unit: .usd, total: 1, at: day(-2)))
        ledger.record(observation(.openRouter, unit: .usd, total: 9, at: day(-1)))

        let presentation = PolledRequestSeriesPresentation(ledger: ledger, now: day(0))

        XCTAssertTrue(presentation.providers.isEmpty)
        XCTAssertTrue(presentation.isEmpty)
    }

    /// The unit travels with the series so the view can never render a request
    /// count behind a currency symbol.
    func testRequestProviderCarriesItsOwnUnit() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 40, at: day(-2)))
        ledger.record(observation(.cursor, unit: .requests, total: 190, at: day(-1)))

        let presentation = PolledRequestSeriesPresentation(ledger: ledger, now: day(0))
        let series = try XCTUnwrap(presentation.providers.first)

        XCTAssertEqual(presentation.providers.map(\.provider), [.cursor])
        XCTAssertEqual(series.unit, .requests)
        XCTAssertEqual(series.days.map(\.amount), [150])
        XCTAssertEqual(series.total, 150, accuracy: 0.000_001)
        XCTAssertFalse(presentation.isEmpty)
    }

    // MARK: - Window boundaries

    /// The card is captioned with a window, so it must honour one. Retained
    /// history reaches back 400 days; drawing all of it under a "Last 30 days"
    /// heading would misstate the total.
    func testDaysOutsideTheRequestedWindowAreExcluded() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 0, at: day(-60)))
        ledger.record(observation(.cursor, unit: .requests, total: 500, at: day(-59)))
        ledger.record(observation(.cursor, unit: .requests, total: 520, at: day(-3)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, requestedDays: 30, now: day(0)).providers.first
        )

        XCTAssertEqual(series.days.map(\.date), [day(-3)])
        XCTAssertEqual(series.total, 20, accuracy: 0.000_001)
    }

    /// If the clock moves backwards a stored day can sit ahead of today. Drawing
    /// it would put a bar off the right edge of the chart.
    func testFutureDatedDaysAreExcluded() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 5, at: day(-1)))
        ledger.record(observation(.cursor, unit: .requests, total: 11, at: day(0)))
        ledger.record(observation(.cursor, unit: .requests, total: 99, at: day(4)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, requestedDays: 30, now: day(0)).providers.first
        )

        XCTAssertEqual(series.days.map(\.date), [day(0)])
        XCTAssertEqual(series.total, 6, accuracy: 0.000_001)
    }

    func testDaysAreOrderedOldestFirst() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 0, at: day(-3)))
        ledger.record(observation(.cursor, unit: .requests, total: 3, at: day(-1)))
        ledger.record(observation(.cursor, unit: .requests, total: 4, at: day(-2)))
        ledger.record(observation(.cursor, unit: .requests, total: 10, at: day(0)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.first
        )

        XCTAssertEqual(series.days.map(\.date), series.days.map(\.date).sorted())
    }

    // MARK: - What the series may and may not claim

    /// The tracking-start date is the whole honesty story for this card: it is
    /// what lets the view say the series begins at the first poll instead of
    /// implying the empty stretch before it was a stretch of zero usage.
    func testTrackingStartDateIsCarried() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 400, at: day(-5)))
        ledger.record(observation(.cursor, unit: .requests, total: 410, at: day(-1)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.first
        )

        XCTAssertEqual(series.trackingStartedOn, day(-5))
    }

    /// A first poll is a baseline, never a day's usage — so a provider polled
    /// once shows an empty series rather than a spike the size of the user's
    /// whole billing cycle.
    func testFirstPollAloneProducesAnEmptySeriesNotASpike() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 431, at: day(0)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.first
        )

        XCTAssertTrue(series.days.isEmpty)
        XCTAssertEqual(series.total, 0)
        XCTAssertEqual(series.trackingStartedOn, day(0))
    }

    /// Days before the first poll must be absent, not zero. A zero bar asserts
    /// that nothing was spent that day, which MeterBar has no way to know.
    func testDaysBeforeTrackingBeganAreAbsentRatherThanZero() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 100, at: day(-1)))
        ledger.record(observation(.cursor, unit: .requests, total: 130, at: day(0)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, requestedDays: 30, now: day(0)).providers.first
        )

        XCTAssertEqual(series.days.count, 1)
        XCTAssertEqual(series.days.map(\.date), [day(0)])
    }

    /// A provider that has never been polled has no card at all — an empty card
    /// reads as "measured nothing", which is a different claim from "not
    /// measured".
    func testNeverPolledProviderIsAbsentEntirely() {
        let presentation = PolledRequestSeriesPresentation(ledger: ProviderUsageLedger(), now: day(0))

        XCTAssertTrue(presentation.providers.isEmpty)
        XCTAssertTrue(presentation.isEmpty)
    }

    /// A counter that has not moved since tracking began is a real observation,
    /// so the provider keeps its card and its start date — only the series is
    /// empty.
    func testUnchangedCounterKeepsTheProviderButNotTheDays() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 7, at: day(-2)))
        ledger.record(observation(.cursor, unit: .requests, total: 7, at: day(-1)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.first
        )

        XCTAssertTrue(series.days.isEmpty)
        XCTAssertEqual(series.trackingStartedOn, day(-2))
    }

    /// Cycle rollover zeroes Cursor's counter. The ledger reads the drop as a
    /// reset, and the card must show the post-reset usage rather than a hole.
    func testCounterResetShowsPostResetUsageAndNeverANegativeDay() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 740, at: day(-2)))
        ledger.record(observation(.cursor, unit: .requests, total: 12, at: day(-1)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.first
        )

        XCTAssertEqual(series.days.map(\.amount), [12])
        XCTAssertTrue(series.days.allSatisfy { $0.amount > 0 })
    }

    // MARK: - Labelling

    /// The label is the last place the unit can be lost. A currency symbol here
    /// would undo every guard upstream, because a user reads the label, not the
    /// enum.
    func testTotalIsLabelledInRequestsAndCarriesNoCurrencySymbol() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 0, at: day(-2)))
        ledger.record(observation(.cursor, unit: .requests, total: 1_204, at: day(-1)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.first
        )

        XCTAssertTrue(series.formattedTotal.hasSuffix("requests"), series.formattedTotal)
        XCTAssertFalse(series.formattedTotal.contains("$"))
    }

    /// One request is one request, not "1 requests".
    func testSingleRequestIsLabelledInTheSingular() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 8, at: day(-2)))
        ledger.record(observation(.cursor, unit: .requests, total: 9, at: day(-1)))

        let series = try XCTUnwrap(
            PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.first
        )

        XCTAssertEqual(series.formattedTotal, "1 request")
    }

    // MARK: - Ordering

    func testProvidersAreOrderedDeterministically() {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 1, at: day(-2)))
        ledger.record(observation(.cursor, unit: .requests, total: 5, at: day(-1)))
        ledger.record(observation(.grok, unit: .requests, total: 1, at: day(-2)))
        ledger.record(observation(.grok, unit: .requests, total: 3, at: day(-1)))

        let first = PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.map(\.provider)
        let second = PolledRequestSeriesPresentation(ledger: ledger, now: day(0)).providers.map(\.provider)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
    }

    // MARK: - Helpers

    private func observation(
        _ provider: ServiceType,
        unit: ProviderUsageUnit,
        total: Double,
        at date: Date
    ) -> ProviderUsageObservation {
        ProviderUsageObservation(provider: provider, unit: unit, runningTotal: total, observedAt: date)
    }

    /// Start of the day `offset` days after a fixed epoch.
    private func day(_ offset: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 20
        components.hour = 12
        let base = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let shifted = calendar.date(byAdding: .day, value: offset, to: base) ?? base
        return calendar.startOfDay(for: shifted)
    }
}
