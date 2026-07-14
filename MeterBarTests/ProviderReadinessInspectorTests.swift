import XCTest
import MeterBarShared
@testable import MeterBar

/// Redaction tests for the inspector's error sanitizer — the layer that keeps
/// `meterbar doctor` / Diagnostics output safe to paste into a public issue.
final class ProviderReadinessInspectorTests: XCTestCase {
    func testReportsGatherOnlyRequestedProvidersInStableOrder() {
        var gathered: [ServiceType] = []
        let reports = ProviderReadinessInspector.reports(
            providers: [.cursor, .codexCli],
            refreshErrors: [:],
            now: Date(timeIntervalSince1970: 1_000),
            claudeReport: { _, _ in
                gathered.append(.claudeCode)
                return self.report(for: .claudeCode)
            },
            codexReport: { _, _ in
                gathered.append(.codexCli)
                return self.report(for: .codexCli)
            },
            cursorReport: { _, _ in
                gathered.append(.cursor)
                return self.report(for: .cursor)
            }
        )

        XCTAssertEqual(gathered, [.codexCli, .cursor])
        XCTAssertEqual(reports.map(\.provider), [.codexCli, .cursor])
    }

    func testRecentClaudeUsageSkipsCredentialRead() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = UsageMetrics(service: .claudeCode, lastUpdated: now.addingTimeInterval(-60))
        var didReadCredentials = false

        _ = ProviderReadinessInspector.claudeReport(
            now: now,
            cachedMetrics: recent,
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertFalse(didReadCredentials)
    }

    func testStaleClaudeUsageFallsBackToCredentialRead() {
        let now = Date(timeIntervalSince1970: 100_000)
        let stale = UsageMetrics(
            service: .claudeCode,
            lastUpdated: now.addingTimeInterval(-ProviderReadinessInspector.recentUsageFetchWindow - 1)
        )
        var didReadCredentials = false

        _ = ProviderReadinessInspector.claudeReport(
            now: now,
            cachedMetrics: stale,
            isOAuthFallbackEnabled: { true },
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertTrue(didReadCredentials)
    }

    func testDisabledClaudeOAuthFallbackSkipsCredentialReadWithoutRecentUsage() {
        var didReadCredentials = false

        _ = ProviderReadinessInspector.claudeReport(
            cachedMetrics: nil,
            isOAuthFallbackEnabled: { false },
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertFalse(didReadCredentials)
    }

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
        XCTAssertEqual(
            ProviderReadinessInspector.sanitize(.apiError("Secure connection failed")),
            "Secure connection failed"
        )
    }

    func testKnownCasesMapToStableStrings() {
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.notAuthenticated), "Not authenticated")
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.parsingError), "Could not parse the provider response")
        XCTAssertNil(ProviderReadinessInspector.sanitize(nil))
    }

    func testParseHealthAddsImmediateFormatMismatchCheckWithStalenessThreshold() {
        let now = Date(timeIntervalSince1970: 40_000)
        let record = ProviderParseHealthRecord(
            provider: .codexCli,
            lastSuccess: now.addingTimeInterval(-60),
            lastAttempt: now,
            consecutiveFailures: 1,
            lastFailureWasShapeMismatch: true
        )

        let reports = ProviderReadinessInspector.reports(
            providers: [.codexCli],
            now: now,
            parseHealth: [.codexCli: record]
        )
        let check = reports.first?.check(ReadinessCheckID.parseHealth)

        XCTAssertEqual(check?.level, .fail)
        XCTAssertTrue(check?.detail.contains("format") ?? false)
        XCTAssertTrue(check?.detail.contains("2 hours") ?? false)
    }

    func testHttpStatusExtraction() {
        XCTAssertEqual(ProviderReadinessInspector.httpStatus(in: "HTTP 404: not found"), 404)
        XCTAssertNil(ProviderReadinessInspector.httpStatus(in: "no status here"))
    }

    private func report(for provider: ServiceType) -> ProviderReadiness {
        ProviderReadiness(
            provider: provider,
            checks: [ReadinessCheck(id: "test", title: "Test", level: .pass, detail: "Ready")]
        )
    }
}
