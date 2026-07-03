import XCTest
@testable import MeterBar

/// Redaction tests for the inspector's error sanitizer — the layer that keeps
/// `meterbar doctor` / Diagnostics output safe to paste into a public issue.
final class ProviderReadinessInspectorTests: XCTestCase {
    func testApiErrorDropsResponseBodyKeepsStatusCode() {
        let raw = ServiceError.apiError("HTTP 500: {\"user\":\"vincent@genfeed.ai\",\"token\":\"sk-SECRET\"}")
        let sanitized = ProviderReadinessInspector.sanitize(raw)

        XCTAssertEqual(sanitized, "API error (HTTP 500)")
        XCTAssertFalse(sanitized?.contains("SECRET") ?? false)
        XCTAssertFalse(sanitized?.contains("vincent@genfeed.ai") ?? false)
    }

    func testApiErrorWithoutStatusIsGeneric() {
        let sanitized = ProviderReadinessInspector.sanitize(.apiError("Bearer sk-SECRET leaked here"))

        XCTAssertEqual(sanitized, "API error")
        XCTAssertFalse(sanitized?.contains("SECRET") ?? false)
    }

    func testSafeNetworkMessagesPassThrough() {
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.apiError("No internet connection")), "No internet connection")
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.apiError("Request timed out")), "Request timed out")
    }

    func testKnownCasesMapToStableStrings() {
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.notAuthenticated), "Not authenticated")
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.parsingError), "Could not parse the provider response")
        XCTAssertNil(ProviderReadinessInspector.sanitize(nil))
    }

    func testHttpStatusExtraction() {
        XCTAssertEqual(ProviderReadinessInspector.httpStatus(in: "HTTP 404: not found"), 404)
        XCTAssertNil(ProviderReadinessInspector.httpStatus(in: "no status here"))
    }
}
