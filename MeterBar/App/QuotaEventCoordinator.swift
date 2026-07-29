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
    private let providerVisibility: ProviderVisibilityStore
    private let settings: QuotaEventSettingsStore
    private let diagnostics: QuotaEventDiagnosticStore
    private let service: QuotaEventService

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(
        dataManager: UsageDataManager? = nil,
        claudeAccounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil,
        providerVisibility: ProviderVisibilityStore? = nil,
        settings: QuotaEventSettingsStore? = nil,
        diagnostics: QuotaEventDiagnosticStore? = nil,
        service: QuotaEventService = QuotaEventService()
    ) {
        self.dataManager = dataManager ?? .shared
        self.claudeAccounts = claudeAccounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
        self.providerVisibility = providerVisibility ?? .shared
        self.settings = settings ?? .shared
        self.diagnostics = diagnostics ?? .shared
        self.service = service
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
        ]

        Publishers.MergeMany(triggers)
            .sink { [weak self] in
                self?.evaluateCurrentSnapshot()
            }
            .store(in: &cancellables)

        evaluateCurrentSnapshot()
    }

    private func evaluateCurrentSnapshot() {
        let snapshots = QuotaEventSnapshotCatalog.snapshots(
            metrics: dataManager.metrics,
            claudeAccounts: claudeAccounts.accounts,
            claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
            codexAccounts: codexAccounts.accounts,
            codexAccountMetrics: dataManager.codexAccountMetrics,
            enabledServices: providerVisibility.enabledServices
        )
        let configuration = settings.configuration
        let service = service
        let diagnostics = diagnostics

        Task {
            let observation = await service.observe(
                snapshots: snapshots,
                configuration: configuration
            )
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
