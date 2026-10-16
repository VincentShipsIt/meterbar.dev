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
}
