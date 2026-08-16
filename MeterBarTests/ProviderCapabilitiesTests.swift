import MeterBarShared
import XCTest
@testable import MeterBar

/// Focused parity suite for the provider capability registry and the all-provider
/// demo/share fixtures. Adding a `ServiceType` case is a compile error in the
/// exhaustive capability switch, and these tests fail if capabilities or
/// fixtures are left undeclared.
final class ProviderCapabilitiesTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Registry

    func testEveryServiceTypeDeclaresCapabilities() {
        for service in ServiceType.allCases {
            _ = service.capabilities
            XCTAssertEqual(service.capabilities, ProviderCapabilities.of(service), "\(service)")
            XCTAssertEqual(service.hasLocalHistorySource, service.writesLocalTokenLogs, "\(service)")
        }
    }

    func testCurrentCapabilityTruth() {
        XCTAssertEqual(
            ServiceType.claudeCode.capabilities,
            ProviderCapabilities(
                isMultiAccount: true,
                supportsExtraUsage: true,
                supportsResetRedemption: false,
                supportsGuardConfigDirectory: true,
                supportsSessionWake: true,
                hasAccountScopedNotifications: true,
                hasAccountScopedQuotaEvents: true
            )
        )
        XCTAssertEqual(
            ServiceType.codexCli.capabilities,
            ProviderCapabilities(
                isMultiAccount: true,
                supportsExtraUsage: false,
                supportsResetRedemption: true,
                supportsGuardConfigDirectory: true,
                supportsSessionWake: true,
                hasAccountScopedNotifications: true,
                hasAccountScopedQuotaEvents: true
            )
        )
        XCTAssertEqual(
            ServiceType.grok.capabilities,
            ProviderCapabilities(
                isMultiAccount: true,
                supportsExtraUsage: true,
                supportsResetRedemption: true,
                supportsGuardConfigDirectory: true,
                supportsSessionWake: false,
                hasAccountScopedNotifications: true,
                hasAccountScopedQuotaEvents: true
            )
        )
        for service in [ServiceType.cursor, .openRouter] {
            XCTAssertEqual(
                service.capabilities,
                ProviderCapabilities(
                    isMultiAccount: false,
                    supportsExtraUsage: false,
                    supportsResetRedemption: false,
                    supportsGuardConfigDirectory: false,
                    supportsSessionWake: false,
                    hasAccountScopedNotifications: false,
                    hasAccountScopedQuotaEvents: false
                ),
                "\(service)"
            )
        }
    }

    func testSessionWakeIsAnExplicitExceptionForGrok() {
        XCTAssertTrue(ServiceType.grok.isMultiAccount)
        XCTAssertTrue(ServiceType.grok.writesLocalTokenLogs)
        XCTAssertTrue(ServiceType.grok.supportsGuardConfigDirectory)
        XCTAssertTrue(ServiceType.grok.hasAccountScopedNotifications)
        XCTAssertTrue(ServiceType.grok.hasAccountScopedQuotaEvents)
        XCTAssertFalse(ServiceType.grok.supportsSessionWake)
    }

    // MARK: - Generic list helpers

    func testFlatNotificationServicesAreExactlyThoseWithoutAccountScopedNotifications() {
        XCTAssertEqual(
            UsageNotificationCoordinator.flatNotificationServices,
            ServiceType.allCases.filter { !$0.hasAccountScopedNotifications }
        )
        XCTAssertFalse(UsageNotificationCoordinator.flatNotificationServices.contains(.claudeCode))
        XCTAssertFalse(UsageNotificationCoordinator.flatNotificationServices.contains(.codexCli))
        XCTAssertFalse(UsageNotificationCoordinator.flatNotificationServices.contains(.grok))
        XCTAssertTrue(UsageNotificationCoordinator.flatNotificationServices.contains(.cursor))
        XCTAssertTrue(UsageNotificationCoordinator.flatNotificationServices.contains(.openRouter))
    }

    func testFlatQuotaEventProvidersAreExactlyThoseWithoutAccountScopedQuotaEvents() {
        XCTAssertEqual(
            QuotaEventSnapshotCatalog.flatProviders,
            ServiceType.allCases.filter { !$0.hasAccountScopedQuotaEvents }
        )
        XCTAssertFalse(QuotaEventSnapshotCatalog.flatProviders.contains(.claudeCode))
        XCTAssertFalse(QuotaEventSnapshotCatalog.flatProviders.contains(.codexCli))
        XCTAssertFalse(QuotaEventSnapshotCatalog.flatProviders.contains(.grok))
    }

    func testGuardConfigDirectoryFollowsTheCapabilityFlag() {
        for service in ServiceType.allCases {
            XCTAssertEqual(
                service.supportsGuardConfigDirectory,
                service.capabilities.supportsGuardConfigDirectory,
                "\(service)"
            )
        }
        XCTAssertTrue(ServiceType.claudeCode.supportsGuardConfigDirectory)
        XCTAssertTrue(ServiceType.codexCli.supportsGuardConfigDirectory)
        XCTAssertTrue(ServiceType.grok.supportsGuardConfigDirectory)
        XCTAssertFalse(ServiceType.cursor.supportsGuardConfigDirectory)
        XCTAssertFalse(ServiceType.openRouter.supportsGuardConfigDirectory)
    }

    // MARK: - Demo fixtures

    func testDemoDataCoversEveryServiceType() {
        let metrics = DemoData.metrics(now: now)
        XCTAssertEqual(Set(metrics.keys), Set(ServiceType.allCases))
        for service in ServiceType.allCases {
            let metric = try? XCTUnwrap(metrics[service], "\(service) missing from DemoData")
            XCTAssertEqual(metric?.hasData, true, "\(service) demo must render a supported state")
            XCTAssertEqual(metric?.lastUpdated, now, "\(service)")
        }
    }

    func testDemoFixturesFollowDeclaredCapabilities() {
        let metrics = DemoData.metrics(now: now)
        for service in ServiceType.allCases {
            let metric = try? XCTUnwrap(metrics[service])
            if service.supportsExtraUsage {
                XCTAssertNotNil(metric?.extraUsage, "\(service) supports extra usage")
            }
            if service.supportsResetRedemption {
                XCTAssertNotNil(metric?.resetCreditsAvailable, "\(service) supports reset redemption")
            }
        }
        XCTAssertNil(metrics[.grok]?.sessionLimit, "do not invent a Grok session bar")
        XCTAssertNotNil(metrics[.grok]?.weeklyLimit)
        XCTAssertEqual(
            ServiceType.openRouter.sessionQuotaTitleKey(limitTotal: metrics[.openRouter]?.sessionLimit?.total),
            .keyLimit
        )
        XCTAssertEqual(
            ServiceType.openRouter.weeklyQuotaTitleKey(limitTotal: metrics[.openRouter]?.weeklyLimit?.total),
            .accountCredits
        )
    }

    func testDemoCostDataCoversEveryServiceType() {
        let summary = DemoData.costSummary(now: now)
        XCTAssertEqual(Set(summary.costs.map(\.provider)), Set(ServiceType.allCases))
        for cost in summary.costs where cost.provider.writesLocalTokenLogs {
            XCTAssertFalse(cost.modelBreakdowns.isEmpty, "\(cost.provider)")
            XCTAssertFalse(cost.originBreakdowns.isEmpty, "\(cost.provider)")
        }
    }

    // MARK: - Share provenance

    func testShareSourceLabelsIncludeEveryLocalLogProvider() {
        let labels = DashboardShareSection.enabledSourceLabels(for: Set(ServiceType.allCases))
        let expected = ServiceType.allCases.compactMap { service -> String? in
            guard service.writesLocalTokenLogs else { return nil }
            return DashboardShareSection.sourceLabel(for: service)
        }
        XCTAssertEqual(labels, expected)
        XCTAssertTrue(labels.contains("Grok JSONL"))
        XCTAssertFalse(labels.contains(where: { $0.localizedCaseInsensitiveContains("OpenRouter") }))
        XCTAssertEqual(
            DashboardShareSection.enabledSourceLabels(for: [.openRouter]),
            []
        )
        XCTAssertEqual(
            DashboardShareSection.enabledSourceLabels(for: [.grok]),
            ["Grok JSONL"]
        )
    }
}
