import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

@MainActor
final class ClaudePlatformGrantPresentationTests: XCTestCase {

    // MARK: Internal

    func testEveryMeasuredGrantRetainsCurrencyAndCentsInCLIAndProviderCards() {
        let metrics = UsageMetrics(
            service: .claudePlatform,
            weeklyLimit: UsageLimit(used: 75.25, total: 200.50, resetTime: nil),
            additionalLimits: [
                UsageLimit(used: 37.50, total: 100.75, resetTime: nil, label: "Purchased credit"),
                UsageLimit(used: 1.25, total: 12.75, resetTime: nil, label: "Other credit"),
            ],
            lastUpdated: now
        )
        let text = CLIUsageTextReport.lines(for: [.claudePlatform: metrics]).joined(separator: "\n")
        XCTAssertTrue(text.contains("$75.25 spent / $200.50 credits"), text)
        XCTAssertTrue(text.contains("$37.50 spent / $100.75 credits"), text)
        XCTAssertTrue(text.contains("$1.25 spent / $12.75 credits"), text)

        let limits = ProviderSnapshotBuilder.limits(for: metrics, service: .claudePlatform)
        XCTAssertEqual(limits.count, 3)
        XCTAssertTrue(limits.allSatisfy { $0.valueStyle == .currency })
        XCTAssertEqual(limits.map(\.accessibilityValue), [
            "$125.25 left, $75.25 spent",
            "$63.25 left, $37.50 spent",
            "$11.50 left, $1.25 spent",
        ])
    }

    func testDemoGrantsHaveNoResetCountdown() throws {
        let metrics = try XCTUnwrap(DemoData.metrics(now: now)[.claudePlatform])
        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(try XCTUnwrap(metrics.weeklyLimit).resetTime)
        XCTAssertFalse(metrics.additionalLimits.isEmpty)
        XCTAssertTrue(metrics.additionalLimits.allSatisfy { $0.resetTime == nil })
    }

    func testWidgetPlaceholderGrantHasNoResetCountdown() throws {
        let metrics = try XCTUnwrap(WidgetPlaceholderMetrics.burnDown(now: now)[.claudePlatform])
        XCTAssertNil(try XCTUnwrap(metrics.weeklyLimit).resetTime)
    }

    func testSettingsPreviewWithoutLiveMetricsUsesGrantsWithoutResetWindows() throws {
        let preview = WidgetSettingsPreviewData.make(
            options: [WidgetSettingsAccountOption(
                id: .provider(.claudePlatform), service: .claudePlatform, name: "Claude Platform"
            )],
            metrics: [:],
            claudeAccountMetrics: [:],
            codexAccountMetrics: [:],
            now: now
        )
        XCTAssertTrue(preview.usesPlaceholders)
        let metrics = try XCTUnwrap(preview.metrics[.claudePlatform])
        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(try XCTUnwrap(metrics.weeklyLimit).resetTime)
        XCTAssertTrue(metrics.additionalLimits.allSatisfy { $0.resetTime == nil })
        XCTAssertNil(metrics.codeReviewLimit)
    }

    // MARK: Private

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

}
