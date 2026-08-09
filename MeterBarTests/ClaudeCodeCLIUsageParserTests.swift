import XCTest
@testable import MeterBar

final class ClaudeCodeCLIUsageParserTests: XCTestCase {
    func testParsesCurrentClaudeUsageOutput() throws {
        let output = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 36% used · resets Jun 11 at 10:40am (Europe/Malta)
        Current week (all models): 100% used · resets Jun 12 at 7am (Europe/Malta)
        Current week (Sonnet only): 83% used · resets Jun 12 at 6:59am (Europe/Malta)
        """

        let now = Date(timeIntervalSince1970: 1_781_154_000)
        let metrics = try ClaudeCodeCLIUsageParser.parseMetrics(from: output, now: now)

        XCTAssertEqual(metrics.service, .claudeCode)
        let sessionLimit = try XCTUnwrap(metrics.sessionLimit)
        let weeklyLimit = try XCTUnwrap(metrics.weeklyLimit)
        let codeReviewLimit = try XCTUnwrap(metrics.codeReviewLimit)
        XCTAssertEqual(sessionLimit.percentage, 36, accuracy: 0.01)
        XCTAssertEqual(weeklyLimit.percentage, 100, accuracy: 0.01)
        XCTAssertEqual(codeReviewLimit.percentage, 83, accuracy: 0.01)
        XCTAssertEqual(metrics.modelLimitLabel, "Sonnet")
        XCTAssertNotNil(sessionLimit.resetTime)
        XCTAssertNotNil(weeklyLimit.resetTime)
        XCTAssertNotNil(codeReviewLimit.resetTime)
    }

    func testParsesRemainingPercentAsUsedPercent() throws {
        let output = """
        Current session: 64% remaining · resets Jun 11 at 10:40am
        Current week (all models): 25% left · resets Jun 12 at 7am
        """

        let metrics = try ClaudeCodeCLIUsageParser.parseMetrics(
            from: output,
            now: Date(timeIntervalSince1970: 1_781_154_000))

        let sessionLimit = try XCTUnwrap(metrics.sessionLimit)
        let weeklyLimit = try XCTUnwrap(metrics.weeklyLimit)
        XCTAssertEqual(sessionLimit.percentage, 36, accuracy: 0.01)
        XCTAssertEqual(weeklyLimit.percentage, 75, accuracy: 0.01)
    }

    /// The CLI renamed the model-specific window from "Sonnet only" to "Fable"
    /// (observed 2026-07, claude 2.1.205); both labels must keep parsing.
    func testParsesFableWeeklyWindow() throws {
        let output = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 13% used · resets Jul 12 at 4pm (Europe/Malta)
        Current week (all models): 23% used · resets Jul 17 at 10pm (Europe/Malta)
        Current week (Fable): 32% used · resets Jul 17 at 10pm (Europe/Malta)

        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine.
        """

        let metrics = try ClaudeCodeCLIUsageParser.parseMetrics(
            from: output,
            now: Date(timeIntervalSince1970: 1_781_154_000))

        let sessionLimit = try XCTUnwrap(metrics.sessionLimit)
        let weeklyLimit = try XCTUnwrap(metrics.weeklyLimit)
        let modelLimit = try XCTUnwrap(metrics.codeReviewLimit)
        XCTAssertEqual(sessionLimit.percentage, 13, accuracy: 0.01)
        XCTAssertEqual(weeklyLimit.percentage, 23, accuracy: 0.01)
        XCTAssertEqual(modelLimit.percentage, 32, accuracy: 0.01)
        XCTAssertEqual(metrics.modelLimitLabel, "Fable")
    }

    func testParsesResetAcrossYearRollover() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 12,
            day: 31,
            hour: 12
        )))
        let metrics = try ClaudeCodeCLIUsageParser.parseMetrics(
            from: "Current session: 10% used · resets Jan 2 at 6pm",
            now: now
        )
        let reset = try XCTUnwrap(metrics.sessionLimit?.resetTime)

        XCTAssertEqual(calendar.component(.year, from: reset), 2027)
        XCTAssertEqual(calendar.component(.month, from: reset), 1)
        XCTAssertEqual(calendar.component(.day, from: reset), 2)
    }

    func testStripsANSICodesBeforeParsing() throws {
        let output = "\u{001B}[31mCurrent session: 42% used · resets Jul 24 at 6pm\u{001B}[0m"

        let metrics = try ClaudeCodeCLIUsageParser.parseMetrics(from: output)

        XCTAssertEqual(metrics.sessionLimit?.percentage, 42)
    }

    func testClampsPercentAndIgnoresWindowWithoutPercent() throws {
        let output = """
        Current session: 105% used · resets Jul 24 at 6pm
        Current week (all models): usage unavailable
        """

        let metrics = try ClaudeCodeCLIUsageParser.parseMetrics(from: output)

        XCTAssertEqual(metrics.sessionLimit?.percentage, 100)
        XCTAssertNil(metrics.weeklyLimit)
    }

    func testKeepsCompleteWindowWhenCaptureEndsMidPercent() throws {
        let output = """
        Current session: 42% used · resets Jul 24 at 6pm
        Current week (all models): 9
        """

        let metrics = try ClaudeCodeCLIUsageParser.parseMetrics(from: output)

        XCTAssertEqual(metrics.sessionLimit?.percentage, 42)
        XCTAssertNil(metrics.weeklyLimit)
    }

    func testThrowsWhenNoUsageWindowsArePresent() {
        XCTAssertThrowsError(try ClaudeCodeCLIUsageParser.parseMetrics(from: "No usage data"))
    }

    /// Headless (non-TTY) spawns of `claude /usage` no longer render the usage
    /// screen — the CLI prints a session cost summary instead. The parser must
    /// recognise that shape and throw a legible, actionable error rather than a
    /// vague "No Claude usage windows found."
    func testDetectsCostSummaryInsteadOfUsageScreen() {
        let output = """
        Total cost:            $0.0000
        Total duration (API):  0s
        Total duration (wall): 1.2s
        Total code changes:    0 lines added, 0 lines removed
        Usage by model:
            claude-opus:  0 input, 0 output
        """

        XCTAssertThrowsError(try ClaudeCodeCLIUsageParser.parseMetrics(from: output)) { error in
            guard case let ClaudeCodeCLIUsageError.parsingFailed(message) = error else {
                return XCTFail("Expected parsingFailed, got \(error)")
            }
            XCTAssertTrue(
                message.lowercased().contains("cost summary"),
                "Message should call out the cost-summary shape, got: \(message)")
        }
    }
}
