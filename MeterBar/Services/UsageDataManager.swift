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
extension GrokCLIUsageService: SimpleUsageProviding {}

protocol ClaudeCodeUsageProviding: AnyObject {
    var hasAccess: Bool { get }
    func fetchUsageMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics
}

extension ClaudeCodeLocalService: ClaudeCodeUsageProviding {}

protocol CodexUsageProviding: AnyObject {
    func canAccess(account: CodexAccount) async -> Bool
    func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics
}

extension CodexCliLocalService: CodexUsageProviding {}

@MainActor
class UsageDataManager: ObservableObject {
    static let shared = UsageDataManager(demoMode: DemoMode.isActive)

    @Published var metrics: [ServiceType: UsageMetrics] = [:]
    @Published var claudeCodeAccountMetrics: [UUID: UsageMetrics] = [:]
    @Published var codexAccountMetrics: [UUID: UsageMetrics] = [:]
    @Published var isLoading: Bool = false
    @Published var lastError: Error?

    @Published private var refreshIntervalRaw: Int {
        didSet {
            preferences.set(refreshIntervalRaw, forKey: StorageKeys.refreshInterval)
        }
    }

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: refreshIntervalRaw) ?? .defaultInterval }
        set {
            refreshIntervalRaw = newValue.rawValue
            setupAutoRefresh()
        }
    }

    private let claudeCodeService: ClaudeCodeUsageProviding
    private let cursorService: SimpleUsageProviding
    private let codexCliService: CodexUsageProviding
    private let openRouterService: SimpleUsageProviding
    private let grokService: SimpleUsageProviding
    private let claudeCodeAccountStore: ClaudeCodeAccountStore
    private let claudeFableSessionTracker: ClaudeFableSessionTracking
    private let codexAccountStore: CodexAccountStore
    private let providerVisibilityStore: ProviderVisibilityStore
    private let parseHealthStore: ProviderParseHealthStore

    /// When true, the manager publishes the synthetic `DemoData` fixture and
    /// performs no real fetches, cache reads, or shared-store writes. Gated at
    /// `shared` on `DemoMode.isActive`; never touches real user data.
    private let demoMode: Bool

    private var refreshTimer: Timer?
    private(set) var scheduledRefreshInterval: TimeInterval?
    private let cacheKey = StorageKeys.cachedUsageMetrics
    private let sharedStore: SharedDataStore
    private let preferences: UserDefaults
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
        grokService: SimpleUsageProviding = GrokCLIUsageService.shared,
        claudeCodeService: ClaudeCodeUsageProviding = ClaudeCodeLocalService.shared,
        claudeCodeAccountStore: ClaudeCodeAccountStore? = nil,
        claudeFableSessionTracker: ClaudeFableSessionTracking? = nil,
        codexAccountStore: CodexAccountStore? = nil,
        providerVisibilityStore: ProviderVisibilityStore? = nil,
        sharedStore: SharedDataStore = .shared,
        preferences: UserDefaults = .standard,
        cacheDefaults: UserDefaults = .standard,
        parseHealthStore: ProviderParseHealthStore? = nil,
        schedulesAutoRefresh: Bool = true,
        demoMode: Bool = false
    ) {
        self.demoMode = demoMode
        self.codexCliService = codexCliService ?? CodexCliLocalService.shared
        self.cursorService = cursorService
        self.openRouterService = openRouterService
        self.grokService = grokService
        self.claudeCodeService = claudeCodeService
        self.claudeCodeAccountStore = claudeCodeAccountStore ?? .shared
        self.claudeFableSessionTracker = claudeFableSessionTracker ?? ClaudeFableSessionTracker.shared
        self.codexAccountStore = codexAccountStore ?? .shared
        self.providerVisibilityStore = providerVisibilityStore ?? .shared
        self.sharedStore = sharedStore
        self.preferences = preferences
        self.cacheDefaults = cacheDefaults
        self.parseHealthStore = parseHealthStore ?? .shared
        refreshIntervalRaw = Self.savedRefreshInterval(in: preferences).rawValue

        guard !demoMode else {
            // Publish the synthetic fixture and stop: no cached reads, no
            // per-account metrics, no auto-refresh timer. Real caches are left
            // untouched so a normal launch is unaffected.
            metrics = DemoData.metrics()
            return
        }

        loadCachedData()
        loadCachedAccountMetrics()
        if schedulesAutoRefresh {
            setupAutoRefresh()
        }
    }

    /// Refresh every enabled provider, preserving each provider's last-known-good
    /// metrics when its fetch fails.
    ///
    /// Returns a per-provider report. UI call sites can ignore it; `meterbar
    /// refresh` uses it to report refreshed/failed/skipped state without
    /// re-deriving truth from `lastError`, which only holds the last failure.
    @discardableResult
    func refreshAll() async -> UsageRefreshReport {
        let startedAt = Date()
        guard !demoMode else {
            return UsageRefreshReport(
                startedAt: startedAt,
                finishedAt: Date(),
                outcomes: ServiceType.allCases.map {
                    ProviderRefreshOutcome(
                        provider: $0,
                        state: .skipped,
                        reason: Self.demoModeReason,
                        servedFromCache: metrics[$0] != nil,
                        lastUpdated: metrics[$0]?.lastUpdated
                    )
                }
            )
        }
        guard !isLoading else {
            return UsageRefreshReport(
                startedAt: startedAt,
                finishedAt: Date(),
                outcomes: ServiceType.allCases.map {
                    ProviderRefreshOutcome(
                        provider: $0,
                        state: .skipped,
                        reason: providerVisibilityStore.isEnabled($0)
                            ? "Another refresh is already running."
                            : Self.disabledReason,
                        servedFromCache: metrics[$0] != nil,
                        lastUpdated: metrics[$0]?.lastUpdated
                    )
                }
            )
        }
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        var newMetrics: [ServiceType: UsageMetrics] = [:]
        var states: [ServiceType: (state: ProviderRefreshState, reason: String?)] = [:]

        let hasEnabledClaudeAccount = !claudeCodeAccountStore.enabledAccounts.isEmpty
        let hasEnabledCodexAccount = !codexAccountStore.enabledAccounts.isEmpty

        // The three phases own disjoint state, so they run concurrently: a cycle
        // now costs the slowest phase instead of the sum of all three. Every
        // published assignment is deferred until all three have collected, which
        // is what lets the account fetchers keep reading the *previous* cache for
        // their graceful-degradation fallbacks.
        async let claudeFetch = claudeAccountFetch(
            isEnabled: providerVisibilityStore.isEnabled(.claudeCode) && hasEnabledClaudeAccount
        )
        async let codexFetch = codexAccountFetch(
            isEnabled: providerVisibilityStore.isEnabled(.codexCli) && hasEnabledCodexAccount
        )
        async let simpleFetch = refreshSimpleProviders()

        let claudeResult = await claudeFetch
        let codexResult = await codexFetch
        let simpleResults = await simpleFetch

        // Claude Code metrics (local files)
        if let claudeResult {
            claudeCodeAccountMetrics = claudeResult.metrics

            if let representativeMetrics = representativeClaudeCodeMetrics(from: claudeResult.metrics) {
                newMetrics[.claudeCode] = representativeMetrics
            } else if let cachedMetrics = self.metrics[.claudeCode] {
                newMetrics[.claudeCode] = cachedMetrics
            }
            states[.claudeCode] = accountFetchState(claudeResult)
        } else {
            claudeCodeAccountMetrics = [:]
            states[.claudeCode] = (.skipped, claudeCodeSkipReason(hasEnabledAccount: hasEnabledClaudeAccount))
        }

        if let codexResult {
            codexAccountMetrics = codexResult.metrics
            if let representative = representativeCodexMetrics(from: codexResult.metrics) {
                newMetrics[.codexCli] = representative
            }
            states[.codexCli] = accountFetchState(codexResult)
        } else {
            codexAccountMetrics = [:]
            states[.codexCli] = (
                .skipped,
                providerVisibilityStore.isEnabled(.codexCli) ? Self.noEnabledAccountsReason : Self.disabledReason
            )
        }

        // Simple (single-account) providers. On failure the final merge loop
        // below preserves any cached metrics (graceful degradation).
        newMetrics.merge(simpleResults.metrics) { _, refreshed in refreshed }
        states.merge(simpleResults.states) { _, refreshed in refreshed }

        // Merge new metrics with existing cached metrics for services that failed to fetch
        for service in ServiceType.allCases where providerVisibilityStore.isEnabled(service) {
            if service == .claudeCode, !hasEnabledClaudeAccount { continue }
            // Codex cache entries are account-scoped and merged during account refresh.
            if service == .codexCli { continue }
            if newMetrics[service] == nil, let cachedMetric = self.metrics[service] {
                newMetrics[service] = cachedMetric
            }
        }

        metrics = newMetrics
        saveCachedData()
        saveCachedAccountMetrics()
        saveSharedData(newMetrics)

        return UsageRefreshReport(
            startedAt: startedAt,
            finishedAt: Date(),
            outcomes: states.map { service, state in
                ProviderRefreshOutcome(
                    provider: service,
                    state: state.state,
                    reason: state.reason,
                    servedFromCache: state.state != .refreshed && newMetrics[service] != nil,
                    lastUpdated: newMetrics[service]?.lastUpdated
                )
            }
        )
    }

    private static let disabledReason = "Provider is turned off in MeterBar."
    private static let demoModeReason = "Demo mode is showing sample data."
    private static let notSignedInReason = "No readable credentials for this provider."
    private static let noEnabledAccountsReason = "No enabled accounts for this provider."

    private func claudeCodeSkipReason(hasEnabledAccount: Bool) -> String {
        if !providerVisibilityStore.isEnabled(.claudeCode) { return Self.disabledReason }
        if !hasEnabledAccount { return "No enabled Claude Code accounts." }
        return Self.notSignedInReason
    }

    /// Map a multi-account fetch onto one provider-level state. Any successful
    /// account means the provider refreshed; otherwise a recorded failure wins
    /// over an unreachable/no-account skip.
    private func accountFetchState(_ fetch: AccountFetchResult) -> (ProviderRefreshState, String?) {
        if fetch.successCount > 0 { return (.refreshed, nil) }
        if let failure = fetch.firstFailure {
            return (.failed, ServiceSupport.safeErrorMessage(for: failure))
        }
        return (.skipped, Self.notSignedInReason)
    }

    /// One fanned-out fetch leg, tagged with its position in the original store
    /// order so the fold can restore deterministic ordering.
    ///
    /// `@unchecked Sendable` is honest here: every leg runs on the main actor,
    /// exactly like its parent, so nothing genuinely crosses an isolation
    /// domain. The annotation only satisfies the task-group signature for a
    /// payload carrying an `any Error`.
    private struct IndexedFetch: @unchecked Sendable {
        let index: Int
        let metrics: UsageMetrics?
        let error: Error?
    }

    /// Run `body` once per index concurrently and return the legs in index order.
    ///
    /// `{ @MainActor in }` is required, not decorative: `addTask` closures are
    /// `@Sendable` and therefore nonisolated by default, and the provider
    /// services are not thread-safe. Staying on the main actor is still
    /// concurrent — a main-actor `async` call releases the actor at each of its
    /// own suspension points, so the providers' process and network waits
    /// overlap. That overlap is the whole point.
    private func fanOut(
        count: Int,
        _ body: @escaping @Sendable @MainActor (Int) async throws -> UsageMetrics
    ) async -> [IndexedFetch] {
        guard count > 0 else { return [] }
        return await withTaskGroup(of: IndexedFetch.self) { group in
            for index in 0..<count {
                group.addTask { @MainActor in
                    do {
                        let metrics = try await body(index)
                        return IndexedFetch(index: index, metrics: metrics, error: nil)
                    } catch {
                        return IndexedFetch(index: index, metrics: nil, error: error)
                    }
                }
            }
            var legs: [IndexedFetch] = []
            for await leg in group { legs.append(leg) }
            return legs.sorted { $0.index < $1.index }
        }
    }

    /// Named (rather than a tuple) so it can be returned from an `async let` leg.
    /// `@unchecked Sendable` for the same reason as `IndexedFetch`: main-actor
    /// state that never actually leaves the main actor.
    private struct SimpleProviderRefresh: @unchecked Sendable {
        let metrics: [ServiceType: UsageMetrics]
        let states: [ServiceType: (state: ProviderRefreshState, reason: String?)]
    }

    private func refreshSimpleProviders() async -> SimpleProviderRefresh {
        var metrics: [ServiceType: UsageMetrics] = [:]
        var states: [ServiceType: (state: ProviderRefreshState, reason: String?)] = [:]
        var pending: [ServiceType] = []

        // Visibility and access are synchronous, so resolve them up front and
        // fan out only the legs that will actually reach a provider.
        for service in [ServiceType.cursor, .openRouter, .grok] {
            guard providerVisibilityStore.isEnabled(service) else {
                states[service] = (.skipped, Self.disabledReason)
                continue
            }
            guard hasProviderAccess(service) else {
                states[service] = (.skipped, Self.notSignedInReason)
                continue
            }
            pending.append(service)
        }

        let legs = await fanOut(count: pending.count) { [pending] index in
            try await self.fetchSimpleProviderMetrics(pending[index])
        }

        // Fold in the original provider order so `lastError` stays deterministic
        // rather than reflecting whichever leg happened to finish last.
        for (service, leg) in zip(pending, legs) {
            if let fetched = leg.metrics {
                metrics[service] = fetched
                states[service] = (.refreshed, nil)
            } else if let error = leg.error {
                lastError = error
                let safeMessage = ServiceSupport.safeErrorMessage(for: error)
                let detail = "Failed to fetch \(service.rawValue) metrics: \(safeMessage)"
                AppLog.usage.error("\(detail, privacy: .public)")
                states[service] = (.failed, safeMessage)
            }
        }

        return SimpleProviderRefresh(metrics: metrics, states: states)
    }

    func refresh(service: ServiceType) async {
        guard !demoMode else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        guard providerVisibilityStore.isEnabled(service) else {
            metrics.removeValue(forKey: service)
            if service == .claudeCode {
                claudeCodeAccountMetrics = [:]
            } else if service == .codexCli {
                codexAccountMetrics = [:]
            }
            saveCachedData()
            saveCachedAccountMetrics()
            saveSharedData(metrics)
            return
        }

        if service == .claudeCode, claudeCodeAccountStore.enabledAccounts.isEmpty {
            claudeCodeAccountMetrics = [:]
            metrics.removeValue(forKey: service)
            saveCachedData()
            saveCachedAccountMetrics()
            saveSharedData(metrics)
            return
        }

        if service == .codexCli, codexAccountStore.enabledAccounts.isEmpty {
            codexAccountMetrics = [:]
            metrics.removeValue(forKey: service)
            saveCachedData()
            saveCachedAccountMetrics()
            saveSharedData(metrics)
            return
        }

        do {
            let newMetrics = try await refreshedMetrics(for: service)

            metrics[service] = newMetrics
            saveCachedData()
            saveCachedAccountMetrics()
            saveSharedData(metrics)
        } catch {
            if lastError == nil {
                lastError = error
            }
            if service == .codexCli {
                // Codex aggregate metrics carry no account identity. Scoped
                // per-account caches are restored inside fetchCodexAccountMetrics;
                // if none exist, showing no data is safer than relabeling a
                // different profile's stale quota.
                metrics.removeValue(forKey: service)
                saveCachedData()
                saveCachedAccountMetrics()
                saveSharedData(metrics)
            } else if metrics[service] == nil {
                // Preserve existing cached metrics for single-account services.
                if let cachedData = loadCachedMetricsFromDisk()[service] {
                    metrics[service] = cachedData
                }
            }
        }
    }

    /// A delayed repeating timer does not replay missed ticks after sleep. The
    /// workspace wake hook calls this method once; it catches up only when an
    /// enabled source has no data or its oldest successful snapshot is at least
    /// ten minutes old. Manual-only mode remains fully manual.
    func refreshAfterWakeIfNeeded(now: Date = Date()) async {
        guard !demoMode else { return }
        guard refreshInterval != .manual, await shouldCatchUpAfterWake(now: now) else { return }
        await refreshAll()
    }

    /// Installs the post-redemption Codex usage response into the same caches
    /// used by the popover, dashboard, widget, and CLI. The service has already
    /// performed the network refresh; this method only publishes that result.
    func applyCodexResetCreditRefresh(_ refreshedMetrics: UsageMetrics, accountID: UUID) {
        guard !demoMode else { return }
        codexAccountMetrics[accountID] = refreshedMetrics
        if let representative = representativeCodexMetrics(from: codexAccountMetrics) {
            metrics[.codexCli] = representative
        }
        lastError = nil
        saveCachedData()
        saveCachedAccountMetrics()
        saveSharedData(metrics)
    }

    private func refreshedMetrics(for service: ServiceType) async throws -> UsageMetrics {
        switch service {
        case .claudeCode:
            let accountMetrics = await fetchClaudeCodeAccountMetrics().metrics
            claudeCodeAccountMetrics = accountMetrics
            if let representative = representativeClaudeCodeMetrics(from: accountMetrics) { return representative }
        case .codexCli:
            let accountMetrics = await fetchCodexAccountMetrics().metrics
            codexAccountMetrics = accountMetrics
            if let representative = representativeCodexMetrics(from: accountMetrics) { return representative }
            throw ServiceError.notAuthenticated
        case .cursor, .openRouter, .grok:
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
            return
        }
        // A bundled CLI process has a different defaults domain than the app.
        // Fall back to the app-group snapshot so failures preserve the same
        // last-known-good values `meterbar usage` already exposes.
        let shared = sharedStore.loadMetrics()
        if !shared.isEmpty {
            metrics = shared
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

    private func loadCachedAccountMetrics() {
        if let data = cacheDefaults.data(forKey: StorageKeys.cachedClaudeCodeAccountMetrics),
           let decoded = try? JSONDecoder().decode([UUID: UsageMetrics].self, from: data) {
            claudeCodeAccountMetrics = decoded
        }
        if let data = cacheDefaults.data(forKey: StorageKeys.cachedCodexAccountMetrics),
           let decoded = try? JSONDecoder().decode([UUID: UsageMetrics].self, from: data) {
            codexAccountMetrics = decoded
        }

        guard claudeCodeAccountMetrics.isEmpty || codexAccountMetrics.isEmpty else { return }
        let sharedSnapshots = sharedStore.loadAccountMetrics()
        if claudeCodeAccountMetrics.isEmpty {
            claudeCodeAccountMetrics = Dictionary(
                uniqueKeysWithValues: sharedSnapshots
                    .filter { $0.metrics.service == .claudeCode }
                    .map { ($0.id, $0.metrics) }
            )
        }
        if codexAccountMetrics.isEmpty {
            codexAccountMetrics = Dictionary(
                uniqueKeysWithValues: sharedSnapshots
                    .filter { $0.metrics.service == .codexCli }
                    .map { ($0.id, $0.metrics) }
            )
        }
    }

    private func saveCachedAccountMetrics() {
        if let data = try? JSONEncoder().encode(claudeCodeAccountMetrics) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedClaudeCodeAccountMetrics)
        }
        if let data = try? JSONEncoder().encode(codexAccountMetrics) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedCodexAccountMetrics)
        }
    }

    private func saveSharedData(_ metrics: [ServiceType: UsageMetrics]) {
        sharedStore.saveMetrics(metrics)
        let claudeSnapshots = claudeCodeAccountStore.enabledAccounts.compactMap { account -> AccountUsageSnapshot? in
            guard let metrics = claudeCodeAccountMetrics[account.id] else { return nil }
            return AccountUsageSnapshot(id: account.id, name: account.name, metrics: metrics)
        }
        let codexSnapshots = codexAccountStore.enabledAccounts.compactMap { account -> AccountUsageSnapshot? in
            guard let metrics = codexAccountMetrics[account.id] else { return nil }
            return AccountUsageSnapshot(id: account.id, name: account.name, metrics: metrics)
        }
        let accountSnapshots = claudeSnapshots + codexSnapshots
        sharedStore.saveAccountMetrics(accountSnapshots)
    }

    private func setupAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        scheduledRefreshInterval = nil

        guard refreshInterval != .manual else { return }

        let interval = refreshInterval.seconds
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        scheduledRefreshInterval = interval
    }

    private static func savedRefreshInterval(in preferences: UserDefaults) -> RefreshInterval {
        guard let rawValue = preferences.object(forKey: StorageKeys.refreshInterval) as? Int else {
            return .defaultInterval
        }
        return RefreshInterval(rawValue: rawValue) ?? .defaultInterval
    }

    private func shouldCatchUpAfterWake(now: Date) async -> Bool {
        var lastUpdatedDates: [Date] = []
        var hasEnabledSource = false
        var hasMissingData = false

        func collect(_ metric: UsageMetrics?) {
            hasEnabledSource = true
            guard let metric else {
                hasMissingData = true
                return
            }
            lastUpdatedDates.append(metric.lastUpdated)
        }

        if providerVisibilityStore.isEnabled(.claudeCode),
           claudeCodeService.hasAccess,
           !claudeCodeAccountStore.enabledAccounts.isEmpty {
            for account in claudeCodeAccountStore.enabledAccounts {
                collect(claudeCodeAccountMetrics[account.id])
            }
        }

        if providerVisibilityStore.isEnabled(.codexCli),
           !codexAccountStore.enabledAccounts.isEmpty {
            for account in codexAccountStore.enabledAccounts {
                guard await codexCliService.canAccess(account: account) else { continue }
                collect(codexAccountMetrics[account.id])
            }
        }

        for service in [ServiceType.cursor, .openRouter, .grok]
        where providerVisibilityStore.isEnabled(service) && hasProviderAccess(service) {
            collect(metrics[service])
        }

        guard hasEnabledSource else { return false }
        if hasMissingData { return true }
        guard let oldestUpdate = lastUpdatedDates.min() else { return true }
        return now.timeIntervalSince(oldestUpdate) >= RefreshInterval.tenMinutes.seconds
    }

    /// `@unchecked Sendable` for the same reason as `IndexedFetch`: main-actor
    /// state that never actually leaves the main actor, carrying an `any Error`.
    private struct AccountFetchResult: @unchecked Sendable {
        let metrics: [UUID: UsageMetrics]
        let successCount: Int
        let firstFailure: Error?
    }

    /// Sentinel that lets the `canAccess` probe move inside the concurrent leg
    /// while still folding back to today's plain-skip semantics: an unreachable
    /// account contributes no metrics, no cached fallback, and no failure.
    private struct CodexAccountUnreachable: Error {}

    private func claudeAccountFetch(isEnabled: Bool) async -> AccountFetchResult? {
        guard isEnabled else { return nil }
        return await fetchClaudeCodeAccountMetrics()
    }

    private func codexAccountFetch(isEnabled: Bool) async -> AccountFetchResult? {
        guard isEnabled else { return nil }
        return await fetchCodexAccountMetrics()
    }

    private func fetchClaudeCodeAccountMetrics() async -> AccountFetchResult {
        let enabledAccounts = claudeCodeAccountStore.enabledAccounts
        var refreshedMetrics: [UUID: UsageMetrics] = [:]
        var firstFailure: Error?
        var successCount = 0

        let legs = await fanOut(count: enabledAccounts.count) { [enabledAccounts] index in
            try await self.claudeCodeService.fetchUsageMetrics(account: enabledAccounts[index])
        }

        // Fold in account-store order, never completion order, so `firstFailure`
        // (and therefore the surfaced reason) is stable across runs. `zip`
        // rather than subscripting: a count mismatch truncates instead of trapping.
        for (account, leg) in zip(enabledAccounts, legs) {
            if let metrics = leg.metrics {
                refreshedMetrics[account.id] = metrics
                successCount += 1
            } else if let error = leg.error {
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

        claudeFableSessionTracker.scheduleRefresh(accounts: enabledAccounts)
        return AccountFetchResult(
            metrics: refreshedMetrics,
            successCount: successCount,
            firstFailure: firstFailure
        )
    }

    private func representativeClaudeCodeMetrics(from accountMetrics: [UUID: UsageMetrics]) -> UsageMetrics? {
        if claudeCodeAccountStore.defaultAccountIsEnabled,
           let defaultMetrics = accountMetrics[ClaudeCodeAccount.defaultID] {
            return defaultMetrics
        }
        return claudeCodeAccountStore.enabledAccounts.lazy.compactMap { accountMetrics[$0.id] }.first
    }

    private func fetchCodexAccountMetrics() async -> AccountFetchResult {
        let enabledAccounts = codexAccountStore.enabledAccounts
        var refreshedMetrics: [UUID: UsageMetrics] = [:]
        var firstFailure: Error?
        var successCount = 0

        // `canAccess` is itself an async probe, so it moves into the leg rather
        // than gating it serially; an unreachable account throws the sentinel.
        let legs = await fanOut(count: enabledAccounts.count) { [enabledAccounts] index in
            let account = enabledAccounts[index]
            guard await self.codexCliService.canAccess(account: account) else {
                throw CodexAccountUnreachable()
            }
            return try await self.codexCliService.fetchUsageMetrics(account: account)
        }

        for (account, leg) in zip(enabledAccounts, legs) {
            if let metrics = leg.metrics {
                refreshedMetrics[account.id] = metrics
                successCount += 1
            } else if let error = leg.error {
                // Matches the previous `continue`: an inaccessible account is a
                // skip, not a failure, and must not resurrect a stale cache.
                if error is CodexAccountUnreachable { continue }
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

        return AccountFetchResult(
            metrics: refreshedMetrics,
            successCount: successCount,
            firstFailure: firstFailure
        )
    }

    private func representativeCodexMetrics(from accountMetrics: [UUID: UsageMetrics]) -> UsageMetrics? {
        if codexAccountStore.defaultAccountIsEnabled,
           let defaultMetrics = accountMetrics[CodexAccount.defaultID] {
            return defaultMetrics
        }
        return codexAccountStore.enabledAccounts.lazy.compactMap { accountMetrics[$0.id] }.first
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
        case .grok:
            return grokService.hasAccess
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
            case .grok:
                result = try await grokService.fetchUsageMetrics()
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
