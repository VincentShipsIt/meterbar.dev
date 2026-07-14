@testable import MeterBar
import MeterBarShared
import SwiftUI
import XCTest

/// Covers the centralized per-provider fact derivation that replaced the ~7
/// `switch service` helpers previously scattered through SettingsView. Pure
/// value-in / value-out, so no live services are needed.
@MainActor
final class ProviderSettingsFactsTests: XCTestCase {
    // MARK: - Helpers

    private func facts(
        service: ServiceType,
        isEnabled: Bool = true,
        hasAccess: Bool = true,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        errorText: String? = nil,
        updatedText: String = "Updated just now",
        worstBand: QuotaBand? = nil,
        codexAuthFileDisplayPath: String = "~/.codex/auth.json"
    ) -> ProviderSettingsFacts {
        ProviderSettingsFacts(
            service: service,
            isEnabled: isEnabled,
            hasAccess: hasAccess,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            errorText: errorText,
            updatedText: updatedText,
            worstBand: worstBand,
            codexAuthFileDisplayPath: codexAuthFileDisplayPath
        )
    }

    // MARK: - sourceText

    func testSourceTextPerProvider() {
        XCTAssertEqual(facts(service: .claudeCode).sourceText, "Claude CLI /usage")
        XCTAssertEqual(
            facts(service: .codexCli, codexAuthFileDisplayPath: "~/work/auth.json").sourceText,
            "~/work/auth.json + ChatGPT usage API"
        )
        XCTAssertEqual(facts(service: .cursor).sourceText, "Cursor local state + usage API")
        XCTAssertEqual(facts(service: .openRouter).sourceText, "OpenRouter credits + key APIs")
    }

    // MARK: - planText

    func testClaudePlanJoinsPlanAndTier() {
        let f = facts(service: .claudeCode, subscriptionType: "max", rateLimitTier: "custom_tier")
        XCTAssertEqual(f.planText, "Max · Custom Tier")
    }

    func testClaudePlanWithOnlyPlan() {
        XCTAssertEqual(facts(service: .claudeCode, subscriptionType: "max").planText, "Max")
    }

    func testClaudePlanWithOnlyTier() {
        XCTAssertEqual(facts(service: .claudeCode, rateLimitTier: "default_tier").planText, "Default Tier")
    }

    func testClaudePlanNilWhenNeither() {
        XCTAssertNil(facts(service: .claudeCode).planText)
    }

    func testCodexAndCursorCapitalizePlan() {
        XCTAssertEqual(facts(service: .codexCli, subscriptionType: "pro").planText, "Pro")
        XCTAssertEqual(facts(service: .cursor, subscriptionType: "business").planText, "Business")
        XCTAssertNil(facts(service: .codexCli).planText)
        XCTAssertNil(facts(service: .cursor).planText)
    }

    func testOpenRouterNeverReportsPlan() {
        // Even if a subscription token leaked in, OpenRouter has no plan row.
        XCTAssertNil(facts(service: .openRouter, subscriptionType: "team").planText)
    }

    // MARK: - statusText

    func testStatusTextDisabledWins() {
        let f = facts(service: .claudeCode, isEnabled: false, hasAccess: true, worstBand: .healthy)
        XCTAssertEqual(f.statusText, "Disabled")
    }

    func testStatusTextNotConnected() {
        XCTAssertEqual(facts(service: .cursor, hasAccess: false).statusText, "Not connected")
    }

    func testStatusTextRefreshFailedBeatsBand() {
        let f = facts(service: .codexCli, errorText: "boom", worstBand: .healthy)
        XCTAssertEqual(f.statusText, "Refresh failed")
    }

    func testStatusTextUsesWorstBandLabel() {
        XCTAssertEqual(facts(service: .claudeCode, worstBand: .tight).statusText, QuotaBand.tight.shortLabel)
        XCTAssertEqual(facts(service: .claudeCode, worstBand: .exhausted).statusText, QuotaBand.exhausted.shortLabel)
    }

    func testStatusTextWaitingWhenNoBand() {
        XCTAssertEqual(facts(service: .openRouter).statusText, "Waiting for refresh")
    }

    // MARK: - statusColor

    func testStatusColorSecondaryUntilEnabledAndConnected() {
        XCTAssertEqual(facts(service: .claudeCode, isEnabled: false).statusColor, .secondary)
        XCTAssertEqual(facts(service: .claudeCode, hasAccess: false).statusColor, .secondary)
    }

    func testStatusColorWarningOnError() {
        XCTAssertEqual(facts(service: .codexCli, errorText: "boom").statusColor, MeterBarTheme.warning)
    }

    func testStatusColorFollowsBand() {
        XCTAssertEqual(facts(service: .claudeCode, worstBand: .exhausted).statusColor, QuotaBand.exhausted.color)
        XCTAssertEqual(facts(service: .claudeCode, worstBand: .healthy).statusColor, QuotaBand.healthy.color)
    }

    func testStatusColorSecondaryWithoutBand() {
        XCTAssertEqual(facts(service: .cursor).statusColor, .secondary)
    }

    // MARK: - QuotaBand.severity

    func testBandSeverityOrdering() {
        XCTAssertLessThan(QuotaBand.healthy.severity, QuotaBand.tight.severity)
        XCTAssertLessThan(QuotaBand.tight.severity, QuotaBand.critical.severity)
        XCTAssertLessThan(QuotaBand.critical.severity, QuotaBand.exhausted.severity)
    }

    func testWorstBandSelectionPicksHighestSeverity() {
        let bands: [QuotaBand] = [.healthy, .exhausted, .tight]
        let worst = bands.max(by: { $0.severity < $1.severity })
        XCTAssertEqual(worst, .exhausted)
    }
}
