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
        XCTAssertEqual(try XCTUnwrap(metrics.sessionLimit).percentage, 36, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(metrics.weeklyLimit).percentage, 100, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(metrics.codeReviewLimit).percentage, 83, accuracy: 0.01)
        XCTAssertNotNil(metrics.sessionLimit?.resetTime)
        XCTAssertNotNil(metrics.weeklyLimit?.resetTime)
        XCTAssertNotNil(metrics.codeReviewLimit?.resetTime)
    }

    func testParsesRemainingPercentAsUsedPercent() throws {
        let output = """
        Current session: 64% remaining · resets Jun 11 at 10:40am
        Current week (all models): 25% left · resets Jun 12 at 7am
        """

        let metrics = try ClaudeCodeCLIUsageParser.parseMetrics(
            from: output,
            now: Date(timeIntervalSince1970: 1_781_154_000))

        XCTAssertEqual(try XCTUnwrap(metrics.sessionLimit).percentage, 36, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(metrics.weeklyLimit).percentage, 75, accuracy: 0.01)
    }

    func testThrowsWhenNoUsageWindowsArePresent() {
        XCTAssertThrowsError(try ClaudeCodeCLIUsageParser.parseMetrics(from: "No usage data"))
    }
}
