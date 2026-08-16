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
        let grok = GrokAccount(
            id: UUID(uuidString: "C3D4E5F6-A7B8-4901-8234-567890ABCDEF")!,
            name: "Grok Work",
            homeDirectory: "/secret/grok-home"
        )
        let metrics = Dictionary(uniqueKeysWithValues: QuotaEventSnapshotCatalog.flatProviders.map {
            ($0, usage(service: $0, used: 50))
        })

        let snapshots = QuotaEventSnapshotCatalog.snapshots(
            metrics: metrics,
            accounts: QuotaEventAccountInputs(
                claudeAccounts: [claude],
                claudeAccountMetrics: [claude.id: usage(service: .claudeCode, used: 50)],
                codexAccounts: [codex],
                codexAccountMetrics: [codex.id: usage(service: .codexCli, used: 50)],
                grokAccounts: [grok],
                grokAccountMetrics: [grok.id: usage(service: .grok, used: 50)]
            ),
            enabledServices: Set(ServiceType.allCases)
        )

        XCTAssertFalse(QuotaEventSnapshotCatalog.flatProviders.contains(.grok))
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
        XCTAssertEqual(
            snapshots.first { $0.provider == .grok }?.account,
            QuotaEventAccount(id: grok.id.uuidString, name: grok.name)
        )
        let encoded = try? JSONEncoder().encode(snapshots.map(\.account))
        let text = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("configDirectory"))
        XCTAssertFalse(text.contains("homeDirectory"))
        XCTAssertFalse(text.contains("GROK_HOME"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
    }

    func testCatalogExposesEachEnabledGrokProfileAsAStableSelectableAccount() {
        let work = GrokAccount(
            id: UUID(uuidString: "C3D4E5F6-A7B8-4901-8234-567890ABCDEF")!,
            name: "Work",
            homeDirectory: "/secret/grok-work"
        )
        var personal = GrokAccount.defaultAccount
        personal.name = "Personal"
        var disabled = GrokAccount(
            id: UUID(uuidString: "D4E5F6A7-B8C9-4012-9345-67890ABCDEF0")!,
            name: "Disabled",
            homeDirectory: "/secret/grok-disabled"
        )
        disabled.isEnabled = false

        let selectable = QuotaEventSnapshotCatalog.selectableAccounts(
            claudeAccounts: [],
            codexAccounts: [],
            grokAccounts: [personal, work, disabled]
        )
        let grok = selectable.filter { $0.provider == .grok }

        XCTAssertEqual(grok.map(\.accountID), [personal.id.uuidString, work.id.uuidString])
        XCTAssertEqual(Set(grok.map(\.name)), ["Personal", "Work"])
        XCTAssertEqual(
            grok.map(\.selection),
            [
                QuotaEventAccountSelection(provider: .grok, accountID: personal.id.uuidString),
                QuotaEventAccountSelection(provider: .grok, accountID: work.id.uuidString),
            ]
        )
        XCTAssertFalse(grok.contains { $0.accountID == disabled.id.uuidString })
        XCTAssertFalse(grok.contains { $0.accountID == "default" })
        XCTAssertFalse(selectable.contains { $0.provider == .grok && $0.name == ServiceType.grok.displayName })
        XCTAssertFalse(QuotaEventSnapshotCatalog.flatProviders.contains(.grok))
    }

    func testCatalogEvaluatesEnabledGrokProfilesIndependentlyAndOmitsDisabledOnes() {
        let work = GrokAccount(
            id: UUID(uuidString: "C3D4E5F6-A7B8-4901-8234-567890ABCDEF")!,
            name: "Work",
            homeDirectory: "/secret/grok-work"
        )
        var disabled = GrokAccount(
            id: UUID(uuidString: "D4E5F6A7-B8C9-4012-9345-67890ABCDEF0")!,
            name: "Disabled",
            homeDirectory: "/secret/grok-disabled"
        )
        disabled.isEnabled = false
        let snapshots = QuotaEventSnapshotCatalog.snapshots(
            metrics: [.grok: usage(service: .grok, used: 10)],
            accounts: QuotaEventAccountInputs(
                grokAccounts: [.defaultAccount, work, disabled],
                grokAccountMetrics: [
                    GrokAccount.defaultID: usage(service: .grok, used: 50),
                    work.id: usage(service: .grok, used: 91),
                    disabled.id: usage(service: .grok, used: 100),
                ]
            ),
            enabledServices: [.grok]
        )

        XCTAssertEqual(snapshots.map(\.provider), [.grok, .grok])
        XCTAssertEqual(
            Set(snapshots.map(\.account)),
            [
                QuotaEventAccount(id: GrokAccount.defaultID.uuidString, name: GrokAccount.defaultName),
                QuotaEventAccount(id: work.id.uuidString, name: work.name),
            ]
        )
        XCTAssertEqual(
            snapshots.first { $0.account.id == work.id.uuidString }?.metrics.sessionLimit?.used,
            91
        )
        XCTAssertFalse(snapshots.contains { $0.account.id == "default" })
        XCTAssertFalse(snapshots.contains { $0.account.id == disabled.id.uuidString })
    }

    func testLegacyProviderWideGrokSnapshotDoesNotCoexistWithAccountSnapshots() {
        let snapshots = QuotaEventSnapshotCatalog.snapshots(
            metrics: [.grok: usage(service: .grok, used: 76)],
            accounts: QuotaEventAccountInputs(
                grokAccounts: [.defaultAccount],
                grokAccountMetrics: [GrokAccount.defaultID: usage(service: .grok, used: 76)]
            ),
            enabledServices: [.grok]
        )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.provider, .grok)
        XCTAssertEqual(snapshots.first?.account.id, GrokAccount.defaultID.uuidString)
        XCTAssertEqual(snapshots.first?.account.name, GrokAccount.defaultName)
        XCTAssertFalse(QuotaEventSnapshotCatalog.flatProviders.contains(.grok))
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
            accounts: QuotaEventAccountInputs(claudeAccounts: [one]),
            enabledServices: [.claudeCode]
        )
        let ambiguous = QuotaEventSnapshotCatalog.snapshots(
            metrics: [.claudeCode: fallback],
            accounts: QuotaEventAccountInputs(claudeAccounts: [one, second]),
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

    func testServiceEvaluatesGrokProfilesIndependentlyAndMigratesLegacyDefaultWithoutDuplicateDelivery() async {
        var delivered: [QuotaEventPayload] = []
        let engine = QuotaEventDeliveryEngine(handlers: QuotaEventDeliveryHandlers(
            local: { payload, _ in
                delivered.append(payload)
                return .succeeded
            },
            webhook: { _, _ in .succeeded }
        ))
        let service = QuotaEventService(
            planner: QuotaEventPlanner(debounceInterval: 0),
            deliveryEngine: engine
        )
        let work = GrokAccount(
            id: UUID(uuidString: "C3D4E5F6-A7B8-4901-8234-567890ABCDEF")!,
            name: "Work",
            homeDirectory: "/secret/grok-work"
        )
        let defaultAccount = QuotaEventAccount(
            id: GrokAccount.defaultID.uuidString,
            name: GrokAccount.defaultName
        )
        let workAccount = QuotaEventAccount(id: work.id.uuidString, name: work.name)
        let configuration = QuotaEventIntegrationConfiguration(
            localDeliveryEnabled: true,
            localExecutablePath: "/usr/bin/true",
            localArguments: [],
            webhookDeliveryEnabled: false,
            webhookURLString: "",
            enabledQuotaEvents: [.warning, .critical, .exhausted, .recovered],
            enabledProviders: [.grok],
            enabledAccounts: [
                QuotaEventAccountSelection(provider: .grok, accountID: "default"),
                QuotaEventAccountSelection(provider: .grok, accountID: defaultAccount.id),
                QuotaEventAccountSelection(provider: .grok, accountID: workAccount.id),
            ],
            enabledWakeEvents: []
        )

        let primed = await service.observe(
            snapshots: [
                QuotaEventSnapshot(
                    provider: .grok,
                    account: QuotaEventAccount(id: "default", name: "Grok"),
                    metrics: usage(service: .grok, used: 50)
                ),
            ],
            configuration: configuration,
            now: now
        )
        delivered.removeAll()
        let migratedSameBand = await service.observe(
            snapshots: [
                QuotaEventSnapshot(provider: .grok, account: defaultAccount, metrics: usage(service: .grok, used: 50)),
                QuotaEventSnapshot(provider: .grok, account: workAccount, metrics: usage(service: .grok, used: 50)),
            ],
            configuration: configuration,
            now: now.addingTimeInterval(1)
        )
        let crossed = await service.observe(
            snapshots: [
                QuotaEventSnapshot(provider: .grok, account: defaultAccount, metrics: usage(service: .grok, used: 91)),
                QuotaEventSnapshot(provider: .grok, account: workAccount, metrics: usage(service: .grok, used: 76)),
            ],
            configuration: configuration,
            now: now.addingTimeInterval(2)
        )

        XCTAssertTrue(primed.events.isEmpty)
        XCTAssertTrue(migratedSameBand.events.isEmpty)
        XCTAssertEqual(Set(crossed.events.map(\.account)), [defaultAccount, workAccount])
        XCTAssertEqual(
            crossed.events.first { $0.account == defaultAccount }?.event,
            .critical
        )
        XCTAssertEqual(
            crossed.events.first { $0.account == workAccount }?.event,
            .warning
        )
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(Set(delivered.map(\.account.id)), [defaultAccount.id, workAccount.id])
        XCTAssertFalse(delivered.contains { $0.account.id == "default" })
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
