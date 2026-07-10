import XCTest
import MeterBarShared
@testable import MeterBar

/// Crossing matrix + gate coverage for the pure notification decision extracted
/// from `AppDelegate.checkAndNotify`.
final class NotificationDeciderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Band fixtures (chosen so QuotaBand.forLimit lands where we want)

    /// 90% left → healthy.
    private func healthyLimit() -> UsageLimit { UsageLimit(used: 10, total: 100, resetTime: nil) }
    /// 20% left → tight.
    private func tightLimit() -> UsageLimit { UsageLimit(used: 80, total: 100, resetTime: nil) }
    /// 5% left → critical.
    private func criticalLimit() -> UsageLimit { UsageLimit(used: 95, total: 100, resetTime: nil) }
    /// 0% left → exhausted.
    private func exhaustedLimit() -> UsageLimit { UsageLimit(used: 100, total: 100, resetTime: nil) }

    private func metrics(
        service: ServiceType = .claudeCode,
        session: UsageLimit? = nil,
        weekly: UsageLimit? = nil,
        codeReview: UsageLimit? = nil,
        extraUsage: ExtraUsageStatus? = nil,
        lastUpdated: Date? = nil
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: session,
            weeklyLimit: weekly,
            codeReviewLimit: codeReview,
            extraUsage: extraUsage,
            lastUpdated: lastUpdated ?? now
        )
    }

    private func decider(_ preferences: NotificationPreferences = .default) -> NotificationDecider {
        NotificationDecider(preferences: preferences)
    }

    // MARK: - Rising

    func testWarningFiresOnRiseIntoCriticalBand() {
        let result = decider().evaluate(
            metrics: metrics(session: criticalLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 1)
        let fired = result.notifications[0]
        XCTAssertEqual(fired.level, .warning)
        XCTAssertEqual(fired.key, "Claude Code-session-warn")
        XCTAssertEqual(fired.serviceDisplayName, "Claude Code")
        XCTAssertEqual(fired.quotaDisplayName, "Session")
        XCTAssertTrue(fired.blocksProvider)
        XCTAssertEqual(fired.percentUsed, 95)
        XCTAssertEqual(fired.title, "Claude Code Session Usage Warning")
        XCTAssertTrue(result.notifiedKeys.contains("Claude Code-session-warn"))
    }

    func testCriticalFiresAndPreservesWarningState() {
        // Already warned; usage climbs into the exhausted band.
        let result = decider().evaluate(
            metrics: metrics(session: exhaustedLimit()),
            providerEnabled: true,
            alreadyNotified: ["Claude Code-session-warn"],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 1)
        XCTAssertEqual(result.notifications[0].level, .critical)
        XCTAssertEqual(result.notifications[0].key, "Claude Code-session-critical")
        // Preserve the warning key so a later recovery into the warning band
        // cannot look like a new upward crossing.
        XCTAssertTrue(result.notifiedKeys.contains("Claude Code-session-warn"))
        XCTAssertTrue(result.notifiedKeys.contains("Claude Code-session-critical"))
    }

    // MARK: - Repeat (dedup)

    func testWarningDoesNotRepeatWhileStillInBand() {
        let result = decider().evaluate(
            metrics: metrics(session: criticalLimit()),
            providerEnabled: true,
            alreadyNotified: ["Claude Code-session-warn"],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertEqual(result.notifiedKeys, ["Claude Code-session-warn"])
    }

    func testCriticalDoesNotRepeatWhileExhausted() {
        let result = decider().evaluate(
            metrics: metrics(session: exhaustedLimit()),
            providerEnabled: true,
            alreadyNotified: ["Claude Code-session-critical"],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertEqual(result.notifiedKeys, ["Claude Code-session-warn", "Claude Code-session-critical"])
    }

    // MARK: - Falling

    func testFallingBelowThresholdsClearsKeys() {
        let result = decider().evaluate(
            metrics: metrics(session: healthyLimit()),
            providerEnabled: true,
            alreadyNotified: ["Claude Code-session-warn", "Claude Code-session-critical"],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertTrue(result.notifiedKeys.isEmpty, "Recovered quota should reset so the next crossing re-notifies.")
    }

    func testTightBandClearsUnderDefaultThresholds() {
        // Default warning threshold is .critical, so the .tight band does not warn.
        let result = decider().evaluate(
            metrics: metrics(session: tightLimit()),
            providerEnabled: true,
            alreadyNotified: ["Claude Code-session-warn"],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertFalse(result.notifiedKeys.contains("Claude Code-session-warn"))
    }

    func testRecoveryFromExhaustedIntoWarningBandDoesNotFire() {
        let result = decider().evaluate(
            metrics: metrics(session: criticalLimit()),
            providerEnabled: true,
            alreadyNotified: ["Claude Code-session-warn", "Claude Code-session-critical"],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertEqual(result.notifiedKeys, ["Claude Code-session-warn"])
    }

    // MARK: - Threshold change

    func testThresholdChangeWarnsEarlierAtTight() {
        let prefs = NotificationPreferences(warningThreshold: .tight, criticalThreshold: .exhausted)
        let result = decider(prefs).evaluate(
            metrics: metrics(session: tightLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 1)
        XCTAssertEqual(result.notifications[0].level, .warning)
    }

    func testCriticalThresholdLoweredToCriticalBandFiresAlert() {
        let prefs = NotificationPreferences(warningThreshold: .tight, criticalThreshold: .critical)
        let result = decider(prefs).evaluate(
            metrics: metrics(session: criticalLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 1)
        XCTAssertEqual(
            result.notifications[0].level,
            .critical,
            "At the critical threshold the critical band should alert, not warn."
        )
        XCTAssertFalse(result.notifications[0].isExhausted)
        XCTAssertEqual(result.notifications[0].title, "Claude Code Session Usage Alert")
        XCTAssertFalse(result.notifications[0].body.lowercased().contains("reached"))
    }

    // MARK: - Gates

    func testGlobalDisableSuppressesEverything() {
        let prefs = NotificationPreferences(isEnabled: false)
        let result = decider(prefs).evaluate(
            metrics: metrics(session: exhaustedLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertEqual(result.notifiedKeys, ["Claude Code-session-warn", "Claude Code-session-critical"])
    }

    func testDisabledProviderNeverNotifies() {
        let result = decider().evaluate(
            metrics: metrics(session: exhaustedLimit()),
            providerEnabled: false,
            alreadyNotified: [],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertEqual(result.notifiedKeys, ["Claude Code-session-warn", "Claude Code-session-critical"])
    }

    func testStaleDataNeverNotifies() {
        let stale = metrics(session: exhaustedLimit(), lastUpdated: now.addingTimeInterval(-7_200))
        let result = decider().evaluate(
            metrics: stale,
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty, "A two-hour-old cache must not fire alerts.")
        XCTAssertEqual(result.notifiedKeys, ["Claude Code-session-warn", "Claude Code-session-critical"])
    }

    func testDisabledRecoveryRearmsNextEnabledCrossing() {
        let recoveredWhileDisabled = decider().evaluate(
            metrics: metrics(session: healthyLimit()),
            providerEnabled: false,
            alreadyNotified: ["Claude Code-session-warn", "Claude Code-session-critical"],
            now: now
        )
        XCTAssertTrue(recoveredWhileDisabled.notifiedKeys.isEmpty)

        let nextCrossing = decider().evaluate(
            metrics: metrics(session: criticalLimit()),
            providerEnabled: true,
            alreadyNotified: recoveredWhileDisabled.notifiedKeys,
            now: now
        )
        XCTAssertEqual(nextCrossing.notifications.map(\.level), [.warning])
    }

    func testStaleRecoveryRearmsNextFreshCrossing() {
        let staleRecovery = decider().evaluate(
            metrics: metrics(
                session: healthyLimit(),
                lastUpdated: now.addingTimeInterval(-NotificationDecider.defaultStalenessThreshold - 1)
            ),
            providerEnabled: true,
            alreadyNotified: ["Claude Code-session-warn"],
            now: now
        )
        XCTAssertTrue(staleRecovery.notifications.isEmpty)
        XCTAssertTrue(staleRecovery.notifiedKeys.isEmpty)

        let nextCrossing = decider().evaluate(
            metrics: metrics(session: criticalLimit()),
            providerEnabled: true,
            alreadyNotified: staleRecovery.notifiedKeys,
            now: now
        )
        XCTAssertEqual(nextCrossing.notifications.map(\.level), [.warning])
    }

    func testMissingLimitClearsPreviousBandState() {
        let result = decider().evaluate(
            metrics: metrics(session: nil),
            providerEnabled: false,
            alreadyNotified: ["Claude Code-session-warn", "Claude Code-session-critical"],
            now: now
        )

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertTrue(result.notifiedKeys.isEmpty)
    }

    func testExhaustedCriticalCopyClaimsLimitReached() {
        let result = decider().evaluate(
            metrics: metrics(session: exhaustedLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        let fired = result.notifications[0]
        XCTAssertTrue(fired.isExhausted)
        XCTAssertTrue(fired.blocksProvider)
        XCTAssertEqual(fired.title, "Claude Code Session Limit Reached")
        XCTAssertTrue(fired.body.contains("reached"))
    }

    func testClaudeSecondaryExhaustionNamesSonnetWithoutBlockingProvider() {
        let result = decider().evaluate(
            metrics: metrics(session: healthyLimit(), codeReview: exhaustedLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        let fired = result.notifications[0]
        XCTAssertEqual(fired.key, "Claude Code-codeReview-critical")
        XCTAssertEqual(fired.quotaDisplayName, "Sonnet")
        XCTAssertFalse(fired.blocksProvider)
        XCTAssertEqual(fired.title, "Claude Code Sonnet Quota Exhausted")
        XCTAssertTrue(fired.body.contains("does not block all Claude Code usage"))
    }

    func testCodexSecondaryExhaustionNamesCodeReviewWithoutBlockingProvider() {
        let result = decider().evaluate(
            metrics: metrics(service: .codexCli, session: healthyLimit(), codeReview: exhaustedLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        let fired = result.notifications[0]
        XCTAssertEqual(fired.key, "Codex CLI-codeReview-critical")
        XCTAssertEqual(fired.quotaDisplayName, "Code Review")
        XCTAssertFalse(fired.blocksProvider)
        XCTAssertEqual(fired.title, "OpenAI Codex Code Review Quota Exhausted")
        XCTAssertTrue(fired.body.contains("does not block all OpenAI Codex usage"))
    }

    func testExtraUsageKeepsExhaustedPrimaryQuotaNonblocking() {
        let result = decider().evaluate(
            metrics: metrics(
                service: .codexCli,
                session: exhaustedLimit(),
                extraUsage: ExtraUsageStatus(state: .on)
            ),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        let fired = result.notifications[0]
        XCTAssertEqual(fired.key, "Codex CLI-session-critical")
        XCTAssertFalse(fired.blocksProvider)
        XCTAssertEqual(fired.title, "OpenAI Codex Session Quota Exhausted")
        XCTAssertTrue(fired.body.contains("does not block all OpenAI Codex usage"))
    }

    func testDataAtStalenessBoundaryStillNotifies() {
        let edge = metrics(
            session: exhaustedLimit(),
            lastUpdated: now.addingTimeInterval(-NotificationDecider.defaultStalenessThreshold)
        )
        let result = decider().evaluate(
            metrics: edge,
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 1, "Data exactly at the staleness edge is still fresh enough.")
    }

    // MARK: - Multiple limits

    func testLimitsEvaluatedIndependently() {
        let result = decider().evaluate(
            metrics: metrics(session: exhaustedLimit(), weekly: healthyLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 1)
        XCTAssertEqual(result.notifications[0].key, "Claude Code-session-critical")
        XCTAssertFalse(result.notifiedKeys.contains { $0.hasPrefix("Claude Code-weekly") })
    }

    func testSimultaneouslyExhaustedLimitsProduceDistinguishableBanners() {
        let result = decider().evaluate(
            metrics: metrics(session: exhaustedLimit(), codeReview: exhaustedLimit()),
            providerEnabled: true,
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 2)
        XCTAssertEqual(Set(result.notifications.map(\.title)), [
            "Claude Code Session Limit Reached",
            "Claude Code Sonnet Quota Exhausted"
        ])
        XCTAssertEqual(Set(result.notifications.map(\.key)), [
            "Claude Code-session-critical",
            "Claude Code-codeReview-critical"
        ])
    }
}
