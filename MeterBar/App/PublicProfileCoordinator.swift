import Combine
import Foundation
import MeterBarShared

/// Assembles the public-profile document from the live stores.
///
/// One place builds it, so the toggle, the reset button, the "what is
/// published" preview and the background sync all send the same bytes.
@MainActor
enum PublicProfileSource {
    static func currentDocument(now: Date = Date()) -> PublicProfileDocument {
        let visibility = ProviderVisibilityStore.shared
        let snapshots = ProviderSnapshotBuilder.snapshots(.live(
            stores: .init(
                dataManager: .shared,
                claudeAccounts: ClaudeCodeAccountStore.shared.accounts,
                codexAccounts: CodexAccountStore.shared.accounts,
                grokAccounts: GrokAccountStore.shared.accounts,
                openRouterAccounts: OpenRouterAccountStore.shared.accounts,
                enabledServices: visibility.enabledServices,
                claudeCodeService: .shared,
                codexCliService: .shared,
                cursorService: .shared,
                openRouterService: .shared,
                grokService: .shared
            ),
            parseHealth: ProviderParseHealthStore.shared.records
        ))
        var plans: [ServiceType: String] = [:]
        for service in ServiceType.allCases {
            if let plan = ProviderSettingsFacts.live(for: service, snapshots: []).subscriptionType {
                plans[service] = plan
            }
        }
        return PublicProfileDocument.make(
            snapshots: snapshots,
            plans: plans,
            costSummary: CostTracker.shared.costSummary?.filtered(to: visibility.enabledServices),
            now: now
        )
    }
}

/// Keeps a published profile live: after each refresh it hands the store a
/// fresh document, and the store decides whether the throttle lets it out.
/// Demo mode never publishes, because its numbers are synthetic.
@MainActor
final class PublicProfileCoordinator {
    static let shared = PublicProfileCoordinator()

    private let store: PublicProfileStore
    private let refreshEvents: AnyPublisher<Void, Never>
    private let document: @MainActor () -> PublicProfileDocument
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(
        store: PublicProfileStore? = nil,
        dataManager: UsageDataManager? = nil,
        costTracker: CostTracker? = nil,
        visibility: ProviderVisibilityStore? = nil,
        refreshEvents: AnyPublisher<Void, Never>? = nil,
        document: @escaping @MainActor () -> PublicProfileDocument = { PublicProfileSource.currentDocument() }
    ) {
        self.store = store ?? .shared
        self.refreshEvents = refreshEvents ?? Publishers.MergeMany(
            (dataManager ?? .shared).$refreshGeneration.map { _ in () }.eraseToAnyPublisher(),
            (costTracker ?? .shared).$costSummary.map { _ in () }.eraseToAnyPublisher(),
            (visibility ?? .shared).$hiddenServices.map { _ in () }.eraseToAnyPublisher()
        )
        .eraseToAnyPublisher()
        self.document = document
    }

    func start() {
        guard !started else { return }
        started = true

        refreshEvents
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.sync() }
            .store(in: &cancellables)

        Task { await store.resumePendingDeletions() }
    }

    private func sync() {
        Task {
            await store.resumePendingDeletions()
            guard store.isEnabled, store.canPublish else { return }
            await store.sync(document: document())
        }
    }
}
