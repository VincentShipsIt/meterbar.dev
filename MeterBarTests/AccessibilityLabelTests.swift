import XCTest
@testable import MeterBar
import MeterBarShared

/// Covers the pure VoiceOver label/value composition on `SnapshotLimit` and
/// `ProviderSnapshot`. These strings are what the popover, dashboard, and
/// detail-panel cards feed into `.accessibilityLabel`/`.accessibilityValue`, so
/// asserting them here guarantees the three limit-row renderers and both
/// provider-card branches speak identically without a rendered-view harness.
final class AccessibilityLabelTests: XCTestCase {
    private func limit(
        used: Double,
        total: Double = 100,
        resetIn seconds: TimeInterval? = nil,
        isEstimated: Bool = false
    ) -> UsageLimit {
        UsageLimit(
            used: used,
            total: total,
            resetTime: seconds.map { Date().addingTimeInterval($0) },
            isEstimated: isEstimated
        )
    }

    private func snapshotLimit(
        kind: SnapshotLimit.Kind = .session,
        title: String = "Session",
        limit: UsageLimit,
        valueStyle: SnapshotLimit.ValueStyle = .quota
    ) -> SnapshotLimit {
        SnapshotLimit(id: title, kind: kind, title: title, usageLimit: limit, valueStyle: valueStyle)
    }

    // MARK: - SnapshotLimit label

    func testLimitLabelIsTitleWhenReported() {
        let row = snapshotLimit(limit: limit(used: 40))
        XCTAssertEqual(row.accessibilityLabel, "Session")
    }

    func testLimitLabelAppendsEstimatedWhenDerived() {
        let row = snapshotLimit(limit: limit(used: 40, isEstimated: true))
        XCTAssertEqual(row.accessibilityLabel, "Session, estimated")
    }

    // MARK: - SnapshotLimit value

    func testQuotaLimitValueSpeaksLeftAndUsedPercent() {
        let row = snapshotLimit(limit: limit(used: 40))
        // 40% used -> 60% left.
        XCTAssertEqual(row.accessibilityValue, "60% left, 40% used")
    }

    func testEstimatedLimitValueCarriesApproximationMark() {
        let row = snapshotLimit(limit: limit(used: 40, isEstimated: true))
        XCTAssertEqual(row.accessibilityValue, "~60% left, ~40% used")
    }

    func testExhaustedQuotaLimitValueSaysOut() {
        let row = snapshotLimit(limit: limit(used: 100))
        XCTAssertTrue(row.accessibilityValue.hasPrefix("Out, "), row.accessibilityValue)
    }

    func testExhaustedEstimatedLimitDoesNotSayOut() {
        // Estimated totals are never presented as a hard "Out".
        let row = snapshotLimit(limit: limit(used: 100, isEstimated: true))
        XCTAssertFalse(row.accessibilityValue.hasPrefix("Out"), row.accessibilityValue)
    }

    func testCurrencyLimitValueSpeaksDollars() {
        let row = snapshotLimit(
            kind: .session,
            title: "Key limit",
            limit: limit(used: 3, total: 10),
            valueStyle: .currency
        )
        // $7.00 left, $3.00 spent (exact formatting comes from UsageFormat.cost).
        XCTAssertTrue(row.accessibilityValue.contains("left"), row.accessibilityValue)
        XCTAssertTrue(row.accessibilityValue.contains("spent"), row.accessibilityValue)
    }

    // MARK: - ProviderSnapshot label

    func testProviderLabelIncludesTitleBandAndFreshness() {
        let snapshot = ProviderSnapshot(
            id: "codex",
            title: "Codex",
            service: .codexCli,
            updatedAt: nil,
            limits: [snapshotLimit(limit: limit(used: 10))],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
        // 10% used -> healthy band, no updatedAt -> "No data" freshness.
        XCTAssertEqual(snapshot.accessibilityLabel, "Codex, Healthy, No data")
    }

    func testProviderLabelReportsExhaustedBand() {
        let snapshot = ProviderSnapshot(
            id: "claude",
            title: "Claude",
            service: .claudeCode,
            updatedAt: nil,
            limits: [snapshotLimit(kind: .weekly, title: "Weekly", limit: limit(used: 100))],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
        XCTAssertTrue(snapshot.accessibilityLabel.contains("Out"), snapshot.accessibilityLabel)
    }

    // MARK: - ProviderSnapshot value

    func testProviderValueEnumeratesEveryWindow() {
        let snapshot = ProviderSnapshot(
            id: "codex",
            title: "Codex",
            service: .codexCli,
            updatedAt: nil,
            limits: [
                snapshotLimit(kind: .session, title: "Session", limit: limit(used: 40)),
                snapshotLimit(kind: .weekly, title: "Weekly", limit: limit(used: 20))
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
        let value = snapshot.accessibilityValue
        XCTAssertTrue(value.contains("Session"), value)
        XCTAssertTrue(value.contains("Weekly"), value)
        XCTAssertTrue(value.contains("60% left"), value)
        XCTAssertTrue(value.contains("80% left"), value)
    }

    func testProviderValueFallsBackToEmptyDetail() {
        let snapshot = ProviderSnapshot(
            id: "cursor",
            title: "Cursor",
            service: .cursor,
            updatedAt: nil,
            limits: [],
            emptyDetail: "Log in to Cursor",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
        XCTAssertEqual(snapshot.accessibilityValue, "Log in to Cursor")
    }
}
