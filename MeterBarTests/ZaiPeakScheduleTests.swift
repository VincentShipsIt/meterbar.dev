import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// The Z.ai peak schedule: Monday–Friday 14:00–18:00 Singapore time (UTC+8),
/// with all-day off-peak pricing from 25 September to 7 October 2026.
final class ZaiPeakScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600) ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    // 2026-08-03 is a Monday; 2026-08-08 a Saturday; 2026-08-09 a Sunday.

    func testPeakBeginsAtFourteenHundredOnAWeekday() {
        let before = ZaiPeakSchedule.status(at: date(2026, 8, 3, 13, 59))
        XCTAssertFalse(before.isPeak)
        XCTAssertEqual(before.nextChange, date(2026, 8, 3, 14))

        let start = ZaiPeakSchedule.status(at: date(2026, 8, 3, 14))
        XCTAssertTrue(start.isPeak)
        XCTAssertFalse(start.isPromotion)
        XCTAssertEqual(start.nextChange, date(2026, 8, 3, 18))
    }

    func testPeakEndsAtEighteenHundred() {
        XCTAssertTrue(ZaiPeakSchedule.status(at: date(2026, 8, 3, 17, 59)).isPeak)

        let end = ZaiPeakSchedule.status(at: date(2026, 8, 3, 18))
        XCTAssertFalse(end.isPeak)
        XCTAssertEqual(end.nextChange, date(2026, 8, 4, 14))
    }

    func testFridayEveningRollsToMondayNotSaturday() {
        let friday = ZaiPeakSchedule.status(at: date(2026, 8, 7, 18, 30))

        XCTAssertFalse(friday.isPeak)
        XCTAssertEqual(friday.nextChange, date(2026, 8, 10, 14))
    }

    func testWeekendAfternoonIsOffPeak() {
        for day in [8, 9] {
            let status = ZaiPeakSchedule.status(at: date(2026, 8, day, 15))
            XCTAssertFalse(status.isPeak, "August \(day)")
            XCTAssertFalse(status.isPromotion)
            XCTAssertEqual(status.nextChange, date(2026, 8, 10, 14))
        }
    }

    func testOffPeakOvernightCountsDownToTheNextPeakStart() {
        let status = ZaiPeakSchedule.status(at: date(2026, 8, 4, 3))

        XCTAssertFalse(status.isPeak)
        XCTAssertEqual(status.nextChange, date(2026, 8, 4, 14))
    }

    func testTimeZoneOfTheUserDoesNotMatterOnlyTheInstant() {
        // 2026-08-03 06:00 UTC == 14:00 UTC+8.
        let instant = Date(timeIntervalSince1970: date(2026, 8, 3, 14).timeIntervalSince1970)
        XCTAssertTrue(ZaiPeakSchedule.status(at: instant).isPeak)
    }

    // MARK: - Promotion

    func testPromotionMakesWeekdayPeakHoursOffPeak() {
        // 2026-09-28 is a Monday, inside 25 Sep – 7 Oct.
        let status = ZaiPeakSchedule.status(at: date(2026, 9, 28, 15))

        XCTAssertFalse(status.isPeak)
        XCTAssertTrue(status.isPromotion)
        XCTAssertEqual(status.nextChange, date(2026, 10, 8, 14), "peak resumes the first afternoon after the promotion")
    }

    func testPromotionCoversItsFirstAndLastDay() {
        XCTAssertTrue(ZaiPeakSchedule.status(at: date(2026, 9, 25, 14)).isPromotion)
        XCTAssertTrue(ZaiPeakSchedule.status(at: date(2026, 10, 7, 17, 59)).isPromotion)
    }

    func testPeakIsBackAfterThePromotionAndBeforeItSchedulePricingApplies() {
        let after = ZaiPeakSchedule.status(at: date(2026, 10, 8, 14))
        XCTAssertTrue(after.isPeak)
        XCTAssertFalse(after.isPromotion)

        let before = ZaiPeakSchedule.status(at: date(2026, 9, 24, 15))
        XCTAssertTrue(before.isPeak)
        XCTAssertFalse(before.isPromotion)
        XCTAssertEqual(before.nextChange, date(2026, 9, 24, 18))
    }

    func testPromotionStartFlipsAPeakAfternoonToOffPeak() {
        // Thursday 2026-09-24 17:59 is peak; Friday 09-25 00:00 the promotion begins.
        let status = ZaiPeakSchedule.status(at: date(2026, 9, 24, 17, 59))

        XCTAssertTrue(status.isPeak)
        XCTAssertEqual(status.nextChange, date(2026, 9, 24, 18))
    }

    // MARK: - Words

    func testLabelsNameTheCurrentRateAndTheNextChange() {
        let now = date(2026, 8, 3, 15)
        let peak = ZaiPeakSchedule.status(at: now)
        XCTAssertEqual(ZaiPeakPresentation.label(peak, now: now), "Peak · off-peak in 3h")

        let off = ZaiPeakSchedule.status(at: date(2026, 8, 3, 18, 30))
        XCTAssertEqual(ZaiPeakPresentation.label(off, now: date(2026, 8, 3, 18, 30)), "Off-peak · peak in 19h 30m")

        let promoNow = date(2026, 9, 28, 15)
        let promo = ZaiPeakSchedule.status(at: promoNow)
        XCTAssertTrue(ZaiPeakPresentation.label(promo, now: promoNow).hasPrefix("Off-peak all day · peak resumes in"))
    }

    func testStatusWithNoKnownChangeStillNamesTheRate() {
        XCTAssertEqual(
            ZaiPeakPresentation.label(.init(isPeak: true, isPromotion: false, nextChange: nil)),
            "Peak"
        )
        XCTAssertEqual(
            ZaiPeakPresentation.label(.init(isPeak: false, isPromotion: false, nextChange: nil)),
            "Off-peak"
        )
    }
}
