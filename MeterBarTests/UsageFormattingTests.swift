import XCTest
@testable import MeterBar

final class UsageFormattingTests: XCTestCase {
    // MARK: - Compact tokens

    func testCompactTokensBelowThousand() {
        XCTAssertEqual(UsageFormat.tokens(0), "0")
        XCTAssertEqual(UsageFormat.tokens(999), "999")
    }

    func testCompactTokensThousands() {
        XCTAssertEqual(UsageFormat.tokens(1_000), "1.0K")
        XCTAssertEqual(UsageFormat.tokens(1_500), "1.5K")
        XCTAssertEqual(UsageFormat.tokens(999_999), "1000.0K")
    }

    func testCompactTokensMillions() {
        XCTAssertEqual(UsageFormat.tokens(1_000_000), "1.0M")
        XCTAssertEqual(UsageFormat.tokens(2_500_000), "2.5M")
    }

    func testCompactTokensBillions() {
        // Regression: a duplicate formatter without the billions tier rendered
        // 1B as "1000.0M". The shared formatter must use the B suffix.
        XCTAssertEqual(UsageFormat.tokens(1_000_000_000), "1.0B")
        XCTAssertEqual(UsageFormat.tokens(3_400_000_000), "3.4B")
    }

    // MARK: - Grouped tokens

    func testGroupedTokensInsertsSeparators() {
        XCTAssertEqual(UsageFormat.groupedTokens(1_234_567), "1,234,567")
        XCTAssertEqual(UsageFormat.groupedTokens(0), "0")
        XCTAssertEqual(UsageFormat.groupedTokens(999), "999")
    }

    // MARK: - Cost

    func testCostFormatting() {
        XCTAssertEqual(UsageFormat.cost(0), "$0.00")
        XCTAssertEqual(UsageFormat.cost(1.5), "$1.50")
        XCTAssertEqual(UsageFormat.cost(123.456), "$123.46")
        XCTAssertEqual(UsageFormat.cost(6_954.07), "$6,954.07")
    }

    // MARK: - Relative date

    func testRelativeDateIsNonEmpty() {
        let earlier = Date(timeIntervalSince1970: 1_000_000)
        let reference = earlier.addingTimeInterval(3_600)
        XCTAssertFalse(UsageFormat.relative(earlier, to: reference).isEmpty)
    }
}
