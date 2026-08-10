import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// `meterbar refresh --timeout` is resolved in the core rather than by
/// ArgumentParser's `Double` conversion, so a malformed value still produces a
/// versioned JSON document and one of the exit codes `docs/cli-json-schema.md`
/// promises (0/10/11/12/13/130) instead of a bare usage message and 64.
final class RefreshCLITimeoutTests: XCTestCase {
    func testMissingValueResolvesToTheDocumentedDefault() throws {
        XCTAssertEqual(try resolve(nil), UsageRefreshCLI.defaultTimeout)
    }

    func testWellFormedValuesResolveAndToleratePadding() throws {
        XCTAssertEqual(try resolve("30"), 30)
        XCTAssertEqual(try resolve(" 45 "), 45)
        XCTAssertEqual(try resolve("\(Int(UsageRefreshCLI.minimumTimeout))"), UsageRefreshCLI.minimumTimeout)
        XCTAssertEqual(try resolve("\(Int(UsageRefreshCLI.maximumTimeout))"), UsageRefreshCLI.maximumTimeout)
    }

    func testMalformedOrOutOfRangeValuesFailWithAStableCodeNamingTheInput() {
        for raw in ["abc", "", "   ", "0", "0.5", "601", "-1", "nan", "inf"] {
            let failure = expectFailure(raw)
            XCTAssertEqual(failure.code, "invalid_timeout", raw)
            XCTAssertEqual(failure.flag, "--timeout", raw)
            XCTAssertEqual(failure.value, raw.trimmingCharacters(in: .whitespacesAndNewlines), raw)
            XCTAssertTrue(failure.message.contains("--timeout"), failure.message)
        }
    }

    // MARK: - JSON contract

    func testAnInvalidTimeoutStillEmitsAVersionedDocumentAndADocumentedExitCode() throws {
        let failure = expectFailure("abc")
        let response = RefreshCLIResponse(
            failure: failure,
            collectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            cachedMetrics: [:]
        )

        XCTAssertEqual(response.outcome, .refreshFailed)
        XCTAssertEqual(response.outcome.exitCode, 13)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["outcome"] as? String, "refreshFailed")
        XCTAssertNotNil(object["message"])

        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_timeout")
        XCTAssertEqual(error["flag"] as? String, "--timeout")
        XCTAssertEqual(error["value"] as? String, "abc")
        XCTAssertEqual(error["message"] as? String, response.message)
    }

    func testASuccessfulRefreshCarriesNoErrorObject() throws {
        let now = Date()
        let response = RefreshCLIResponse(
            outcome: .success,
            collectedAt: now,
            durationSeconds: 0,
            outcomes: [ProviderRefreshOutcome(provider: .cursor, state: .refreshed, lastUpdated: now)],
            cachedMetrics: [:]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )
        XCTAssertNil(object["error"])
    }

    // MARK: - Request wiring

    func testRawTextRequestsCarryTheTextUnparsedSoTheCoreCanReportTheFailure() {
        XCTAssertEqual(UsageRefreshCLI.Request(timeoutText: "abc").timeout, .text("abc"))
        XCTAssertEqual(UsageRefreshCLI.Request(timeoutText: nil).timeout, .text(nil))
        XCTAssertEqual(UsageRefreshCLI.Request(timeout: 20).timeout, .resolved(20))
    }

    // MARK: - Helpers

    private func resolve(_ raw: String?) throws -> TimeInterval {
        switch RefreshTimeout.resolve(raw) {
        case let .success(value):
            return value
        case let .failure(failure):
            throw XCTSkip("unexpected failure: \(failure.message)")
        }
    }

    private func expectFailure(
        _ raw: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> RefreshCLIFailure {
        switch RefreshTimeout.resolve(raw) {
        case let .success(value):
            XCTFail("expected \(raw ?? "nil") to fail, resolved to \(value)", file: file, line: line)
            return RefreshCLIFailure(code: "", message: "", flag: nil, value: nil)
        case let .failure(failure):
            return failure
        }
    }
}
