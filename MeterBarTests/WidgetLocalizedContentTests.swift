import Foundation
import MeterBarShared
import XCTest
@testable import MeterBarWidgetContent

/// Calls the widget extension's own formatter (`WidgetLocalizedContent`), not
/// the shared presentation model's English `summaryText`. The two have
/// separate currency-remainder branches, so a regression in the widget's one
/// would pass every test that only reads the shared model.
final class WidgetLocalizedContentTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func firstRow(_ metrics: UsageMetrics) throws -> WidgetPresentationRow {
        var preferences = WidgetPreferences.defaults
        preferences.preservesLegacyOpenRouterBalance = false
        let presentation = WidgetPresentationPlanner.makePresentation(
            metrics: [metrics.service: metrics],
            accountMetrics: [],
            preferences: preferences,
            family: .medium,
            now: now,
            stalenessThreshold: WidgetPresentationPlanner.defaultStalenessThreshold
        )
        return try XCTUnwrap(presentation.rows.first { $0.limit != nil })
    }

    func testCurrencyRemainderKeepsItsDollarUnitAndLeftWording() throws {
        let row = try firstRow(
            UsageMetrics(
                service: .openRouter,
                weeklyLimit: UsageLimit(used: 7.5, total: 20, resetTime: nil, reading: .remainder),
                lastUpdated: now
            )
        )

        XCTAssertEqual(
            WidgetLocalizedContent.summaryText(for: row),
            LocalizedUsageFormat.amountLeft("$12.50")
        )
    }

    func testCreditRemainderStaysAGroupedCountWithoutADollarSign() throws {
        let row = try firstRow(
            UsageMetrics(
                service: .codexCli,
                weeklyLimit: UsageLimit(
                    used: 0,
                    total: 61_586.14,
                    resetTime: nil,
                    label: "Credits",
                    reading: .remainder
                ),
                lastUpdated: now
            )
        )

        let text = WidgetLocalizedContent.summaryText(for: row)
        XCTAssertEqual(text, LocalizedUsageFormat.amountLeft("61,586.14"))
        XCTAssertFalse(text.contains("$"), text)
    }

    func testZeroCurrencyBalanceReadsAsDollars() throws {
        let row = try firstRow(
            UsageMetrics(
                service: .openRouter,
                weeklyLimit: UsageLimit(used: 0, total: 0, resetTime: nil, reading: .remainder),
                lastUpdated: now
            )
        )

        XCTAssertEqual(WidgetLocalizedContent.summaryText(for: row), LocalizedUsageFormat.amountLeft("$0.00"))
    }

    func testWidgetAndSharedSummariesAgreeOnCurrencyRemainders() throws {
        let row = try firstRow(
            UsageMetrics(
                service: .openRouter,
                weeklyLimit: UsageLimit(used: 7.5, total: 20, resetTime: nil, reading: .remainder),
                lastUpdated: now
            )
        )

        XCTAssertEqual(WidgetLocalizedContent.summaryText(for: row), row.summaryText)
    }
}
