import Combine
import Foundation

/// App-lifecycle publisher for menu-bar-only sessions. It listens to the same
/// provider and cost refreshes the app already performs, then coalesces them to
/// a coarse cadence. Subscribing is local-only; the enabled guard runs before
/// quota identity reads and before the CloudKit-backed service.
@MainActor
final class ICloudUsageAggregationCoordinator {
    static let shared = ICloudUsageAggregationCoordinator(
        settings: .shared,
        refreshPublisher: UsageDataManager.shared.$refreshGeneration
            .map { _ in () }
            .eraseToAnyPublisher(),
        costPublisher: CostTracker.shared.$costSummary
            .map { _ in () }
            .eraseToAnyPublisher(),
        minimumInterval: 15 * 60,
        localSummary: { CostTracker.shared.costSummary },
        sync: { summary in
            await ICloudUsageAggregationService.shared.sync(localSummary: summary)
        }
    )

    private let settings: ICloudUsageSettingsStore
    private let refreshPublisher: AnyPublisher<Void, Never>
    private let costPublisher: AnyPublisher<Void, Never>
    private let minimumInterval: TimeInterval
    private let now: () -> Date
    private let localSummary: () -> CostSummary?
    private let sync: (CostSummary?) async -> Void

    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    private var lastStartedAt: Date?
    private var isActive = false

    init(
        settings: ICloudUsageSettingsStore,
        refreshPublisher: AnyPublisher<Void, Never>,
        costPublisher: AnyPublisher<Void, Never>,
        minimumInterval: TimeInterval,
        now: @escaping () -> Date = Date.init,
        localSummary: @escaping () -> CostSummary? = { nil },
        sync: @escaping (CostSummary?) async -> Void
    ) {
        self.settings = settings
        self.refreshPublisher = refreshPublisher
        self.costPublisher = costPublisher
        self.minimumInterval = minimumInterval
        self.now = now
        self.localSummary = localSummary
        self.sync = sync
    }

    func activate() {
        guard !isActive else { return }
        isActive = true

        settings.$isEnabled
            .sink { [weak self] enabled in
                Task { @MainActor in
                    guard let self else { return }
                    if enabled {
                        self.requestSync()
                    } else {
                        self.lastStartedAt = nil
                    }
                }
            }
            .store(in: &cancellables)

        Publishers.Merge(refreshPublisher, costPublisher)
            .sink { [weak self] _ in
                Task { @MainActor in self?.requestSync() }
            }
            .store(in: &cancellables)
    }

    private func requestSync() {
        guard settings.isEnabled, syncTask == nil else { return }
        let startedAt = now()
        if let lastStartedAt,
           startedAt.timeIntervalSince(lastStartedAt) < minimumInterval {
            return
        }
        lastStartedAt = startedAt
        let summary = localSummary()

        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if settings.isEnabled {
                await sync(summary)
            }
            syncTask = nil
        }
    }
}
