import Foundation
import XCTest
@testable import MeterBar

/// Covers `CostScanFreshnessNote`, the pure model behind #530: the popover
/// header's "Updated N min ago" describes the quota poll, and the seven-day
/// sparkline underneath is fed by an independent cost scan. This type decides
/// when that gap is worth calling out next to the sparkline, so the wording
/// and the threshold are asserted directly rather than through a rendered
/// `ProviderDailyUsageSparkline`.
final class CostScanFreshnessNoteTests: XCTestCase {
    // Pinned so relative-time text and interval arithmetic are reproducible.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    // MARK: - Never scanned

    func testScanNeverRunSaysSoEvenWithAFreshQuotaPoll() {
        let note = CostScanFreshnessNote(
            quotaPollUpdatedAt: minutesAgo(1),
            costScanDate: nil,
            now: now
        )
        XCTAssertEqual(note.text, "Not scanned yet")
    }

    func testScanNeverRunSaysSoWithNoQuotaPollEither() {
        let note = CostScanFreshnessNote(quotaPollUpdatedAt: nil, costScanDate: nil, now: now)
        XCTAssertEqual(note.text, "Not scanned yet")
    }

    // MARK: - Close together

    func testScanAndPollCloseTogetherAddsNoSeparateNote() {
        let note = CostScanFreshnessNote(
            quotaPollUpdatedAt: minutesAgo(1),
            costScanDate: minutesAgo(5),
            now: now
        )
        XCTAssertNil(note.text)
    }

    func testScanNewerThanThePollAddsNoNote() {
        // A manual cost scan after the last quota poll — the scan is, if
        // anything, more current than the poll, never "materially older."
        let note = CostScanFreshnessNote(
            quotaPollUpdatedAt: minutesAgo(30),
            costScanDate: minutesAgo(1),
            now: now
        )
        XCTAssertNil(note.text)
    }

    // MARK: - Materially older

    func testScanMuchOlderThanPollIsLegibleAsItsOwnTimestamp() {
        let note = CostScanFreshnessNote(
            quotaPollUpdatedAt: minutesAgo(1),
            costScanDate: now.addingTimeInterval(-5 * 3600),
            now: now
        )
        XCTAssertEqual(note.text, "Scanned \(UsageFormat.relative(now.addingTimeInterval(-5 * 3600), to: now))")
    }

    func testScanWithNoQuotaPollToCompareStillReportsItsOwnClock() {
        let scanDate = minutesAgo(10)
        let note = CostScanFreshnessNote(quotaPollUpdatedAt: nil, costScanDate: scanDate, now: now)
        XCTAssertEqual(note.text, "Scanned \(UsageFormat.relative(scanDate, to: now))")
    }

    // MARK: - Threshold boundary

    func testGapExactlyAtTheThresholdIsNotYetMaterial() {
        let scanDate = now.addingTimeInterval(-CostScanFreshnessNote.materiallyOlderThreshold)
        let note = CostScanFreshnessNote(quotaPollUpdatedAt: now, costScanDate: scanDate, now: now)
        XCTAssertNil(note.text)
    }

    func testGapOneSecondPastTheThresholdIsMaterial() {
        let scanDate = now.addingTimeInterval(-CostScanFreshnessNote.materiallyOlderThreshold - 1)
        let note = CostScanFreshnessNote(quotaPollUpdatedAt: now, costScanDate: scanDate, now: now)
        XCTAssertEqual(note.text, "Scanned \(UsageFormat.relative(scanDate, to: now))")
    }

    func testThresholdMatchesTheAppsExistingStalenessConvention() {
        // Deliberately reuses `ProviderParseHealthRecord.staleAfter` (2 hours)
        // instead of a second bespoke magic number.
        XCTAssertEqual(CostScanFreshnessNote.materiallyOlderThreshold, ProviderParseHealthRecord.staleAfter)
    }
}
