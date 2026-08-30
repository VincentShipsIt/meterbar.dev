import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class AccountFailoverDecisionTests: XCTestCase {
    private let preferred = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10))
    private let fallbackA = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11))
    private let fallbackB = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12))

    func testFeatureDisabledNeverSwitches() {
        XCTAssertEqual(
            decide(
                enabled: false,
                active: preferred,
                availability: [preferred: .depleted, fallbackA: .available]
            ),
            .stay(.featureDisabled)
        )
    }

    func testAvailabilityRejectsCachedMetricsWithoutCurrentRefreshSuccess() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 100, total: 100, resetTime: nil)
        )

        XCTAssertEqual(
            AccountFailoverAvailability(
                provider: .claudeCode,
                metrics: metrics,
                refreshedSuccessfully: false
            ),
            .unknown
        )
    }

    func testAvailabilityRejectsEstimatedPrimaryLimit() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 100, total: 100, resetTime: nil, isEstimated: true)
        )

        XCTAssertEqual(
            AccountFailoverAvailability(
                provider: .claudeCode,
                metrics: metrics,
                refreshedSuccessfully: true
            ),
            .unknown
        )
    }

    func testCodexWeeklyOnlyPrimaryWindowCanBeDepleted() {
        let metrics = UsageMetrics(
            service: .codexCli,
            weeklyLimit: UsageLimit(
                used: 100,
                total: 100,
                resetTime: nil,
                periodKind: .weekly
            )
        )

        XCTAssertEqual(
            AccountFailoverAvailability(
                provider: .codexCli,
                metrics: metrics,
                refreshedSuccessfully: true
            ),
            .depleted
        )
    }

    func testDepletedPreferredSwitchesToFirstAvailableFallbackInConfiguredOrder() {
        XCTAssertEqual(
            decide(
                active: preferred,
                availability: [preferred: .depleted, fallbackA: .available, fallbackB: .available]
            ),
            .switchAccount(from: preferred, to: fallbackA, reason: .activeAccountDepleted)
        )
    }

    func testDepletedFallbackAdvancesWithoutReturningToStillDepletedPreferred() {
        XCTAssertEqual(
            decide(
                active: fallbackA,
                availability: [preferred: .depleted, fallbackA: .depleted, fallbackB: .available]
            ),
            .switchAccount(from: fallbackA, to: fallbackB, reason: .activeAccountDepleted)
        )
    }

    func testAllAccountsDepletedStaysOnCurrentAccount() {
        XCTAssertEqual(
            decide(
                active: fallbackA,
                availability: [preferred: .depleted, fallbackA: .depleted, fallbackB: .depleted]
            ),
            .stay(.allAccountsDepleted)
        )
    }

    func testPreferredResetSwitchesBackFromFallback() {
        XCTAssertEqual(
            decide(
                active: fallbackB,
                availability: [preferred: .available, fallbackA: .depleted, fallbackB: .available]
            ),
            .switchAccount(from: fallbackB, to: preferred, reason: .preferredAccountRecovered)
        )
    }

    func testUnknownFallbackIsNotSelected() {
        XCTAssertEqual(
            decide(
                active: preferred,
                availability: [preferred: .depleted, fallbackA: .unknown, fallbackB: .available]
            ),
            .switchAccount(from: preferred, to: fallbackB, reason: .activeAccountDepleted)
        )
    }

    func testAvailableActiveAccountDoesNotSwitchSideways() {
        XCTAssertEqual(
            decide(
                active: fallbackA,
                availability: [preferred: .depleted, fallbackA: .available, fallbackB: .available]
            ),
            .stay(.activeAccountAvailable)
        )
    }

    func testMissingActiveAccountFallsBackToPreferredIdentityWithoutCredentialMutation() {
        XCTAssertEqual(
            AccountFailoverDecisionEngine.decide(
                AccountFailoverDecisionInput(
                    isEnabled: true,
                    orderedAccountIDs: [preferred, fallbackA],
                    activeAccountID: UUID(),
                    availability: [preferred: .available, fallbackA: .available]
                )
            ),
            .adopt(preferred, reason: .activeAccountUnavailable)
        )
    }

    private func decide(
        enabled: Bool = true,
        active: UUID,
        availability: [UUID: AccountFailoverAvailability]
    ) -> AccountFailoverDecision {
        AccountFailoverDecisionEngine.decide(
            AccountFailoverDecisionInput(
                isEnabled: enabled,
                orderedAccountIDs: [preferred, fallbackA, fallbackB],
                activeAccountID: active,
                availability: availability
            )
        )
    }
}
