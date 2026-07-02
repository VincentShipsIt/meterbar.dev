import XCTest
@testable import MeterBar
import MeterBarShared

final class QuotaBandsTests: XCTestCase {
    // MARK: - Band edges

    func testBandEdges() {
        XCTAssertEqual(QuotaBand.forPercentLeft(-5), .exhausted)
        XCTAssertEqual(QuotaBand.forPercentLeft(0), .exhausted)
        XCTAssertEqual(QuotaBand.forPercentLeft(1), .critical)
        XCTAssertEqual(QuotaBand.forPercentLeft(10), .critical)
        XCTAssertEqual(QuotaBand.forPercentLeft(11), .tight)
        XCTAssertEqual(QuotaBand.forPercentLeft(25), .tight)
        XCTAssertEqual(QuotaBand.forPercentLeft(26), .healthy)
        XCTAssertEqual(QuotaBand.forPercentLeft(100), .healthy)
    }

    func testLabelsPerBand() {
        XCTAssertEqual(QuotaBand.healthy.shortLabel, "Healthy")
        XCTAssertEqual(QuotaBand.tight.shortLabel, "Tight")
        XCTAssertEqual(QuotaBand.critical.shortLabel, "Critical")
        XCTAssertEqual(QuotaBand.exhausted.shortLabel, "Out")
    }

    func testIconSeverityAgreesWithBands() {
        XCTAssertEqual(QuotaBand.healthy.iconName, "checkmark.shield.fill")
        XCTAssertEqual(QuotaBand.tight.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(QuotaBand.critical.iconName, "exclamationmark.octagon.fill")
        XCTAssertEqual(QuotaBand.exhausted.iconName, "exclamationmark.octagon.fill")
    }

    // MARK: - percentLeft rounding

    func testPercentLeftRounding() {
        // Ceil: partially-consumed percent still counts as "left".
        XCTAssertEqual(QuotaMath.percentLeft(usedPercent: 0), 100)
        XCTAssertEqual(QuotaMath.percentLeft(usedPercent: 42), 58)
        XCTAssertEqual(QuotaMath.percentLeft(usedPercent: 89.5), 11)
        XCTAssertEqual(QuotaMath.percentLeft(usedPercent: 90), 10)
        // Floors at 1 while any quota remains…
        XCTAssertEqual(QuotaMath.percentLeft(usedPercent: 99.5), 1)
        XCTAssertEqual(QuotaMath.percentLeft(usedPercent: 99.999), 1)
        // …and reads 0 only when truly spent (or overspent).
        XCTAssertEqual(QuotaMath.percentLeft(usedPercent: 100), 0)
        XCTAssertEqual(QuotaMath.percentLeft(usedPercent: 120), 0)
    }

    func testPercentLeftForLimitUsesRawPercentage() {
        // rawPercentage is unclamped, so an overspent limit still lands at 0.
        let overspent = UsageLimit(used: 150, total: 100, resetTime: nil)
        XCTAssertEqual(QuotaMath.percentLeft(for: overspent), 0)

        let zeroTotal = UsageLimit(used: 50, total: 0, resetTime: nil)
        XCTAssertEqual(QuotaMath.percentLeft(for: zeroTotal), 100)
    }

    // MARK: - Notification-band equivalence

    func testNotificationBandsMatchLegacyThresholds() {
        // The old notification scheme warned at >= 90% used and alerted at
        // >= 100% used. Those are exactly the critical and exhausted bands.
        let warnLimit = UsageLimit(used: 90, total: 100, resetTime: nil)
        XCTAssertEqual(QuotaBand.forLimit(warnLimit), .critical)

        let belowWarn = UsageLimit(used: 89, total: 100, resetTime: nil)
        XCTAssertEqual(QuotaBand.forLimit(belowWarn), .tight)

        let atLimit = UsageLimit(used: 100, total: 100, resetTime: nil)
        XCTAssertEqual(QuotaBand.forLimit(atLimit), .exhausted)
    }
}
