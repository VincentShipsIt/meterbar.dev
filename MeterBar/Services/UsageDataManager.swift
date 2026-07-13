import Combine
import Foundation
import MeterBarShared
import os

/// The single-account provider surface `UsageDataManager` orchestrates (Codex,
/// Cursor). Behind a protocol so the manager's merge / graceful-degradation
/// logic can be tested with stub providers instead of the real network + local
/// credential files. Claude Code has its own account-aware path and is not part
/// of this seam.
protocol SimpleUsageProviding: AnyObject {
    var hasAccess: Bool { get }
    func fetchUsageMetrics() async throws -> UsageMetrics
}

extension CodexCliLocalService: SimpleUsageProviding {}
extension CursorLocalService: SimpleUsageProviding {}
extension OpenRouterService: SimpleUsageProviding {}

@MainActor
class UsageDataManager: ObservableObject {
    static let shared = UsageDataManager()

    @Published var metrics: [ServiceType: UsageMetrics] = [:]
    @Published var claudeCodeAccountMetrics: [UUID: UsageMetrics] = [:]
    @Published var isLoading: Bool = false
    @Published var lastError: Error?

    @Published private var refreshIntervalRaw: Int =
        UserDefaults.standard.object(forKey: StorageKeys.refreshInterval) as? Int
        ?? RefreshInterval.fifteenMinutes.rawValue {
        didSet {
            UserDefaults.standard.set(refreshIntervalRaw, forKey: StorageKeys.refreshInterval)
        }
    }

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: refreshIntervalRaw) ?? .fifteenMinutes }
        set {
            refreshIntervalRaw = newValue.rawValue
            setupAutoRefresh()
        }
    }

    private let claudeCodeService: ClaudeCodeLocalService
    private let cursorService: SimpleUsageProviding
    private let codexCliService: SimpleUsageProviding
    private let openRouterService: SimpleUsageProviding
    private let claudeCodeAccountStore: ClaudeCodeAccountStore
    private let providerVisibilityStore: ProviderVisibilityStore

    private var refreshTimer: Timer?
    private let cacheKey = StorageKeys.cachedUsageMetrics
    private let sharedStore: SharedDataStore
    private let cacheDefaults: UserDefaults

    /// Defaults wire the production singletons so `shared` behaves exactly as
    /// before; tests inject stub providers, an isolated `UserDefaults` suite, a
    /// temp-directory `SharedDataStore`, and disable the auto-refresh timer.
    /// The store defaults are `nil` sentinels resolved in the body because the
    /// MainActor-isolated singletons cannot appear in (nonisolated) default
    /// argument position.
    init(
        codexCliService: SimpleUsageProviding = CodexCliLocalService.shared,
        cursorService: SimpleUsageProviding = CursorLocalService.shared,
        openRouterService: SimpleUsageProviding = OpenRouterService.shared,
        claudeCodeService: ClaudeCodeLocalService = .shared,
        claudeCodeAccountStore: ClaudeCodeAccountStore? = nil,
        providerVisibilityStore: ProviderVisibilityStore? = nil,
        sharedStore: SharedDataStore = .shared,
        cacheDefaults: UserDefaults = .standard,
        schedulesAutoRefresh: Bool = true
    ) {
        self.codexCliService = codexCliService
        self.cursorService = cursorService
        self.openRouterService = openRouterService
        self.claudeCodeService = claudeCodeService
        self.claudeCodeAccountStore = claudeCodeAccountStore ?? .shared
        self.providerVisibilityStore = providerVisibilityStore ?? .shared
        self.sharedStore = sharedStore
        self.cacheDefaults = cacheDefaults
        loadCachedData()
        if schedulesAutoRefresh {
            setupAutoRefresh()
        }
    }

    func refreshAll() async {
        isLoading = true
        lastError = nil

        var newMetrics: [ServiceType: UsageMetrics] = [:]

        // Fetch Claude Code metrics (local files)
        if providerVisibilityStore.isEnabled(.claudeCode), claudeCodeService.hasAccess {
            let accountMetrics = await fetchClaudeCodeAccountMetrics()
            claudeCodeAccountMetrics = accountMetrics

            if let representativeMetrics = representativeClaudeCodeMetrics(from: accountMetrics) {
                newMetrics[.claudeCode] = representativeMetrics
            } else if let cachedMetrics = self.metrics[.claudeCode] {
                newMetrics[.claudeCode] = cachedMetrics
            }
        } else if !providerVisibilityStore.isEnabled(.claudeCode) {
            claudeCodeAccountMetrics = [:]
        }

        // Fetch the simple (single-account) providers. On failure the final
        // merge loop below preserves any cached metrics (graceful degradation).
        for service in [ServiceType.codexCli, .cursor, .openRouter]
        where providerVisibilityStore.isEnabled(service) && hasProviderAccess(service) {
            do {
                newMetrics[service] = try await fetchSimpleProviderMetrics(service)
            } catch {
                lastError = error
                let safeMessage = ServiceSupport.safeErrorMessage(for: error)
                let detail = "Failed to fetch \(service.rawValue) metrics: \(safeMessage)"
                AppLog.usage.error("\(detail, privacy: .public)")
            }
        }

        // Merge new metrics with existing cached metrics for services that failed to fetch
        for service in ServiceType.allCases where providerVisibilityStore.isEnabled(service) {
            if newMetrics[service] == nil, let cachedMetric = self.metrics[service] {
                newMetrics[service] = cachedMetric
            }
        }

        metrics = newMetrics
        saveCachedData()
        sharedStore.saveMetrics(newMetrics)
        isLoading = false
    }

    func refresh(service: ServiceType) async {
        isLoading = true
        lastError = nil

        guard providerVisibilityStore.isEnabled(service) else {
            metrics.removeValue(forKey: service)
            if service == .claudeCode {
                claudeCodeAccountMetrics = [:]
            }
            saveCachedData()
            sharedStore.saveMetrics(metrics)
            isLoading = false
            return
        }

        do {
            let newMetrics: UsageMetrics

            switch service {
            case .claudeCode:
                guard claudeCodeService.hasAccess else {
                    throw ServiceError.notAuthenticated
                }
                let accountMetrics = await fetchClaudeCodeAccountMetrics()
                claudeCodeAccountMetrics = accountMetrics
                if let representativeMetrics = representativeClaudeCodeMetrics(from: accountMetrics) {
                    newMetrics = representativeMetrics
                } else if let cachedMetric = metrics[service] {
                    newMetrics = cachedMetric
                } else {
                    // No representative account metrics and nothing cached. Throw a
                    // specific error rather than the shared `lastError`, which may
                    // hold a stale error from an unrelated provider/account.
                    throw ServiceError.notAuthenticated
                }
            case .codexCli, .cursor, .openRouter:
                guard hasProviderAccess(service) else {
                    throw ServiceError.notAuthenticated
                }
                do {
                    newMetrics = try await fetchSimpleProviderMetrics(service)
                } catch {
                    // On individual refresh, preserve cached data if fetch fails
                    if let cachedMetric = metrics[service] {
                        newMetrics = cachedMetric
                        lastError = error
                    } else {
                        throw error
                    }
                }
            }

            metrics[service] = newMetrics
            saveCachedData()
            sharedStore.saveMetrics(metrics)
        } catch {
            if lastError == nil {
                lastError = error
            }
            // Preserve existing cached metrics for this service on error
            if metrics[service] == nil {
                if let cachedData = loadCachedMetricsFromDisk()[service] {
                    metrics[service] = cachedData
                }
            }
        }

        isLoading = false
    }

    private func loadCachedData() {
        let decoded = loadCachedMetricsFromDisk()
        if !decoded.isEmpty {
            metrics = decoded
        }
    }

    /// Decode cached metrics from disk without modifying instance state.
    private func loadCachedMetricsFromDisk() -> [ServiceType: UsageMetrics] {
        guard let data = cacheDefaults.data(forKey: cacheKey) else {
            return [:]
        }
        return MetricsCodec.decode(data)
    }

    private func saveCachedData() {
        if let data = MetricsCodec.encode(metrics) {
            cacheDefaults.set(data, forKey: cacheKey)
        }
    }

    private func setupAutoRefresh() {
        // Cancel existing timer
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Don't schedule if manual refresh only
        guard refreshInterval != .manual else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    private func fetchClaudeCodeAccountMetrics() async -> [UUID: UsageMetrics] {
        var refreshedMetrics: [UUID: UsageMetrics] = [:]

        for account in claudeCodeAccountStore.accounts {
            do {
                refreshedMetrics[account.id] = try await claudeCodeService.fetchUsageMetrics(account: account)
            } catch {
                lastError = error
                if let cachedMetrics = claudeCodeAccountMetrics[account.id] {
                    refreshedMetrics[account.id] = cachedMetrics
                }
            }
        }

        return refreshedMetrics
    }

    private func representativeClaudeCodeMetrics(from accountMetrics: [UUID: UsageMetrics]) -> UsageMetrics? {
        accountMetrics[ClaudeCodeAccount.defaultID] ?? accountMetrics.values.first
    }

    // MARK: - Provider strategy

    private func hasProviderAccess(_ service: ServiceType) -> Bool {
        switch service {
        case .claudeCode:
            return claudeCodeService.hasAccess
        case .codexCli:
            return codexCliService.hasAccess
        case .cursor:
            return cursorService.hasAccess
        case .openRouter:
            return openRouterService.hasAccess
        }
    }

    /// Fetch for the providers without multi-account handling (Claude Code has
    /// its own account-aware path).
    private func fetchSimpleProviderMetrics(_ service: ServiceType) async throws -> UsageMetrics {
        switch service {
        case .codexCli:
            return try await codexCliService.fetchUsageMetrics()
        case .cursor:
            return try await cursorService.fetchUsageMetrics()
        case .openRouter:
            return try await openRouterService.fetchUsageMetrics()
        case .claudeCode:
            preconditionFailure("Claude Code uses the account-aware fetch path")
        }
    }
}
