import MeterBarShared
import XCTest
@testable import MeterBar

/// Covers the path behind "why 'failed to parse response'?" — the Claude CLI
/// told MeterBar exactly what went wrong and how to fix it, and every layer
/// between the parser and Settings threw that sentence away.
final class ClaudeCodeParseFailureTests: XCTestCase {
    // MARK: - The closed failure set

    func testMessagesAreDistinctAndRoundTrip() {
        for failure in ClaudeCodeParseFailure.allCases {
            XCTAssertEqual(ClaudeCodeParseFailure(message: failure.message), failure)
            XCTAssertFalse(failure.recovery.isEmpty)
        }
        XCTAssertEqual(ClaudeCodeParseFailure.messages.count, ClaudeCodeParseFailure.allCases.count)
    }

    func testUnknownMessageDoesNotResolve() {
        XCTAssertNil(ClaudeCodeParseFailure(message: "Failed to parse response"))
    }

    // MARK: - Parser emits the authored constants

    func testCostSummaryOutputThrowsTheHeadlessFailure() {
        let output = """
        Total cost:            $0.0000
        Total duration (API):  0s
        Usage by model:
            claude-opus:  0 input, 0 output
        """

        XCTAssertThrowsError(try ClaudeCodeCLIUsageParser.parseMetrics(from: output)) { error in
            guard case let ClaudeCodeCLIUsageError.parsingFailed(message) = error else {
                return XCTFail("Expected parsingFailed, got \(error)")
            }
            XCTAssertEqual(ClaudeCodeParseFailure(message: message), .headlessUsageUnavailable)
        }
    }

    func testUnrecognisedOutputThrowsTheNoWindowsFailure() {
        XCTAssertThrowsError(try ClaudeCodeCLIUsageParser.parseMetrics(from: "No usage data")) { error in
            guard case let ClaudeCodeCLIUsageError.parsingFailed(message) = error else {
                return XCTFail("Expected parsingFailed, got \(error)")
            }
            XCTAssertEqual(ClaudeCodeParseFailure(message: message), .noUsageWindows)
        }
    }

    // MARK: - ServiceError carries the detail

    func testParsingErrorSurfacesItsDetail() {
        let detail = ClaudeCodeParseFailure.headlessUsageUnavailable.message
        XCTAssertEqual(ServiceError.parsingError(detail).localizedDescription, detail)
    }

    func testParsingErrorWithoutDetailKeepsTheGenericMessage() {
        XCTAssertEqual(ServiceError.parsingError(nil).localizedDescription, "Failed to parse response")
    }

    // MARK: - Sanitizers pass authored text and drop everything else

    /// The detail is only ever displayable because it is one of a closed set of
    /// strings MeterBar itself wrote. Anything else may be provider output and
    /// must collapse to the generic message, exactly as `.apiError` does.
    func testArbitraryParseDetailIsDiscarded() {
        let leaked = ServiceSupport.serviceError(from: ServiceError.parsingError("token=sk-ant-secret"))
        XCTAssertEqual(leaked.localizedDescription, "Failed to parse response")
    }

    func testAuthoredParseDetailSurvivesSanitising() {
        let detail = ClaudeCodeParseFailure.headlessUsageUnavailable.message
        let sanitized = ServiceSupport.serviceError(from: ServiceError.parsingError(detail))
        XCTAssertEqual(sanitized.localizedDescription, detail)
    }

    func testReadinessSanitizerKeepsAuthoredDetailOnly() {
        let detail = ClaudeCodeParseFailure.headlessUsageUnavailable.message
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.parsingError(detail)), detail)
        XCTAssertEqual(
            ProviderReadinessInspector.sanitize(.parsingError("HTTP 500 <body>")),
            "Could not parse the provider response"
        )
        XCTAssertEqual(
            ProviderReadinessInspector.sanitize(.parsingError(nil)),
            "Could not parse the provider response"
        )
    }

    // MARK: - CLI failure → app state

    func testHeadlessFailureReachesSettingsAsAnActionableMessage() {
        let error = ClaudeCodeCLIUsageError.parsingFailed(ClaudeCodeParseFailure.headlessUsageUnavailable.message)
        let mapped = ClaudeCodeCLIFailureMapping.serviceError(from: error)

        XCTAssertEqual(mapped.localizedDescription, ClaudeCodeParseFailure.headlessUsageUnavailable.message)
        XCTAssertNotEqual(mapped.localizedDescription, "Failed to parse response")
    }

    func testUnauthoredParseFailureStaysGeneric() {
        let error = ClaudeCodeCLIUsageError.parsingFailed("unexpected token '<' at line 4")
        XCTAssertEqual(ClaudeCodeCLIFailureMapping.serviceError(from: error).localizedDescription,
                       "Failed to parse response")
    }

    /// A headless CLI cannot render `/usage` at all, so refreshing again will
    /// keep failing until the user connects OAuth. That is `needsLogin`, not a
    /// nondescript error the user is invited to retry forever.
    func testHeadlessFailureAsksForLoginRatherThanRetry() {
        let error = ClaudeCodeCLIUsageError.parsingFailed(ClaudeCodeParseFailure.headlessUsageUnavailable.message)
        XCTAssertEqual(ClaudeCodeCLIFailureMapping.authState(from: error), .needsLogin)
    }

    func testOtherParseFailuresRemainErrors() {
        let error = ClaudeCodeCLIUsageError.parsingFailed(ClaudeCodeParseFailure.noUsageWindows.message)
        guard case .error = ClaudeCodeCLIFailureMapping.authState(from: error) else {
            return XCTFail("Expected .error for a non-headless parse failure")
        }
    }

    func testExistingMappingsAreUnchanged() {
        guard case .notAuthenticated = ClaudeCodeCLIFailureMapping.serviceError(from: ClaudeCodeCLIUsageError.cliNotFound) else {
            return XCTFail("Expected a missing CLI to keep mapping to .notAuthenticated")
        }
        XCTAssertEqual(ClaudeCodeCLIFailureMapping.authState(from: ClaudeCodeCLIUsageError.cliNotFound),
                       .unavailable)
        XCTAssertEqual(ClaudeCodeCLIFailureMapping.authState(from: ClaudeCodeCLIUsageError.commandFailed("please login")),
                       .needsLogin)
    }
}
