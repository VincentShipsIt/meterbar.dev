import Combine
import Foundation
import MeterBarShared
import os

/// Main-actor bridge from live app stores into the serialized quota event
/// service. Refresh commits are the primary trigger; account/provider changes
/// also reconcile planner namespaces so disabled or removed accounts re-prime
/// cleanly when they return.
@MainActor
final class QuotaEventCoordinator {
    static let shared = QuotaEventCoordinator()

    private let dataManager: UsageDataManager
    private let claudeAccounts: ClaudeCodeAccountStore
    private let codexAccounts: CodexAccountStore
    private let grokAccounts: GrokAccountStore
    private let openRouterKeys: OpenRouterAccountStore
    private let providerVisibility: ProviderVisibilityStore
    private let settings: QuotaEventSettingsStore
    private let diagnostics: QuotaEventDiagnosticStore
    private let observe: (
        [QuotaEventSnapshot],
        QuotaEventIntegrationConfiguration
    ) async -> QuotaEventObservation

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// Guards `evaluateCurrentSnapshot()` the same way
    /// `ICloudUsageAggregationCoordinator.syncTask` guards `requestSync()`
    /// (ICloudUsageAggregationCoordinator.swift:34,81,90-96): 15 merged
    /// publishers (`start()` below) can each fire while a prior evaluation's
    /// webhook POST — up to 10s (`QuotaWebhookClient`) — is still in flight,
    /// and every fire used to spawn its own bare `Task`. Internal (not
    /// private) so tests can observe it directly.
    var evaluationTask: Task<Void, Never>?

    init(
        dataManager: UsageDataManager? = nil,
        claudeAccounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil,
        grokAccounts: GrokAccountStore? = nil,
        openRouterKeys: OpenRouterAccountStore? = nil,
        providerVisibility: ProviderVisibilityStore? = nil,
        settings: QuotaEventSettingsStore? = nil,
        diagnostics: QuotaEventDiagnosticStore? = nil,
        service: QuotaEventService = QuotaEventService(),
        observe: (
            (
                [QuotaEventSnapshot],
                QuotaEventIntegrationConfiguration
            ) async -> QuotaEventObservation
        )? = nil
    ) {
        self.dataManager = dataManager ?? .shared
        self.claudeAccounts = claudeAccounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
        self.grokAccounts = grokAccounts ?? .shared
        self.openRouterKeys = openRouterKeys ?? .shared
        self.providerVisibility = providerVisibility ?? .shared
        self.settings = settings ?? .shared
        self.diagnostics = diagnostics ?? .shared
        // Defaults to the (persistent, planner-stateful) `service` passed or
        // constructed above; `observe` exists as a seam so tests can gate one
        // evaluation mid-flight without a real 10s webhook POST, mirroring
        // `ICloudUsageAggregationCoordinator`'s injectable `sync:` closure.
        self.observe = observe ?? { snapshots, configuration in
            await service.observe(snapshots: snapshots, configuration: configuration)
        }
    }

    func start() {
        guard !started else { return }
        started = true

        let triggers: [AnyPublisher<Void, Never>] = [
            dataManager.$refreshGeneration.map { _ in () }.eraseToAnyPublisher(),
            providerVisibility.$hiddenServices.map { _ in () }.eraseToAnyPublisher(),
            settings.$configuration.map { _ in () }.eraseToAnyPublisher(),
            claudeAccounts.$customAccounts.map { _ in () }.eraseToAnyPublisher(),
            claudeAccounts.$defaultAccountName.map { _ in () }.eraseToAnyPublisher(),
            claudeAccounts.$defaultAccountIsEnabled.map { _ in () }.eraseToAnyPublisher(),
            codexAccounts.$customAccounts.map { _ in () }.eraseToAnyPublisher(),
            codexAccounts.$defaultAccountName.map { _ in () }.eraseToAnyPublisher(),
            codexAccounts.$defaultAccountIsEnabled.map { _ in () }.eraseToAnyPublisher(),
            grokAccounts.$customAccounts.map { _ in () }.eraseToAnyPublisher(),
            grokAccounts.$defaultAccountName.map { _ in () }.eraseToAnyPublisher(),
            grokAccounts.$defaultAccountIsEnabled.map { _ in () }.eraseToAnyPublisher(),
            openRouterKeys.$customAccounts.map { _ in () }.eraseToAnyPublisher(),
            openRouterKeys.$defaultAccountName.map { _ in () }.eraseToAnyPublisher(),
            openRouterKeys.$defaultAccountIsEnabled.map { _ in () }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(triggers)
            .sink { [weak self] in
                self?.evaluateCurrentSnapshot()
            }
            .store(in: &cancellables)

        evaluateCurrentSnapshot()
    }

    private func evaluateCurrentSnapshot() {
        // See `evaluationTask`'s doc comment: without this, every one of the
        // 15 merged publishers firing while a delivery pass is still running
        // spawns its own bare Task, risking duplicate/overlapping delivery for
        // one crossing. This is the lowest-confidence part of issue #547 —
        // it depends on actual actor job ordering rather than a deterministic
        // sequence — so treat it as aligning with the sibling coordinator's
        // own precedent rather than as a proven bug.
        guard evaluationTask == nil else { return }

        let snapshots = QuotaEventSnapshotCatalog.snapshots(
            metrics: dataManager.metrics,
            accounts: QuotaEventAccountInputs(
                claudeAccounts: claudeAccounts.accounts,
                claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                codexAccounts: codexAccounts.accounts,
                codexAccountMetrics: dataManager.codexAccountMetrics,
                grokAccounts: grokAccounts.accounts,
                grokAccountMetrics: dataManager.grokAccountMetrics,
                openRouterAccounts: openRouterKeys.accounts,
                openRouterAccountMetrics: dataManager.openRouterAccountMetrics
            ),
            enabledServices: providerVisibility.enabledServices
        )
        let configuration = settings.configuration
        let observe = observe
        let diagnostics = diagnostics

        evaluationTask = Task { [weak self] in
            defer { self?.evaluationTask = nil }
            let observation = await observe(snapshots, configuration)
            guard !observation.diagnostics.isEmpty else { return }
            diagnostics.record(observation.diagnostics)
            for record in observation.diagnostics where !record.succeeded {
                let summary = "Quota event \(record.channel.rawValue) delivery failed for "
                    + "\(record.provider) \(record.event.rawValue)/\(record.window.rawValue): "
                    + record.message
                AppLog.app.error("\(summary, privacy: .public)")
            }
        }
    }
}
