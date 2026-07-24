import XCTest
import MeterBarShared
@testable import MeterBar

final class DiagnosticsRunnerTests: XCTestCase {
    func testRefreshErrorsIncludesEnabledDefaultClaudeError() {
        let result = DiagnosticsRunner.refreshErrors(
            claudeDefaultAccountEnabled: true,
            claudeError: .apiError("x"),
            codexError: nil,
            cursorError: nil,
            openRouterError: nil,
            grokError: nil
        )

        XCTAssertNotNil(result[.claudeCode])
    }

    func testRefreshErrorsOmitsDisabledDefaultClaudeAndKeepsCodexError() {
        let result = DiagnosticsRunner.refreshErrors(
            claudeDefaultAccountEnabled: false,
            claudeError: .apiError("claude"),
            codexError: .apiError("codex"),
            cursorError: nil,
            openRouterError: nil,
            grokError: nil
        )

        XCTAssertNil(result[.claudeCode])
        XCTAssertNotNil(result[.codexCli])
    }

    func testRefreshErrorsWithNoErrorsIsEmpty() {
        let result = DiagnosticsRunner.refreshErrors(
            claudeDefaultAccountEnabled: true,
            claudeError: nil,
            codexError: nil,
            cursorError: nil,
            openRouterError: nil,
            grokError: nil
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testRefreshErrorsMapsEachNonClaudeProvider() {
        let result = DiagnosticsRunner.refreshErrors(
            claudeDefaultAccountEnabled: true,
            claudeError: nil,
            codexError: .apiError("codex"),
            cursorError: .apiError("cursor"),
            openRouterError: .apiError("openrouter"),
            grokError: .apiError("grok")
        )

        XCTAssertNotNil(result[.codexCli])
        XCTAssertNotNil(result[.cursor])
        XCTAssertNotNil(result[.openRouter])
        XCTAssertNotNil(result[.grok])
    }

    func testSummaryReturnsNilForEmptyReports() {
        XCTAssertNil(DiagnosticsRunner.summary(for: []))
    }

    func testSummaryMatchesProviderReadinessSummary() {
        let reports = [report()]

        XCTAssertEqual(
            DiagnosticsRunner.summary(for: reports),
            ProviderReadinessSummary(reports: reports).displayText
        )
    }

    func testReportTextMatchesDiagnosticsReportText() {
        let reports = [report()]

        XCTAssertEqual(
            DiagnosticsRunner.reportText(for: reports),
            DiagnosticsReportText.plainText(reports)
        )
    }

    private func report() -> ProviderReadiness {
        ProviderReadiness(
            provider: .codexCli,
            checks: [
                ReadinessCheck(
                    id: "test",
                    title: "Test",
                    level: .pass,
                    detail: "Ready"
                ),
            ]
        )
    }
}
