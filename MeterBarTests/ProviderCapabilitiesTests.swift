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

    func testCanonicalFixtureCoversEveryServiceType() {
        let metrics = MetricsFixtures.allProviders()
        XCTAssertEqual(Set(metrics.keys), Set(ServiceType.allCases))
        for service in ServiceType.allCases {
            let metric = try? XCTUnwrap(metrics[service], "\(service) missing from MetricsFixtures")
            XCTAssertEqual(metric?.service, service)
            XCTAssertEqual(metric?.hasData, true, "\(service) fixture must render a supported state")
        }
    }

    func testPopoverAndDashboardRowsCoverEveryProvider() {
        let metrics = MetricsFixtures.allProviders()
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: metrics,
                claudeAccounts: [.defaultAccount],
                claudeAccountMetrics: [:],
                enabledServices: Set(ServiceType.allCases)
            )
        )
        XCTAssertEqual(Set(snapshots.map(\.service)), Set(ServiceType.allCases))
        for snapshot in snapshots {
            XCTAssertTrue(snapshot.hasMetrics, "\(snapshot.service) popover/dashboard row has no metrics")
            XCTAssertFalse(snapshot.limits.isEmpty, "\(snapshot.service) popover/dashboard row is empty")
        }
    }

    func testEveryWidgetFamilyRendersEveryProvider() {
        let metrics = MetricsFixtures.allProviders()
        for service in ServiceType.allCases {
            let providerMetrics = try? XCTUnwrap(metrics[service])
            for family in WidgetPresentationFamily.allCases {
                let presentation = WidgetPresentationPlanner.makePresentation(
                    metrics: providerMetrics.map { [service: $0] } ?? [:],
                    accountMetrics: [],
                    preferences: .defaults,
                    family: family,
                    now: MetricsFixtures.referenceDate
                )
                XCTAssertEqual(
                    presentation.rows.map(\.service),
                    [service],
                    "\(family) dropped \(service)"
                )
                XCTAssertNil(presentation.emptyState, "\(family) \(service)")
                XCTAssertFalse(
                    presentation.rows.first?.accessibilityValueText.isEmpty ?? true,
                    "\(family) \(service) has no spoken value"
                )
            }
        }
    }

    func testCLIAndServeEmitEveryProvider() throws {
        let metrics = MetricsFixtures.allProviders()
        let cli = try UsageCLIJSONResponse(metrics: metrics).jsonString()
        for service in ServiceType.allCases {
            XCTAssertTrue(
                cli.contains("\"provider\" : \"\(service.cliIdentifier)\""),
                "CLI JSON omitted \(service.cliIdentifier)"
            )
            XCTAssertTrue(cli.contains(service.displayName), "CLI JSON omitted \(service.displayName)")
        }

        let serve = ServeRouter.handle(
            ServeHTTPRequest(
                method: "GET",
                path: "/usage",
                query: [:],
                authorizationHeader: "Bearer fixture-token"
            ),
            token: "fixture-token",
            dataSource: ServeRouter.DataSource(
                loadUsageMetrics: { metrics },
                loadCostCache: { nil }
            )
        )
        XCTAssertEqual(serve.status, 200)
        XCTAssertEqual(serve.body, try UsageCLIJSONResponse(metrics: metrics).jsonData())
    }

    func testNotificationsAndEventsCoverEveryProvider() {
        let coveredNotifications = Set(UsageNotificationCoordinator.flatNotificationServices)
            .union(ServiceType.allCases.filter(\.hasAccountScopedNotifications))
        XCTAssertEqual(coveredNotifications, Set(ServiceType.allCases))

        let decider = NotificationDecider(preferences: .default)
        for service in ServiceType.allCases {
            let evaluation = decider.evaluate(
                metrics: UsageMetrics(
                    service: service,
                    weeklyLimit: UsageLimit(used: 95, total: 100, resetTime: nil),
                    lastUpdated: MetricsFixtures.referenceDate
                ),
                providerEnabled: true,
                alreadyNotified: [],
                now: MetricsFixtures.referenceDate
            )
            XCTAssertFalse(
                evaluation.notifications.isEmpty,
                "\(service) produced no notification from a critical weekly window"
            )
        }

        let events = QuotaEventSnapshotCatalog.snapshots(
            metrics: MetricsFixtures.allProviders(),
            accounts: QuotaEventAccountInputs(
                claudeAccounts: [.defaultAccount],
                claudeAccountMetrics: [ClaudeCodeAccount.defaultID: MetricsFixtures.claudeCode()],
                codexAccounts: [.defaultAccount],
                codexAccountMetrics: [CodexAccount.defaultID: MetricsFixtures.codexCli()],
                grokAccounts: [.defaultAccount],
                grokAccountMetrics: [GrokAccount.defaultID: MetricsFixtures.grok()]
            ),
            enabledServices: Set(ServiceType.allCases)
        )
        XCTAssertEqual(Set(events.map(\.provider)), Set(ServiceType.allCases))
    }

    func testDiagnosticsCoverEveryProvider() {
        let errors = DiagnosticsRunner.refreshErrors(
            claudeDefaultAccountEnabled: true,
            claudeError: .apiError("claude"),
            codexError: .apiError("codex"),
            cursorError: .apiError("cursor"),
            openRouterError: .apiError("openrouter"),
            grokError: .apiError("grok")
        )
        XCTAssertEqual(Set(errors.keys), Set(ServiceType.allCases))
    }

    func testAccessibilityCoversEveryProvider() {
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: MetricsFixtures.allProviders(),
                claudeAccounts: [.defaultAccount],
                claudeAccountMetrics: [:],
                enabledServices: Set(ServiceType.allCases)
            )
        )
        XCTAssertEqual(Set(snapshots.map(\.service)), Set(ServiceType.allCases))
        for snapshot in snapshots {
            XCTAssertFalse(snapshot.accessibilityLabel.isEmpty, "\(snapshot.service) label")
            XCTAssertFalse(snapshot.accessibilityValue.isEmpty, "\(snapshot.service) value")
            for limit in snapshot.limits {
                XCTAssertFalse(limit.accessibilityLabel.isEmpty, "\(snapshot.service) \(limit.id) label")
                XCTAssertFalse(limit.accessibilityValue.isEmpty, "\(snapshot.service) \(limit.id) value")
            }
        }
    }

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
