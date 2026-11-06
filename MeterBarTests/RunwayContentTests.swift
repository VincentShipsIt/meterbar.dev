import MeterBarShared
import XCTest
@testable import MeterBar

final class RunwayContentTests: XCTestCase {
    private let week: TimeInterval = 7 * 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func content(used: Double, elapsedDays: Double) -> RunwayContent? {
        let reset = now.addingTimeInterval(week - elapsedDays * 86_400)
        let limit = UsageLimit(used: used, total: 100, resetTime: reset, windowSeconds: week, periodKind: .weekly)
        return RunwayContent(limit: limit, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
    }

    func testBurningFasterThanThePaceProjectsAShortfall() throws {
        // 81% used after 3.5 of 7 days: empty after ~4.3 days, ~2.7 days short.
        let runway = try XCTUnwrap(content(used: 81, elapsedDays: 3.5))
        XCTAssertEqual(runway.outlook, .shortfall)
        XCTAssertTrue(runway.headline.hasPrefix("Out by"))
        XCTAssertTrue(runway.detail.hasSuffix("short"))
        XCTAssertEqual(runway.geometry.projectionEnd.y, 1)
        XCTAssertEqual(runway.geometry.projectionEnd.x, 3.5 / 7 + (19.0 / 81 * 3.5) / 7, accuracy: 0.001)
    }

    func testUnderPaceLastsAndReportsTheReserve() throws {
        let runway = try XCTUnwrap(content(used: 20, elapsedDays: 3.5))
        XCTAssertEqual(runway.outlook, .lasts)
        XCTAssertEqual(runway.headline, "Lasts until reset")
        XCTAssertTrue(runway.detail.contains("30% in reserve"))
        XCTAssertEqual(runway.geometry.projectionEnd.x, 1)
        XCTAssertEqual(runway.geometry.projectionEnd.y, 0.4, accuracy: 0.001)
    }

    func testIneligibleWindowsHaveNoRunway() {
        XCTAssertNil(content(used: 100, elapsedDays: 3.5))
        let estimated = UsageLimit(
            used: 50, total: 100, resetTime: now.addingTimeInterval(86_400),
            windowSeconds: week, isEstimated: true
        )
        XCTAssertNil(RunwayContent(limit: estimated, now: now))
        let noWindow = UsageLimit(used: 50, total: 100, resetTime: now.addingTimeInterval(86_400))
        XCTAssertNil(RunwayContent(limit: noWindow, now: now))
    }

    // MARK: - Annotations

    private let en = Locale(identifier: "en_US")

    private func content(
        used: Double,
        window: TimeInterval,
        elapsed: TimeInterval,
        kind: UsageLimit.PeriodKind
    ) -> RunwayContent? {
        let limit = UsageLimit(
            used: used,
            total: 100,
            resetTime: now.addingTimeInterval(window - elapsed),
            windowSeconds: window,
            periodKind: kind
        )
        return RunwayContent(limit: limit, now: now, calendar: utc, locale: en)
    }

    /// `now` is 2027-01-15 08:00 UTC. A 5 hour window that is 3.6 hours in resets at 09:24
    /// and opened at 04:24, so the full hours 05:00 to 09:00 sit inside it.
    func testSessionWindowGetsAnHourlyAxis() throws {
        let runway = try XCTUnwrap(content(used: 20, window: 5 * 3_600, elapsed: 3.6 * 3_600, kind: .session))

        XCTAssertEqual(runway.ticks.count, 5)
        XCTAssertEqual(runway.ticks.first?.x ?? -1, 36.0 / 300, accuracy: 0.001)
        XCTAssertEqual(runway.ticks.last?.x ?? -1, 276.0 / 300, accuracy: 0.001)
        XCTAssertTrue(runway.ticks.first?.label.hasPrefix("5") == true)
        XCTAssertTrue(runway.ticks.last?.label.hasPrefix("9") == true)
    }

    /// Opened Thursday 03:00, resets next Thursday 03:00. Each local midnight in between is a tick.
    func testWeeklyWindowGetsADailyAxis() throws {
        let runway = try XCTUnwrap(content(used: 20, window: week, elapsed: 29 * 3_600, kind: .weekly))

        XCTAssertEqual(runway.ticks.map(\.label), ["Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"])
        XCTAssertEqual(runway.ticks.first?.x ?? -1, 21.0 / 168, accuracy: 0.001)
        XCTAssertTrue(runway.ticks.allSatisfy { $0.x > 0 && $0.x < 1 })
    }

    func testLongWindowsThinTheirAxisInsteadOfCrowdingIt() throws {
        let month: TimeInterval = 30 * 86_400
        let runway = try XCTUnwrap(content(used: 20, window: month, elapsed: 10 * 86_400, kind: .monthly))

        XCTAssertFalse(runway.ticks.isEmpty)
        XCTAssertLessThanOrEqual(runway.ticks.count, RunwayContent.maxTicks)
    }

    func testShortfallNamesHowLongTheQuotaIsGone() throws {
        let runway = try XCTUnwrap(content(used: 81, elapsedDays: 3.5))
        let remaining = 3.5 * 86_400
        let emptyAfter = 19.0 / 81 * 3.5 * 86_400

        XCTAssertEqual(runway.shortfallDuration, UsageDurationText.short(seconds: remaining - emptyAfter))
        XCTAssertTrue(runway.detail.hasSuffix("\(runway.shortfallDuration ?? "") short"))
    }

    func testLastingRunwayHasNoShortfall() throws {
        let runway = try XCTUnwrap(content(used: 20, elapsedDays: 3.5))

        XCTAssertNil(runway.shortfallDuration)
    }

    func testRunwayKeepsTheWindowItWasDrawnFrom() throws {
        let runway = try XCTUnwrap(content(used: 20, window: 5 * 3_600, elapsed: 3_600, kind: .session))

        XCTAssertEqual(runway.windowSeconds, 5 * 3_600)
        XCTAssertEqual(runway.resetAt, now.addingTimeInterval(4 * 3_600))
    }

    // MARK: - Eligibility

    private func snapshotLimit(
        _ kind: SnapshotLimit.Kind,
        window: TimeInterval? = 5 * 3_600,
        isEstimated: Bool = false
    ) -> SnapshotLimit {
        SnapshotLimit(
            id: "\(kind)",
            kind: kind,
            title: "\(kind)",
            usageLimit: UsageLimit(
                used: 20,
                total: 100,
                resetTime: now.addingTimeInterval(3_600),
                windowSeconds: window,
                isEstimated: isEstimated
            )
        )
    }

    func testSessionAndWeeklyWindowsAreEligibleForARunway() {
        XCTAssertTrue(RunwayContent.isEligible(snapshotLimit(.session), now: now))
        XCTAssertTrue(RunwayContent.isEligible(snapshotLimit(.weekly, window: week), now: now))
    }

    func testModelAndReviewWindowsStayBars() {
        XCTAssertFalse(RunwayContent.isEligible(snapshotLimit(.codeReview), now: now))
        XCTAssertFalse(RunwayContent.isEligible(snapshotLimit(.additional), now: now))
    }

    func testWindowsWithoutACadenceOrWithAnEstimatedTotalStayBars() {
        XCTAssertFalse(RunwayContent.isEligible(snapshotLimit(.session, window: nil), now: now))
        XCTAssertFalse(RunwayContent.isEligible(snapshotLimit(.weekly, window: week, isEstimated: true), now: now))
    }

    // MARK: - DST

    /// A Claude-style weekly window that spans the 2026-10-25 EU fall-back:
    /// opened Fri Oct 23 12:00 CEST, resets Fri Oct 30 11:00 CET (both 10:00 UTC).
    private func parisWeekAcrossFallBack(used: Double) throws -> RunwayContent {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let iso = ISO8601DateFormatter()
        let reset = try XCTUnwrap(iso.date(from: "2026-10-30T10:00:00Z"))
        let now = try XCTUnwrap(iso.date(from: "2026-10-27T10:00:00Z"))
        let limit = UsageLimit(used: used, total: 100, resetTime: reset, windowSeconds: week, periodKind: .weekly)
        return try XCTUnwrap(RunwayContent(limit: limit, now: now, calendar: paris, locale: en))
    }

    func testDailyAxisPlacesMidnightsAcrossTheFallBack() throws {
        let runway = try parisWeekAcrossFallBack(used: 20)

        XCTAssertEqual(runway.ticks.map(\.label), ["Sat", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri"])
        // Sat 00:00 CEST is 12h in; Sunday has 25 hours, so Mon 00:00 CET is 61h in.
        let hoursIn = runway.ticks.map { Double($0.x) * 168 }
        XCTAssertEqual(hoursIn[0], 12, accuracy: 0.001)
        XCTAssertEqual(hoursIn[1], 36, accuracy: 0.001)
        XCTAssertEqual(hoursIn[2], 61, accuracy: 0.001)
        XCTAssertEqual(hoursIn[6], 157, accuracy: 0.001)
    }

    /// The two tests below only prove the calendar's zone is honoured if the
    /// process runs in a different one. This sentinel fails if it does not, but
    /// only in the isolated CI invocation that sets `TZ=Pacific/Kiritimati`:
    /// on a developer machine that happens to be in Paris it would fail a
    /// full `swift test` for no real reason. Never change the process zone from
    /// inside a test: the suite runs concurrently.
    func testProcessZoneDiffersFromTheParisTestCalendar() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TZ"] == "Pacific/Kiritimati",
            "Runs only in the isolated TZ invocation"
        )
        XCTAssertNotEqual(
            TimeZone.current.identifier,
            "Europe/Paris",
            "reset-clock tests would not detect a missing calendar-zone conversion"
        )
        XCTAssertNotEqual(
            TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 1_793_000_000)),
            TimeZone(identifier: "Europe/Paris")?.secondsFromGMT(for: Date(timeIntervalSince1970: 1_793_000_000))
        )
    }

    /// The headline and detail name the reset in the calendar's zone, the same
    /// one the axis uses, whatever zone the process runs in.
    func testResetClockUsesTheCalendarZone() throws {
        let runway = try parisWeekAcrossFallBack(used: 20)

        XCTAssertTrue(runway.detail.hasPrefix("Resets Fri 11"), runway.detail)
    }

    func testShortfallHeadlineUsesTheCalendarZone() throws {
        // 90% used 96h in: empty 96 * 10 / 90 ≈ 10.67h later, Tue Oct 27 21:40 CET.
        let runway = try parisWeekAcrossFallBack(used: 90)

        XCTAssertEqual(runway.outlook, .shortfall)
        XCTAssertTrue(runway.headline.hasPrefix("Out by Tue 9"), runway.headline)
        XCTAssertTrue(runway.detail.hasPrefix("Resets Fri 11"), runway.detail)
    }
}
