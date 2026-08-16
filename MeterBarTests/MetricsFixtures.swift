import Foundation
import MeterBarShared
@testable import MeterBar

/// Deterministic `UsageMetrics` fixtures for every `ServiceType`, shared across
/// the service-layer tests (SharedDataStore round-trip, UsageDataManager
/// orchestration) and the widget-rendering checks. All timestamps are fixed so
/// nothing depends on wall-clock time. Adding a provider is a compile error in
/// `metrics(for:)` until a fixture is declared.
enum MetricsFixtures {
    /// A stable reference instant used for every reset/last-updated field.
    static let referenceDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

    /// One populated metric for `service`. Exhaustive so a new `ServiceType`
    /// cannot join the matrix without a fixture.
    static func metrics(for service: ServiceType) -> UsageMetrics {
        switch service {
        case .claudeCode: return claudeCode()
        case .codexCli: return codexCli()
        case .cursor: return cursor()
        case .openRouter: return openRouter()
        case .grok: return grok()
        }
    }

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

    static func grok(weeklyUsedPercent: Double = 64) -> UsageMetrics {
        UsageMetrics(
            service: .grok,
            weeklyLimit: UsageLimit(
                used: weeklyUsedPercent,
                total: 100,
                resetTime: referenceDate.addingTimeInterval(7 * 24 * 3_600),
                windowSeconds: 7 * 24 * 3_600
            ),
            extraUsage: ExtraUsageStatus(state: .on, detail: "$10.00 credits"),
            resetCreditsAvailable: 1,
            lastUpdated: referenceDate
        )
    }

    /// OpenRouter: key-limit + account-credits, matching production mapping.
    static func openRouter(
        keyUsed: Double = 12.8,
        keyTotal: Double = 40,
        creditsUsed: Double = 42,
        creditsTotal: Double = 100
    ) -> UsageMetrics {
        UsageMetrics(
            service: .openRouter,
            sessionLimit: UsageLimit(
                used: keyUsed,
                total: keyTotal,
                resetTime: referenceDate.addingTimeInterval(18 * 24 * 3_600),
                windowSeconds: 30 * 24 * 3_600
            ),
            weeklyLimit: UsageLimit(
                used: creditsUsed,
                total: creditsTotal,
                resetTime: nil
            ),
            lastUpdated: referenceDate
        )
    }

    /// One populated metric per `ServiceType`. Adding a case without a
    /// `metrics(for:)` fixture is a compile error; omitting it from this map
    /// is a parity-test failure.
    static func allProviders() -> [ServiceType: UsageMetrics] {
        Dictionary(uniqueKeysWithValues: ServiceType.allCases.map { service in
            (service, metrics(for: service))
        })
    }
}
