import Foundation
import MeterBarShared
import XCTest

final class LocalizedUsageFormattingTests: XCTestCase {
    private func limit(used: Double, isEstimated: Bool = false) -> UsageLimit {
        UsageLimit(
            used: used,
            total: 100,
            resetTime: nil,
            isEstimated: isEstimated
        )
    }

    func testQuotaPercentFormattingKeepsUsedAndRemainingSemantics() {
        XCTAssertEqual(
            LocalizedUsageFormat.percentLeft(limit(used: 40), locale: Locale(identifier: "en")),
            "60% left"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.percentUsed(limit(used: 40), locale: Locale(identifier: "en")),
            "40% used"
        )
    }

    func testEstimatedPercentFormattingKeepsApproximationMark() {
        XCTAssertEqual(
            LocalizedUsageFormat.percentLeft(
                limit(used: 100, isEstimated: true),
                locale: Locale(identifier: "en")
            ),
            "~0% left"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.percentUsed(
                limit(used: 40, isEstimated: true),
                locale: Locale(identifier: "en")
            ),
            "~40% used"
        )
    }

    func testCountdownUsesLocaleAwareUnitFormatting() {
        let english = LocalizedUsageFormat.countdown(
            seconds: 3_660,
            locale: Locale(identifier: "en")
        )
        let japanese = LocalizedUsageFormat.countdown(
            seconds: 3_660,
            locale: Locale(identifier: "ja")
        )

        XCTAssertEqual(english, "1h 1m")
        XCTAssertNotEqual(japanese, english)
        XCTAssertFalse(japanese.isEmpty)
    }

    func testCountdownKeepsCompactSubMinuteFallback() {
        XCTAssertEqual(
            LocalizedUsageFormat.countdown(seconds: 59, locale: Locale(identifier: "en")),
            "<1m"
        )
    }
}
