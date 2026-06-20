import SwiftUI
import XCTest
@testable import MeterBar

final class MeterBarThemeTests: XCTestCase {
    func testQuotaStatusColorBuckets() {
        // danger: percentLeft <= 10
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 0), MeterBarTheme.danger)
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 10), MeterBarTheme.danger)
        // warning: 11...25
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 11), MeterBarTheme.warning)
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 25), MeterBarTheme.warning)
        // success: > 25
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 26), MeterBarTheme.success)
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 100), MeterBarTheme.success)
    }

    func testMetricColorMatchesDangerThreshold() {
        // Metric turns red across the whole critical band (<= 10), agreeing with
        // the status label, and stays neutral above it.
        XCTAssertEqual(MeterBarTheme.metricColor(percentLeft: -5), MeterBarTheme.danger)
        XCTAssertEqual(MeterBarTheme.metricColor(percentLeft: 0), MeterBarTheme.danger)
        XCTAssertEqual(MeterBarTheme.metricColor(percentLeft: 10), MeterBarTheme.danger)
        XCTAssertEqual(MeterBarTheme.metricColor(percentLeft: 11), Color.primary)
        XCTAssertEqual(MeterBarTheme.metricColor(percentLeft: 100), Color.primary)
    }

    func testAccentForEveryService() {
        XCTAssertEqual(MeterBarTheme.accent(for: .claude), MeterBarTheme.claudeAccent)
        XCTAssertEqual(MeterBarTheme.accent(for: .claudeCode), MeterBarTheme.claudeAccent)
        XCTAssertEqual(MeterBarTheme.accent(for: .openai), MeterBarTheme.codexAccent)
        XCTAssertEqual(MeterBarTheme.accent(for: .codexCli), MeterBarTheme.codexAccent)
        XCTAssertEqual(MeterBarTheme.accent(for: .cursor), MeterBarTheme.cursorAccent)
    }
}
