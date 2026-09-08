import MeterBarShared
import XCTest
@testable import MeterBar

/// Covers `ProviderDailyUsageSparkline.captionText(for:)` in isolation — no
/// SwiftUI, so the coverage-caption zone hazard (issue #534, defect 2) is
/// directly testable without hosting the view. The same reason
/// `LimitRow.RowContent` and `UsageBar.BarGeometry` exist as extensions.
final class ProviderDailyUsageSparklineTests: XCTestCase {
    private var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private var losAngelesCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// OpenRouter's `.utc` boundary means `coverageStart` is a UTC midnight.
    /// Viewed from America/Los_Angeles (UTC-7 in September), that instant
    /// falls on the *previous* local evening — exactly the discrepancy from
    /// issue #534: "Tracked since Mon, Sep 7" over bars labelled Tue, Sep 8.
    /// The caption must name the bucket's day, not the viewer's.
    ///
    /// `viewerCalendar` is passed explicitly (rather than relying on the
    /// default `.current`) so this fails deterministically on a regression
    /// regardless of which real zone happens to run the test — `coverageStart`
    /// is always exactly a UTC midnight, so an ambient `Calendar.current` only
    /// exposes this bug on a negative-UTC-offset test host, and would pass by
    /// accident on, say, a CEST host without pinning the zone this way.
    func testCoverageCaptionUsesTheBucketZoneNotTheViewersLocalZone() throws {
        let now = try XCTUnwrap(utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12)))
        let firstObserved = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 0)))

        var ledger = ProviderUsageLedger()
        ledger.record(
            ProviderUsageObservation(
                provider: .openRouter,
                unit: .usd,
                runningTotal: 4,
                authoritativeDailyTotal: 1.5,
                dayBoundary: .utc,
                observedAt: firstObserved
            ),
            calendar: losAngelesCalendar
        )

        let series = ProviderDailyUsageSeries(
            service: .openRouter,
            ledger: ledger,
            dayCount: 7,
            now: now,
            calendar: losAngelesCalendar
        )

        XCTAssertTrue(series.hasPartialCoverage)
        let coverageStart = try XCTUnwrap(series.coverageStart)

        let localZoneLabel = ProviderDailyUsageFormat.weekdayAndDate(coverageStart, calendar: losAngelesCalendar)
        let bucketZoneLabel = ProviderDailyUsageFormat.weekdayAndDate(coverageStart, calendar: utcCalendar)
        // Confirms the test genuinely straddles a day boundary between the two
        // zones — otherwise the assertion below would pass for the wrong reason.
        XCTAssertNotEqual(localZoneLabel, bucketZoneLabel)

        let caption = try XCTUnwrap(
            ProviderDailyUsageSparkline.captionText(for: series, viewerCalendar: losAngelesCalendar))
        XCTAssertEqual(caption, "Tracked since \(bucketZoneLabel)")
        XCTAssertNotEqual(caption, "Tracked since \(localZoneLabel)")
    }

    /// The caption renders in the same zone the bars underneath do: the same
    /// `Day.longLabel` the bar strip itself uses (`helpText(for:)`'s tooltip),
    /// never a separately-formatted string that can drift from it.
    func testCoverageCaptionMatchesTheCorrespondingBarsLabel() throws {
        let now = try XCTUnwrap(utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12)))
        let firstObserved = try XCTUnwrap(
            utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 0)))

        var ledger = ProviderUsageLedger()
        ledger.record(
            ProviderUsageObservation(
                provider: .openRouter,
                unit: .usd,
                runningTotal: 4,
                authoritativeDailyTotal: 1.5,
                dayBoundary: .utc,
                observedAt: firstObserved
            ),
            calendar: losAngelesCalendar
        )

        let series = ProviderDailyUsageSeries(
            service: .openRouter,
            ledger: ledger,
            dayCount: 7,
            now: now,
            calendar: losAngelesCalendar
        )

        let coverageStart = try XCTUnwrap(series.coverageStart)
        let coverageDay = try XCTUnwrap(series.days.first { $0.date == coverageStart })

        // Pinned to a zone that disagrees with the bucket zone (see the test
        // above), so this only passes when the caption ignores the viewer's
        // zone in favor of the bar's own label — not by host-zone accident.
        let caption = try XCTUnwrap(
            ProviderDailyUsageSparkline.captionText(for: series, viewerCalendar: losAngelesCalendar))
        XCTAssertEqual(caption, "Tracked since \(coverageDay.longLabel)")
    }

    /// Cross-account combination still wins over the coverage caption — no
    /// zone math applies to that branch, and this pins the two captions can
    /// never both render.
    func testCombinedAccountsCaptionTakesPriorityOverCoverage() {
        let series = ProviderDailyUsageSeries(
            service: .claudeCode,
            dailyUsage: [],
            accountCount: 2,
            dayCount: 7,
            now: Date(timeIntervalSince1970: 1_750_000_000),
            calendar: utcCalendar
        )

        XCTAssertEqual(
            ProviderDailyUsageSparkline.captionText(for: series),
            "Across all \(series.service.shortName) accounts")
    }
}
