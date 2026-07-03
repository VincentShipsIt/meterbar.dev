import Foundation
import MeterBarShared
@testable import MeterBar

/// Deterministic `UsageMetrics` fixtures for the three providers, shared across
/// the service-layer tests (SharedDataStore round-trip, UsageDataManager
/// orchestration) and the widget-rendering checks. All timestamps are fixed so
/// nothing depends on wall-clock time.
enum MetricsFixtures {
    /// A stable reference instant used for every reset/last-updated field.
    static let referenceDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

    static func claudeCode(
        sessionUsedPercent: Double = 42.5,
        weeklyUsedPercent: Double = 12
    ) -> UsageMetrics {
        UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(
                used: sessionUsedPercent,
                total: 100,
                resetTime: referenceDate,
                windowSeconds: 5 * 3_600
            ),
            weeklyLimit: UsageLimit(
                used: weeklyUsedPercent,
                total: 100,
                resetTime: referenceDate.addingTimeInterval(7 * 24 * 3_600),
                windowSeconds: 7 * 24 * 3_600
            ),
            extraUsage: ExtraUsageStatus(state: .on, detail: "$0.00 used"),
            lastUpdated: referenceDate
        )
    }

    static func codexCli(
        sessionUsedPercent: Double = 30,
        weeklyUsedPercent: Double = 55,
        codeReviewUsedPercent: Double = 5,
        resetCreditsAvailable: Int? = 2
    ) -> UsageMetrics {
        UsageMetrics(
            service: .codexCli,
            sessionLimit: UsageLimit(
                used: sessionUsedPercent,
                total: 100,
                resetTime: referenceDate,
                windowSeconds: 5 * 3_600
            ),
            weeklyLimit: UsageLimit(
                used: weeklyUsedPercent,
                total: 100,
                resetTime: referenceDate.addingTimeInterval(7 * 24 * 3_600),
                windowSeconds: 7 * 24 * 3_600
            ),
            codeReviewLimit: UsageLimit(
                used: codeReviewUsedPercent,
                total: 100,
                resetTime: referenceDate.addingTimeInterval(7 * 24 * 3_600),
                windowSeconds: 7 * 24 * 3_600
            ),
            extraUsage: ExtraUsageStatus(state: .off, detail: nil),
            resetCreditsAvailable: resetCreditsAvailable,
            lastUpdated: referenceDate
        )
    }

    static func cursor(
        planUsed: Double = 137,
        planTotal: Double = 500,
        onDemandUsed: Double = 3.5,
        onDemandTotal: Double = 20
    ) -> UsageMetrics {
        UsageMetrics(
            service: .cursor,
            sessionLimit: UsageLimit(
                used: onDemandUsed,
                total: onDemandTotal,
                resetTime: referenceDate
            ),
            weeklyLimit: UsageLimit(
                used: planUsed,
                total: planTotal,
                resetTime: referenceDate
            ),
            lastUpdated: referenceDate
        )
    }

    /// One populated metric per provider, keyed by `ServiceType`.
    static func allProviders() -> [ServiceType: UsageMetrics] {
        [
            .claudeCode: claudeCode(),
            .codexCli: codexCli(),
            .cursor: cursor()
        ]
    }
}
