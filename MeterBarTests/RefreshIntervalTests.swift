import XCTest
@testable import MeterBar

final class RefreshIntervalTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(RefreshInterval.oneMinute.rawValue, 60)
        XCTAssertEqual(RefreshInterval.twoMinutes.rawValue, 120)
        XCTAssertEqual(RefreshInterval.fiveMinutes.rawValue, 300)
        XCTAssertEqual(RefreshInterval.tenMinutes.rawValue, 600)
        XCTAssertEqual(RefreshInterval.fifteenMinutes.rawValue, 900)
        XCTAssertEqual(RefreshInterval.thirtyMinutes.rawValue, 1800)
        XCTAssertEqual(RefreshInterval.manual.rawValue, 0)
    }

    func testDisplayNames() {
        XCTAssertEqual(RefreshInterval.oneMinute.displayName, "1 minute")
        XCTAssertEqual(RefreshInterval.twoMinutes.displayName, "2 minutes")
        XCTAssertEqual(RefreshInterval.fiveMinutes.displayName, "5 minutes")
        XCTAssertEqual(RefreshInterval.tenMinutes.displayName, "10 minutes")
        XCTAssertEqual(RefreshInterval.fifteenMinutes.displayName, "15 minutes")
        XCTAssertEqual(RefreshInterval.thirtyMinutes.displayName, "30 minutes")
        XCTAssertEqual(RefreshInterval.manual.displayName, "Manual only")
    }

    func testSecondsProperty() {
        XCTAssertEqual(RefreshInterval.oneMinute.seconds, 60.0, accuracy: 0.01)
        XCTAssertEqual(RefreshInterval.twoMinutes.seconds, 120.0, accuracy: 0.01)
        XCTAssertEqual(RefreshInterval.fiveMinutes.seconds, 300.0, accuracy: 0.01)
        XCTAssertEqual(RefreshInterval.tenMinutes.seconds, 600.0, accuracy: 0.01)
        XCTAssertEqual(RefreshInterval.fifteenMinutes.seconds, 900.0, accuracy: 0.01)
        XCTAssertEqual(RefreshInterval.thirtyMinutes.seconds, 1800.0, accuracy: 0.01)
        XCTAssertEqual(RefreshInterval.manual.seconds, 0.0, accuracy: 0.01)
    }

    func testIdProperty() {
        XCTAssertEqual(RefreshInterval.oneMinute.id, 60)
        XCTAssertEqual(RefreshInterval.manual.id, 0)
    }

    func testAllCasesCount() {
        XCTAssertEqual(RefreshInterval.allCases.count, 7)
    }

    func testAllCasesContainsExpectedValues() {
        let allCases = RefreshInterval.allCases
        XCTAssertTrue(allCases.contains(.oneMinute))
        XCTAssertTrue(allCases.contains(.twoMinutes))
        XCTAssertTrue(allCases.contains(.fiveMinutes))
        XCTAssertTrue(allCases.contains(.tenMinutes))
        XCTAssertTrue(allCases.contains(.fifteenMinutes))
        XCTAssertTrue(allCases.contains(.thirtyMinutes))
        XCTAssertTrue(allCases.contains(.manual))
    }

    func testDefaultIntervalIsTenMinutes() {
        XCTAssertEqual(RefreshInterval.defaultInterval, .tenMinutes)
    }
}
