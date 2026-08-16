import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// `meterbar usage` text output. The quota titles must come from the same
/// `ServiceType` helpers the popover, widget, and notifications use — the CLI
/// spelled the code-review label out itself and printed "Code Review" over
/// Cursor's on-demand window.
final class CLIUsageTextReportTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testCursorCodeReviewWindowIsTitledOnDemand() {
        let text = render(
            .cursor,
            metric: UsageMetrics(
                service: .cursor,
                codeReviewLimit: UsageLimit(used: 12, total: 50, resetTime: nil),
                lastUpdated: referenceDate
            )
        )

        XCTAssertTrue(text.contains("On-demand:"), text)
        XCTAssertFalse(text.contains("Code Review"), text)
    }

    func testClaudeCodeReviewWindowUsesTheReportedModelLabel() {
        let text = render(
            .claudeCode,
            metric: UsageMetrics(
                service: .claudeCode,
                codeReviewLimit: UsageLimit(used: 12, total: 50, resetTime: nil),
                modelLimitLabel: "Fable",
                lastUpdated: referenceDate
            )
        )

        XCTAssertTrue(text.contains("Fable:"), text)
        XCTAssertFalse(text.contains("Code Review"), text)
    }

    /// No label parsed from the CLI payload: a neutral "Model", never a
    /// hardcoded model name.
    func testClaudeCodeReviewWindowFallsBackToModelWithoutALabel() {
        let text = render(
            .claudeCode,
            metric: UsageMetrics(
                service: .claudeCode,
                codeReviewLimit: UsageLimit(used: 12, total: 50, resetTime: nil),
                lastUpdated: referenceDate
            )
        )

        XCTAssertTrue(text.contains("Model:"), text)
    }

    /// Providers whose third window really is code review keep that title.
    func testCodexCodeReviewWindowKeepsTheCodeReviewTitle() {
        let text = render(
            .codexCli,
            metric: UsageMetrics(
                service: .codexCli,
                codeReviewLimit: UsageLimit(used: 12, total: 50, resetTime: nil),
                lastUpdated: referenceDate
            )
        )

        XCTAssertTrue(text.contains("Code Review:"), text)
    }

    func testAccountSnapshotsListIndependentlyInsteadOfHidingBehindTheProviderRow() {
        let work = AccountUsageSnapshot(
            id: UUID(),
            name: "Work",
            metrics: UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 80, total: 100, resetTime: nil),
                lastUpdated: referenceDate
            )
        )
        let personal = AccountUsageSnapshot(
            id: UUID(),
            name: "Personal",
            metrics: UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
                lastUpdated: referenceDate
            )
        )
        let text = CLIUsageTextReport.lines(
            for: [
                .claudeCode: MetricsFixtures.claudeCode(),
                .cursor: MetricsFixtures.cursor(),
            ],
            accounts: [work, personal]
        ).joined(separator: "\n")

        XCTAssertTrue(text.contains("▸ Claude Code · Personal"), text)
        XCTAssertTrue(text.contains("▸ Claude Code · Work"), text)
        XCTAssertTrue(text.contains("▸ Cursor"), text)
        XCTAssertFalse(text.contains("▸ Claude Code\n"), text)
    }

    func testProviderOnlyOutputIsUnchangedWhenTheAccountCacheIsMissing() {
        let metric = UsageMetrics(
            service: .cursor,
            codeReviewLimit: UsageLimit(used: 12, total: 50, resetTime: nil),
            lastUpdated: referenceDate
        )
        let withoutAccounts = CLIUsageTextReport.lines(for: [.cursor: metric])
        let withEmptyAccounts = CLIUsageTextReport.lines(for: [.cursor: metric], accounts: [])

        XCTAssertEqual(withoutAccounts, withEmptyAccounts)
        XCTAssertTrue(withoutAccounts.joined(separator: "\n").contains("▸ Cursor"))
    }

    func testUnknownAccountFilterPrintsADeterministicEmptyMessage() {
        let text = CLIUsageTextReport.lines(
            for: [.claudeCode: MetricsFixtures.claudeCode()],
            accounts: [
                AccountUsageSnapshot(
                    id: UUID(),
                    name: "Work",
                    metrics: MetricsFixtures.claudeCode()
                ),
            ],
            accountFilter: "Missing"
        ).joined(separator: "\n")

        XCTAssertTrue(text.contains(UsageCLISelection.noMatchingAccountsMessage), text)
        XCTAssertFalse(text.contains("▸ Claude Code"), text)
    }

    func testGrokMonthlyWeeklySlotIsTitledMonthlyNeverWeekly() {
        let text = render(
            .grok,
            metric: UsageMetrics(
                service: .grok,
                weeklyLimit: UsageLimit(used: 41, total: 100, resetTime: nil, periodKind: .monthly),
                lastUpdated: referenceDate
            )
        )

        XCTAssertTrue(text.contains("Monthly:"), text)
        XCTAssertFalse(text.contains("Weekly"), text)
    }

    func testAdditionalLimitsAppearInTheTextReport() {
        let text = render(
            .grok,
            metric: UsageMetrics(
                service: .grok,
                weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil, periodKind: .weekly),
                additionalLimits: [
                    UsageLimit(used: 12, total: 100, resetTime: nil, periodKind: .daily)
                ],
                lastUpdated: referenceDate
            )
        )

        XCTAssertTrue(text.contains("Weekly:"), text)
        XCTAssertTrue(text.contains("Daily:"), text)
    }

    private func render(_ service: ServiceType, metric: UsageMetrics) -> String {
        CLIUsageTextReport.lines(for: [service: metric]).joined(separator: "\n")
    }
}
