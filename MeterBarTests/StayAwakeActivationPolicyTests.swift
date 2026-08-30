import MeterBarShared
import XCTest
@testable import MeterBar

final class StayAwakeActivationPolicyTests: XCTestCase {
    func testManualModeOffNeverEngages() {
        let decision = StayAwakeActivationPolicy.decision(
            isManuallyEnabled: false,
            snapshots: [snapshot(.claudeCode, used: 20)]
        )

        XCTAssertEqual(decision, .inactive)
    }

    func testManualModeEngagesForEnabledProviderWithSessionQuotaRemaining() {
        let decision = StayAwakeActivationPolicy.decision(
            isManuallyEnabled: true,
            snapshots: [snapshot(.codexCli, used: 40)]
        )

        XCTAssertEqual(decision, .active(provider: .codexCli))
    }

    func testDisabledProviderCannotHoldAssertion() {
        let decision = StayAwakeActivationPolicy.decision(
            isManuallyEnabled: true,
            snapshots: [snapshot(.claudeCode, used: 20, isProviderEnabled: false)]
        )

        XCTAssertEqual(decision, .inactive)
    }

    func testDepletedSessionReleasesAssertion() {
        let decision = StayAwakeActivationPolicy.decision(
            isManuallyEnabled: true,
            snapshots: [snapshot(.claudeCode, used: 100)]
        )

        XCTAssertEqual(decision, .inactive)
    }

    func testMissingSessionWindowCannotHoldAssertion() {
        let decision = StayAwakeActivationPolicy.decision(
            isManuallyEnabled: true,
            snapshots: [
                StayAwakeUsageSnapshot(
                    provider: .grok,
                    isProviderEnabled: true,
                    sessionUsedPercentage: nil
                ),
            ]
        )

        XCTAssertEqual(decision, .inactive)
    }

    func testOpenRouterKeyCapIsNotTreatedAsAnAgentSession() {
        let decision = StayAwakeActivationPolicy.decision(
            isManuallyEnabled: true,
            snapshots: [snapshot(.openRouter, used: 20)]
        )

        XCTAssertEqual(decision, .inactive)
    }

    func testStableProviderOrderSelectsFirstEligibleSession() {
        let decision = StayAwakeActivationPolicy.decision(
            isManuallyEnabled: true,
            snapshots: [
                snapshot(.cursor, used: 10),
                snapshot(.codexCli, used: 30),
                snapshot(.claudeCode, used: 100),
            ]
        )

        XCTAssertEqual(decision, .active(provider: .codexCli))
    }

    func testUsageMetricsProjectionIncludesProviderEnablementAndSessionPercentage() {
        let snapshots = StayAwakeUsageSnapshot.make(
            metrics: [
                .claudeCode: MetricsFixtures.claudeCode(sessionUsedPercent: 45),
                .codexCli: MetricsFixtures.codexCli(sessionUsedPercent: 25),
            ],
            enabledServices: [.codexCli]
        )

        XCTAssertEqual(
            snapshots,
            [
                StayAwakeUsageSnapshot(
                    provider: .claudeCode,
                    isProviderEnabled: false,
                    sessionUsedPercentage: 45
                ),
                StayAwakeUsageSnapshot(
                    provider: .codexCli,
                    isProviderEnabled: true,
                    sessionUsedPercentage: 25
                ),
            ]
        )
    }

    private func snapshot(
        _ provider: ServiceType,
        used: Double,
        isProviderEnabled: Bool = true
    ) -> StayAwakeUsageSnapshot {
        StayAwakeUsageSnapshot(
            provider: provider,
            isProviderEnabled: isProviderEnabled,
            sessionUsedPercentage: used
        )
    }
}
