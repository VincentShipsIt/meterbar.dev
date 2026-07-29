import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class QuotaEventServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCatalogCoversEveryEnabledFlatProviderAndEveryAccountWithoutPaths() {
        let claude = ClaudeCodeAccount(
            id: UUID(uuidString: "45B5BB1D-2994-44B5-9374-54760DCBE901")!,
            name: "Claude Work",
            configDirectory: "/secret/claude-profile"
        )
        let codex = CodexAccount(
            id: UUID(uuidString: "AB45485C-7C78-4E71-A238-A2EED2C97DC5")!,
            name: "Codex Work",
            homeDirectory: "/secret/codex-home"
        )
        let metrics = Dictionary(uniqueKeysWithValues: QuotaEventSnapshotCatalog.flatProviders.map {
            ($0, usage(service: $0, used: 50))
        })

        let snapshots = QuotaEventSnapshotCatalog.snapshots(
            metrics: metrics,
            claudeAccounts: [claude],
            claudeAccountMetrics: [claude.id: usage(service: .claudeCode, used: 50)],
            codexAccounts: [codex],
            codexAccountMetrics: [codex.id: usage(service: .codexCli, used: 50)],
            enabledServices: Set(ServiceType.allCases)
        )

        XCTAssertEqual(snapshots.count, ServiceType.allCases.count)
        XCTAssertEqual(Set(snapshots.map(\.provider)), Set(ServiceType.allCases))
        XCTAssertEqual(
            snapshots.first { $0.provider == .claudeCode }?.account,
            QuotaEventAccount(id: claude.id.uuidString, name: claude.name)
        )
        XCTAssertEqual(
            snapshots.first { $0.provider == .codexCli }?.account,
            QuotaEventAccount(id: codex.id.uuidString, name: codex.name)
        )
        let encoded = try? JSONEncoder().encode(snapshots.map(\.account))
        let text = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("configDirectory"))
        XCTAssertFalse(text.contains("homeDirectory"))
    }

    func testCatalogUsesAggregateFallbackOnlyWhenOneEnabledAccountOwnsIt() {
        let one = ClaudeCodeAccount.defaultAccount
        let second = ClaudeCodeAccount(
            id: UUID(uuidString: "45B5BB1D-2994-44B5-9374-54760DCBE901")!,
            name: "Work",
            configDirectory: nil
        )
        let fallback = usage(service: .claudeCode, used: 50)

        let single = QuotaEventSnapshotCatalog.snapshots(
            metrics: [.claudeCode: fallback],
            claudeAccounts: [one],
            claudeAccountMetrics: [:],
            codexAccounts: [],
            codexAccountMetrics: [:],
            enabledServices: [.claudeCode]
        )
        let ambiguous = QuotaEventSnapshotCatalog.snapshots(
            metrics: [.claudeCode: fallback],
            claudeAccounts: [one, second],
            claudeAccountMetrics: [:],
            codexAccounts: [],
            codexAccountMetrics: [:],
            enabledServices: [.claudeCode]
        )

        XCTAssertEqual(single.count, 1)
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testServiceSerializesTransitionPlanningAndFailureIsolatedDelivery() async {
        let engine = QuotaEventDeliveryEngine(handlers: QuotaEventDeliveryHandlers(
            local: { _, _ in .failed("Local hook timed out.") },
            webhook: { _, _ in .succeeded }
        ))
        let service = QuotaEventService(
            planner: QuotaEventPlanner(debounceInterval: 0),
            deliveryEngine: engine
        )
        let account = QuotaEventAccount(id: "default", name: "Cursor")
        let configuration = QuotaEventIntegrationConfiguration(
            localDeliveryEnabled: true,
            localExecutablePath: "/usr/bin/false",
            localArguments: [],
            webhookDeliveryEnabled: true,
            webhookURLString: "https://hooks.example.com/meterbar",
            enabledQuotaEvents: [.critical],
            enabledProviders: [.cursor],
            enabledAccounts: [.init(provider: .cursor, accountID: account.id)],
            enabledWakeEvents: []
        )

        let primed = await service.observe(
            snapshots: [snapshot(account: account, used: 50)],
            configuration: configuration,
            now: now
        )
        let crossed = await service.observe(
            snapshots: [snapshot(account: account, used: 91)],
            configuration: configuration,
            now: now.addingTimeInterval(1)
        )

        XCTAssertTrue(primed.events.isEmpty)
        XCTAssertEqual(crossed.events.map(\.event), [.critical])
        XCTAssertEqual(crossed.diagnostics.count, 2)
        XCTAssertEqual(crossed.diagnostics.filter(\.succeeded).count, 1)
    }

    private func snapshot(account: QuotaEventAccount, used: Double) -> QuotaEventSnapshot {
        QuotaEventSnapshot(
            provider: .cursor,
            account: account,
            metrics: usage(service: .cursor, used: used)
        )
    }

    private func usage(service: ServiceType, used: Double) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: UsageLimit(
                used: used,
                total: 100,
                resetTime: now.addingTimeInterval(3_600)
            ),
            lastUpdated: now
        )
    }
}
