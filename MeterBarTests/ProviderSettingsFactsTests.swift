@testable import MeterBar
import MeterBarShared
import XCTest

/// Unit coverage for the `ProviderSettingsFacts` derivation extracted from the
/// SettingsView monolith. The whole point of the value type is that every
/// displayed string/color is derived from plain primitives, so it is testable
/// without live provider services. Every case must cover `.grok`, which the
/// original (pre-Grok) split omitted.
final class ProviderSettingsFactsTests: XCTestCase {
    // MARK: - Helpers

    private func facts(
        service: ServiceType,
        isEnabled: Bool = true,
        hasAccess: Bool = true,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        errorText: String? = nil,
        worstBand: QuotaBand? = nil
    ) -> ProviderSettingsFacts {
        ProviderSettingsFacts(
            service: service,
            isEnabled: isEnabled,
            hasAccess: hasAccess,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            errorText: errorText,
            updatedText: "Updated just now",
            worstBand: worstBand,
            authNotice: nil,
            codexAuthFileDisplayPath: "~/.codex/auth.json"
        )
    }

    private func snapshot(notice: ProviderAuthNotice?) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "claude-\(UUID().uuidString)",
            title: "Claude",
            service: .claudeCode,
            updatedAt: Date(),
            limits: [
                SnapshotLimit(
                    id: "session",
                    kind: .session,
                    title: "Session",
                    usageLimit: UsageLimit(used: 30, total: 100, resetTime: nil)
                )
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil,
            authNotice: notice
        )
    }

    // MARK: - noticeText

    /// An authored parse failure knows the single step that fixes it, and the
    /// Overview notice is the only multi-line surface that can say it.
    func testNoticeAppendsRecoveryForAuthoredParseFailures() {
        let failure = ClaudeCodeParseFailure.headlessUsageUnavailable
        XCTAssertEqual(
            facts(service: .claudeCode, errorText: failure.message).noticeText,
            "\(failure.message). \(failure.recovery)"
        )
    }

    func testNoticeLeavesOtherErrorsUntouched() {
        XCTAssertEqual(facts(service: .grok, errorText: "HTTP 500").noticeText, "HTTP 500")
        XCTAssertNil(facts(service: .grok).noticeText)
    }

    // MARK: - sourceText (one branch per service, including Grok)

    func testSourceTextCoversEveryService() {
        XCTAssertEqual(facts(service: .claudeCode).sourceText, "Claude CLI /usage")
        XCTAssertEqual(facts(service: .codexCli).sourceText, "~/.codex/auth.json + ChatGPT usage API")
        XCTAssertEqual(facts(service: .cursor).sourceText, "Cursor local state + usage API")
        XCTAssertEqual(facts(service: .openRouter).sourceText, "OpenRouter credits + key APIs")
        XCTAssertEqual(facts(service: .grok).sourceText, "Grok Build ACP billing + usage reset API")
    }

    // MARK: - planText

    func testClaudePlanJoinsSubscriptionAndTier() {
        let derived = facts(
            service: .claudeCode,
            subscriptionType: "max",
            rateLimitTier: "default_max_20x"
        )
        XCTAssertEqual(derived.planText, "Max · Default Max 20X")
    }

    func testClaudePlanIsNilWhenNothingReported() {
        XCTAssertNil(facts(service: .claudeCode).planText)
    }

    func testCodexAndCursorCapitalizePlan() {
        XCTAssertEqual(facts(service: .codexCli, subscriptionType: "plus").planText, "Plus")
        XCTAssertEqual(facts(service: .cursor, subscriptionType: "pro").planText, "Pro")
    }

    func testOpenRouterHasNoPlan() {
        XCTAssertNil(facts(service: .openRouter, subscriptionType: "ignored").planText)
    }

    func testGrokPlanIsShownVerbatim() {
        // Grok's token is already human-facing, so it is not title-cased.
        XCTAssertEqual(facts(service: .grok, subscriptionType: "SuperGrok").planText, "SuperGrok")
        XCTAssertNil(facts(service: .grok, subscriptionType: "").planText)
    }

    // MARK: - statusText

    func testStatusTextDisabledBeatsEverything() {
        let derived = facts(service: .grok, isEnabled: false, hasAccess: true, worstBand: .critical)
        XCTAssertEqual(derived.statusText, "Disabled")
    }

    func testStatusTextNotConnectedWhenNoAccess() {
        XCTAssertEqual(facts(service: .cursor, hasAccess: false).statusText, "Not connected")
    }

    func testStatusTextRefreshFailedOnError() {
        let derived = facts(service: .codexCli, errorText: "boom", worstBand: .healthy)
        XCTAssertEqual(derived.statusText, "Refresh failed")
    }

    func testStatusTextUsesWorstBandLabel() {
        XCTAssertEqual(facts(service: .claudeCode, worstBand: .exhausted).statusText, "Out")
    }

    func testStatusTextAuthNoticeBeatsAHealthyBand() {
        var derived = facts(service: .cursor, worstBand: .healthy)
        derived.authNotice = .stale(since: Date())
        XCTAssertEqual(derived.statusText, "Stale")
        XCTAssertEqual(derived.statusColor, .secondary)
    }

    func testSharedNoticeRequiresEveryMeteredCardToAgree() {
        let stale = snapshot(notice: .stale(since: Date(timeIntervalSince1970: 1)))
        let attention = snapshot(notice: .attention("Work refresh failed"))
        XCTAssertNil(
            ProviderSettingsFacts.sharedNotice(in: [stale, attention]),
            "Distinct overlays must not collapse to whichever card comes first"
        )
    }

    func testSharedNoticeKeepsAnAgreedOverlay() {
        let first = snapshot(notice: .stale(since: Date(timeIntervalSince1970: 1)))
        let second = snapshot(notice: .stale(since: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(ProviderSettingsFacts.sharedNotice(in: [first, second])?.shortLabel, "Stale")
        XCTAssertEqual(ProviderSettingsFacts.sharedNotice(in: [first])?.shortLabel, "Stale")
    }

    func testSharedNoticeIsNilWhenASiblingHasNoOverlay() {
        let stale = snapshot(notice: .stale(since: Date()))
        let healthy = snapshot(notice: nil)
        XCTAssertNil(ProviderSettingsFacts.sharedNotice(in: [stale, healthy]))
    }

    func testStatusTextWaitingWhenConnectedButNoBand() {
        XCTAssertEqual(facts(service: .claudeCode).statusText, "Waiting for refresh")
    }

    // MARK: - statusColor

    func testStatusColorSecondaryUntilEnabledAndConnected() {
        XCTAssertEqual(facts(service: .grok, isEnabled: false).statusColor, .secondary)
        XCTAssertEqual(facts(service: .grok, hasAccess: false).statusColor, .secondary)
    }

    func testStatusColorWarningOnError() {
        XCTAssertEqual(facts(service: .grok, errorText: "boom").statusColor, MeterBarTheme.warning)
    }

    func testStatusColorFollowsWorstBand() {
        XCTAssertEqual(facts(service: .claudeCode, worstBand: .critical).statusColor, QuotaBand.critical.color)
    }
}
