import Combine
import Foundation
import MeterBarShared
import os

/// The single-account provider surface `UsageDataManager` orchestrates (Cursor).
/// Behind a protocol so the manager's merge / graceful-degradation
/// logic can be tested with stub providers instead of the real network + local
/// credential files. Claude Code has its own account-aware path and is not part
/// of this seam.
protocol SimpleUsageProviding: AnyObject {
    var hasAccess: Bool { get }
    func fetchUsageMetrics() async throws -> UsageMetrics
}

extension CursorLocalService: SimpleUsageProviding {}
extension OpenRouterService: SimpleUsageProviding {}

protocol CodexUsageProviding: AnyObject {
    func canAccess(account: CodexAccount) async -> Bool
    func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics
}

extension CodexCliLocalService: CodexUsageProviding {}

@MainActor
class UsageDataManager: ObservableObject {
    static let shared = UsageDataManager()

    @Published var metrics: [ServiceType: UsageMetrics] = [:]
    @Published var claudeCodeAccountMetrics: [UUID: UsageMetrics] = [:]
    @Published var codexAccountMetrics: [UUID: UsageMetrics] = [:]
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
    private let codexCliService: CodexUsageProviding
    private let openRouterService: SimpleUsageProviding
    private let claudeCodeAccountStore: ClaudeCodeAccountStore
    private let codexAccountStore: CodexAccountStore
    private let providerVisibilityStore: ProviderVisibilityStore
    private let parseHealthStore: ProviderParseHealthStore

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
        codexCliService: CodexUsageProviding? = nil,
        cursorService: SimpleUsageProviding = CursorLocalService.shared,
        openRouterService: SimpleUsageProviding = OpenRouterService.shared,
        claudeCodeService: ClaudeCodeLocalService = .shared,
        claudeCodeAccountStore: ClaudeCodeAccountStore? = nil,
        codexAccountStore: CodexAccountStore? = nil,
        providerVisibilityStore: ProviderVisibilityStore? = nil,
        sharedStore: SharedDataStore = .shared,
        cacheDefaults: UserDefaults = .standard,
        parseHealthStore: ProviderParseHealthStore? = nil,
        schedulesAutoRefresh: Bool = true
    ) {
        self.codexCliService = codexCliService ?? CodexCliLocalService.shared
        self.cursorService = cursorService
        self.openRouterService = openRouterService
        self.claudeCodeService = claudeCodeService
        self.claudeCodeAccountStore = claudeCodeAccountStore ?? .shared
        self.codexAccountStore = codexAccountStore ?? .shared
        self.providerVisibilityStore = providerVisibilityStore ?? .shared
        self.sharedStore = sharedStore
        self.cacheDefaults = cacheDefaults
        self.parseHealthStore = parseHealthStore ?? .shared
        loadCachedData()
        loadCachedCodexAccountMetrics()
        if schedulesAutoRefresh {
            setupAutoRefresh()
        }
    }

    func refreshAll() async {
        isLoading = true
        lastError = nil

        var newMetrics: [ServiceType: UsageMetrics] = [:]

        // Fetch Claude Code metrics (local files)
        let hasEnabledClaudeAccount = !claudeCodeAccountStore.enabledAccounts.isEmpty
        if providerVisibilityStore.isEnabled(.claudeCode), hasEnabledClaudeAccount, claudeCodeService.hasAccess {
            let accountMetrics = await fetchClaudeCodeAccountMetrics()
            claudeCodeAccountMetrics = accountMetrics

            if let representativeMetrics = representativeClaudeCodeMetrics(from: accountMetrics) {
                newMetrics[.claudeCode] = representativeMetrics
            } else if let cachedMetrics = self.metrics[.claudeCode] {
                newMetrics[.claudeCode] = cachedMetrics
            }
        } else if !providerVisibilityStore.isEnabled(.claudeCode) || !hasEnabledClaudeAccount {
            claudeCodeAccountMetrics = [:]
        }

        if providerVisibilityStore.isEnabled(.codexCli) {
            let accountMetrics = await fetchCodexAccountMetrics()
            codexAccountMetrics = accountMetrics
            if let representative = representativeCodexMetrics(from: accountMetrics) {
                newMetrics[.codexCli] = representative
            } else if let cachedMetrics = self.metrics[.codexCli] {
                newMetrics[.codexCli] = cachedMetrics
            }
        } else {
            codexAccountMetrics = [:]
        }

        // Fetch the simple (single-account) providers. On failure the final
        // merge loop below preserves any cached metrics (graceful degradation).
        for service in [ServiceType.cursor, .openRouter]
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
            if service == .claudeCode, !hasEnabledClaudeAccount { continue }
            if newMetrics[service] == nil, let cachedMetric = self.metrics[service] {
                newMetrics[service] = cachedMetric
            }
        }

        metrics = newMetrics
        saveCachedData()
        saveCachedCodexAccountMetrics()
        saveSharedData(newMetrics)
        isLoading = false
    }

    func refresh(service: ServiceType) async {
        isLoading = true
        lastError = nil

        guard providerVisibilityStore.isEnabled(service) else {
            metrics.removeValue(forKey: service)
            if service == .claudeCode {
                claudeCodeAccountMetrics = [:]
            } else if service == .codexCli {
                codexAccountMetrics = [:]
            }
            saveCachedData()
            saveCachedCodexAccountMetrics()
            saveSharedData(metrics)
            isLoading = false
            return
        }

        if service == .claudeCode, claudeCodeAccountStore.enabledAccounts.isEmpty {
            claudeCodeAccountMetrics = [:]
            metrics.removeValue(forKey: service)
            saveCachedData()
            saveSharedData(metrics)
            isLoading = false
            return
        }

        do {
            let newMetrics = try await refreshedMetrics(for: service)

            metrics[service] = newMetrics
            saveCachedData()
            saveCachedCodexAccountMetrics()
            saveSharedData(metrics)
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

    private func refreshedMetrics(for service: ServiceType) async throws -> UsageMetrics {
        switch service {
        case .claudeCode:
            guard claudeCodeService.hasAccess else { throw ServiceError.notAuthenticated }
            let accountMetrics = await fetchClaudeCodeAccountMetrics()
            claudeCodeAccountMetrics = accountMetrics
            if let representative = representativeClaudeCodeMetrics(from: accountMetrics) { return representative }
        case .codexCli:
            let accountMetrics = await fetchCodexAccountMetrics()
            codexAccountMetrics = accountMetrics
            if let representative = representativeCodexMetrics(from: accountMetrics) { return representative }
        case .cursor, .openRouter:
            guard hasProviderAccess(service) else { throw ServiceError.notAuthenticated }
            do {
                return try await fetchSimpleProviderMetrics(service)
            } catch {
                if let cachedMetric = metrics[service] {
                    lastError = error
                    return cachedMetric
                }
                throw error
            }
        }

        if let cachedMetric = metrics[service] { return cachedMetric }
        throw ServiceError.notAuthenticated
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

    private func loadCachedCodexAccountMetrics() {
        guard let data = cacheDefaults.data(forKey: StorageKeys.cachedCodexAccountMetrics),
              let decoded = try? JSONDecoder().decode([UUID: UsageMetrics].self, from: data) else { return }
        codexAccountMetrics = decoded
    }

    private func saveCachedCodexAccountMetrics() {
        guard let data = try? JSONEncoder().encode(codexAccountMetrics) else { return }
        cacheDefaults.set(data, forKey: StorageKeys.cachedCodexAccountMetrics)
    }

    private func saveSharedData(_ metrics: [ServiceType: UsageMetrics]) {
        sharedStore.saveMetrics(metrics)
        let accountSnapshots = codexAccountStore.accounts.compactMap { account -> AccountUsageSnapshot? in
            guard let metrics = codexAccountMetrics[account.id] else { return nil }
            return AccountUsageSnapshot(id: account.id, name: account.name, metrics: metrics)
        }
        sharedStore.saveAccountMetrics(accountSnapshots)
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
        var firstFailure: Error?
        var successCount = 0

        for account in claudeCodeAccountStore.enabledAccounts {
            do {
                refreshedMetrics[account.id] = try await claudeCodeService.fetchUsageMetrics(account: account)
                successCount += 1
            } catch {
                if firstFailure == nil { firstFailure = error }
                lastError = error
                if let cachedMetrics = claudeCodeAccountMetrics[account.id] {
                    refreshedMetrics[account.id] = cachedMetrics
                }
            }
        }

        // Parse health tracks integration health, not per-account health:
        // if any account parses, the format contract still holds, so one
        // failing account must not dim the whole provider.
        if successCount > 0 {
            parseHealthStore.recordSuccess(.claudeCode)
        } else if let firstFailure {
            parseHealthStore.recordFailure(.claudeCode, error: firstFailure)
        }

        return refreshedMetrics
    }

    private func representativeClaudeCodeMetrics(from accountMetrics: [UUID: UsageMetrics]) -> UsageMetrics? {
        if claudeCodeAccountStore.defaultAccountIsEnabled,
           let defaultMetrics = accountMetrics[ClaudeCodeAccount.defaultID] {
            return defaultMetrics
        }
        return claudeCodeAccountStore.enabledAccounts.lazy.compactMap { accountMetrics[$0.id] }.first
    }

    private func fetchCodexAccountMetrics() async -> [UUID: UsageMetrics] {
        var refreshedMetrics: [UUID: UsageMetrics] = [:]
        var firstFailure: Error?
        var successCount = 0

        for account in codexAccountStore.accounts {
            guard await codexCliService.canAccess(account: account) else { continue }
            do {
                refreshedMetrics[account.id] = try await codexCliService.fetchUsageMetrics(account: account)
                successCount += 1
            } catch {
                if firstFailure == nil { firstFailure = error }
                lastError = error
                if let cachedMetrics = codexAccountMetrics[account.id] {
                    refreshedMetrics[account.id] = cachedMetrics
                }
            }
        }

        if successCount > 0 {
            parseHealthStore.recordSuccess(.codexCli)
        } else if let firstFailure {
            parseHealthStore.recordFailure(.codexCli, error: firstFailure)
        }

        return refreshedMetrics
    }

    private func representativeCodexMetrics(from accountMetrics: [UUID: UsageMetrics]) -> UsageMetrics? {
        accountMetrics[CodexAccount.defaultID]
            ?? codexAccountStore.accounts.lazy.compactMap { accountMetrics[$0.id] }.first
    }

    // MARK: - Provider strategy

    private func hasProviderAccess(_ service: ServiceType) -> Bool {
        switch service {
        case .claudeCode:
            return claudeCodeService.hasAccess
        case .codexCli:
            return false
        case .cursor:
            return cursorService.hasAccess
        case .openRouter:
            return openRouterService.hasAccess
        }
    }

    /// Fetch for the providers without multi-account handling (Claude Code has
    /// its own account-aware path).
    private func fetchSimpleProviderMetrics(_ service: ServiceType) async throws -> UsageMetrics {
        do {
            let result: UsageMetrics
            switch service {
            case .cursor:
                result = try await cursorService.fetchUsageMetrics()
            case .openRouter:
                result = try await openRouterService.fetchUsageMetrics()
            case .claudeCode, .codexCli:
                preconditionFailure("Account-aware providers use dedicated fetch paths")
            }
            parseHealthStore.recordSuccess(service)
            return result
        } catch {
            parseHealthStore.recordFailure(service, error: error)
            throw error
        }
    }
}
