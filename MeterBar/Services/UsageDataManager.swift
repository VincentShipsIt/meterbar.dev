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

    /// The running counter this provider reported on its last successful poll,
    /// or nil if it has not polled successfully or publishes no such counter.
    ///
    /// Both providers behind this seam serve running scalars and no history —
    /// neither will re-serve a day once it has passed — so this is the only
    /// point at which their spend can be captured for a dated series. Read
    /// after `fetchUsageMetrics()` rather than returned from it, because that
    /// return value is serialized into the app-group cache the widget and the
    /// CLI decode.
    var latestUsageObservation: ProviderUsageObservation? { get }
}

/// Defaulted so stub providers in tests, which have no counter to publish,
/// keep conforming without restating this.
extension SimpleUsageProviding {
    var latestUsageObservation: ProviderUsageObservation? { nil }
}

extension CursorLocalService: SimpleUsageProviding {}

protocol ClaudeCodeUsageProviding: AnyObject {
    var hasAccess: Bool { get }
    /// What the service last observed per account. `hasAccess` above describes
    /// only the default profile, so it cannot say why a secondary account's
    /// refresh failed — without this the manager would fall back to that
    /// account's cache with no way to mark the card as stale or logged out.
    var accountAuthStates: [UUID: ClaudeCodeAuthState] { get }
    func fetchUsageMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics
    func fetchUsageMetrics(
        account: ClaudeCodeAccount,
        trigger: ClaudeTokenRefreshTrigger
    ) async throws -> UsageMetrics
}

extension ClaudeCodeUsageProviding {
    func fetchUsageMetrics(
        account: ClaudeCodeAccount,
        trigger: ClaudeTokenRefreshTrigger
    ) async throws -> UsageMetrics {
        _ = trigger
        return try await fetchUsageMetrics(account: account)
    }
}

extension ClaudeCodeLocalService: ClaudeCodeUsageProviding {}

protocol CodexUsageProviding: AnyObject {
    /// `nonisolated` so the witness thunk forwards `account` without a main-actor
    /// entry hop — see the lifetime note on `CodexCliLocalService.canAccess`.
    /// The refresh legs call this off the main actor, which is exactly where a
    /// hopping thunk would strand the indirect argument.
    nonisolated func canAccess(account: CodexAccount) async -> Bool
    func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics
}

extension CodexCliLocalService: CodexUsageProviding {}

protocol GrokUsageProviding: AnyObject {
    func canAccess(account: GrokAccount) -> Bool
    func fetchUsageMetrics(account: GrokAccount) async throws -> UsageMetrics
}

extension GrokCLIUsageService: GrokUsageProviding {}

/// Account-aware seam for the OpenRouter API keys. `canAccess` is a sync,
/// prompt-free Keychain attribute probe (never a decrypt), so — unlike Codex's
/// async probe — it can gate the leg directly.
protocol OpenRouterUsageProviding: AnyObject {
    func canAccess(account: OpenRouterAccount) -> Bool
    func fetchUsageMetrics(account: OpenRouterAccount) async throws -> UsageMetrics
    /// Per-key running-spend observations from the most recent polls, keyed by
    /// account id. Read after the fan-out folds to build the ledger entry.
    var latestAccountObservations: [UUID: ProviderUsageObservation] { get }
}

extension OpenRouterService: OpenRouterUsageProviding {}

@MainActor
class UsageDataManager: ObservableObject {
    static let shared = UsageDataManager(demoMode: DemoMode.isActive)

    @Published var metrics: [ServiceType: UsageMetrics] = [:]
    @Published var claudeCodeAccountMetrics: [UUID: UsageMetrics] = [:]
    /// Per-account auth/staleness, resolved once per refresh cycle. Drives the
    /// card overlay so a failed leg that falls back to cached numbers cannot
    /// render a green band as if it had just refreshed.
    @Published private(set) var claudeCodeAccountStates: [UUID: ClaudeCodeAuthState] = [:]
    @Published var codexAccountMetrics: [UUID: UsageMetrics] = [:]
    @Published var grokAccountMetrics: [UUID: UsageMetrics] = [:]
    @Published var openRouterAccountMetrics: [UUID: UsageMetrics] = [:]
    @Published var isLoading: Bool = false
    @Published var lastError: Error?
    /// Human-readable explanation for the interval currently installed. The
    /// Diagnostics page reads this value; no activity timestamps are exposed.
    private(set) var effectiveRefreshReason = "Fixed interval selected."

    /// Advances once per committed metric snapshot. Notification checks subscribe
    /// to this rather than polling on a timer, so a limit crossing is evaluated
    /// the moment a refresh lands instead of up to five minutes later.
    @Published private(set) var refreshGeneration: UInt64 = 0

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
    private let openRouterService: OpenRouterUsageProviding
    private let grokService: GrokUsageProviding
    private let claudeCodeAccountStore: ClaudeCodeAccountStore
    private let codexAccountStore: CodexAccountStore
    private let grokAccountStore: GrokAccountStore
    private let openRouterAccountStore: OpenRouterAccountStore
    private let providerVisibilityStore: ProviderVisibilityStore
    private let parseHealthStore: ProviderParseHealthStore
    private let refreshLockMode: UsageRefreshLockMode
    private let refreshLockFactory: @Sendable () -> WakeLock
    private let accountFailoverCoordinator: AccountFailoverCoordinator

    /// Where polled running counters are accumulated into a dated series.
    ///
    /// Its own artifact, not shared with the scan caches: those are derived
    /// from log files that can be re-read, while this ledger is the only copy
    /// of Cursor's and OpenRouter's history that will ever exist. `CostTracker`
    /// reads the same file back when it builds the published summary.
    private let usageLedgerStore = ProviderUsageLedgerStore.applicationSupport

    /// When true, the manager publishes the synthetic `DemoData` fixture and
    /// performs no real fetches, cache reads, or shared-store writes. Gated at
    /// `shared` on `DemoMode.isActive`; never touches real user data.
    private let demoMode: Bool

    private var refreshTimer: Timer?
    private(set) var scheduledRefreshInterval: TimeInterval?
    private(set) var scheduledRefreshRepeats = false
    private let cacheKey = StorageKeys.cachedUsageMetrics
    private let sharedStore: SharedDataStore
    private let preferences: UserDefaults
    private let cacheDefaults: UserDefaults
    private let adaptiveRefreshEngine: AdaptiveRefreshCadenceEngine
    private let adaptiveNow: @Sendable () -> Date
    private let adaptivePowerState: @Sendable () -> AdaptiveRefreshPowerState
    private var adaptiveQuotaSnapshot = AdaptiveQuotaSnapshot(values: [:])
    private var lastMeterBarInteractionAt: Date?
    private var lastQuotaMovementAt: Date?
    private var cadenceCancellables = Set<AnyCancellable>()

    /// Defaults wire the production singletons so `shared` behaves exactly as
    /// before; tests inject stub providers, an isolated `UserDefaults` suite, a
    /// temp-directory `SharedDataStore`, and disable the auto-refresh timer.
    /// The store defaults are `nil` sentinels resolved in the body because the
    /// MainActor-isolated singletons cannot appear in (nonisolated) default
    /// argument position.
    init(
        codexCliService: CodexUsageProviding? = nil,
        cursorService: SimpleUsageProviding = CursorLocalService.shared,
        openRouterService: OpenRouterUsageProviding = OpenRouterService.shared,
        grokService: GrokUsageProviding = GrokCLIUsageService.shared,
        claudeCodeService: ClaudeCodeUsageProviding = ClaudeCodeLocalService.shared,
        claudeCodeAccountStore: ClaudeCodeAccountStore? = nil,
        codexAccountStore: CodexAccountStore? = nil,
        grokAccountStore: GrokAccountStore? = nil,
        openRouterAccountStore: OpenRouterAccountStore? = nil,
        providerVisibilityStore: ProviderVisibilityStore? = nil,
        sharedStore: SharedDataStore = .shared,
        preferences: UserDefaults = .standard,
        cacheDefaults: UserDefaults = .standard,
        parseHealthStore: ProviderParseHealthStore? = nil,
        accountFailoverCoordinator: AccountFailoverCoordinator? = nil,
        schedulesAutoRefresh: Bool = true,
        refreshLockMode: UsageRefreshLockMode = .acquirePerRefresh,
        refreshLockFactory: @escaping @Sendable () -> WakeLock = {
            UsageRefreshLock.make(holderKind: .app)
        },
        adaptiveNow: @escaping @Sendable () -> Date = { Date() },
        adaptivePowerState: @escaping @Sendable () -> AdaptiveRefreshPowerState = {
            .current
        },
        demoMode: Bool = false
    ) {
        self.demoMode = demoMode
        self.codexCliService = codexCliService ?? CodexCliLocalService.shared
        self.cursorService = cursorService
        self.openRouterService = openRouterService
        self.grokService = grokService
        self.claudeCodeService = claudeCodeService
        self.claudeCodeAccountStore = claudeCodeAccountStore ?? .shared
        self.codexAccountStore = codexAccountStore ?? .shared
        self.grokAccountStore = grokAccountStore ?? .shared
        self.openRouterAccountStore = openRouterAccountStore ?? .shared
        self.providerVisibilityStore = providerVisibilityStore ?? .shared
        self.sharedStore = sharedStore
        self.preferences = preferences
        self.cacheDefaults = cacheDefaults
        self.parseHealthStore = parseHealthStore ?? .shared
        self.accountFailoverCoordinator = accountFailoverCoordinator ?? .shared
        self.refreshLockMode = refreshLockMode
        self.refreshLockFactory = refreshLockFactory
        self.adaptiveNow = adaptiveNow
        self.adaptivePowerState = adaptivePowerState
        adaptiveRefreshEngine = AdaptiveRefreshCadenceEngine(now: adaptiveNow)
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
        adaptiveQuotaSnapshot = makeAdaptiveQuotaSnapshot()
        if schedulesAutoRefresh {
            observeAdaptivePowerChanges()
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
    func refreshForExplicitAction(
        _ action: AdaptiveRefreshTrigger
    ) async -> UsageRefreshReport {
        guard action != .scheduled else {
            return await refreshAll(trigger: .background)
        }
        lastMeterBarInteractionAt = adaptiveNow()
        // Popover open bypasses cadence but retains the background credential
        // policy: merely viewing MeterBar must not raise a Keychain prompt.
        // The Refresh buttons carry stronger intent and may request access.
        let tokenTrigger: ClaudeTokenRefreshTrigger = action == .manualRefresh
            ? .userInitiated
            : .background
        return await refreshAll(trigger: tokenTrigger)
    }

    @discardableResult
    func refreshAll(
        trigger: ClaudeTokenRefreshTrigger = .background
    ) async -> UsageRefreshReport {
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
        defer { rescheduleAdaptiveRefreshIfNeeded() }
        guard !isLoading else {
            return skippedRefreshReport(startedAt: startedAt, enabledReason: "Another refresh is already running.")
        }

        let refreshLock: WakeLock?
        switch await acquireRefreshLock() {
        case let .acquired(lock):
            refreshLock = lock
        case let .skipped(reason):
            return skippedRefreshReport(startedAt: startedAt, enabledReason: reason)
        }
        defer { refreshLock?.release() }

        isLoading = true
        defer { isLoading = false }
        lastError = nil

        var newMetrics: [ServiceType: UsageMetrics] = [:]
        var states: [ServiceType: (state: ProviderRefreshState, reason: String?)] = [:]

        let hasEnabledClaudeAccount = !claudeCodeAccountStore.enabledAccounts.isEmpty
        let hasEnabledCodexAccount = !codexAccountStore.enabledAccounts.isEmpty
        let hasEnabledGrokAccount = !grokAccountStore.enabledAccounts.isEmpty
        let hasEnabledOpenRouterKey = !openRouterAccountStore.enabledAccounts.isEmpty

        // The four phases own disjoint state, so they run concurrently: a cycle
        // now costs the slowest phase instead of their sum. Every published
        // assignment is deferred until all four have collected, which
        // is what lets the account fetchers keep reading the *previous* cache for
        // their graceful-degradation fallbacks.
        async let claudeFetch = claudeAccountFetch(
            isEnabled: providerVisibilityStore.isEnabled(.claudeCode) && hasEnabledClaudeAccount,
            trigger: trigger
        )
        async let codexFetch = codexAccountFetch(
            isEnabled: providerVisibilityStore.isEnabled(.codexCli) && hasEnabledCodexAccount
        )
        async let grokFetch = grokAccountFetch(
            isEnabled: providerVisibilityStore.isEnabled(.grok) && hasEnabledGrokAccount
        )
        async let openRouterFetch = openRouterAccountFetch(
            isEnabled: providerVisibilityStore.isEnabled(.openRouter) && hasEnabledOpenRouterKey
        )
        async let simpleFetch = refreshSimpleProviders()

        let claudeResult = await claudeFetch
        let codexResult = await codexFetch
        let grokResult = await grokFetch
        let openRouterResult = await openRouterFetch
        let simpleResults = await simpleFetch

        // Rank the phases here, in a fixed order, rather than letting each one
        // assign `lastError` as it finishes: the three race, so completion order
        // is arbitrary and the surfaced error would otherwise change run to run.
        lastError = claudeResult?.firstFailure
            ?? codexResult?.firstFailure
            ?? grokResult?.firstFailure
            ?? openRouterResult?.firstFailure
            ?? simpleResults.firstFailure

        // Claude Code metrics (local files). Its auth states and skip reason
        // differ; Codex, Grok, and OpenRouter share `foldUniformAccountPhase`.
        if let claudeResult {
            claudeCodeAccountMetrics = claudeResult.metrics
            claudeCodeAccountStates = claudeResult.accountStates

            if let representativeMetrics = representativeClaudeCodeMetrics(from: claudeResult.metrics) {
                newMetrics[.claudeCode] = representativeMetrics
            } else if let cachedMetrics = self.metrics[.claudeCode] {
                newMetrics[.claudeCode] = cachedMetrics
            }
            states[.claudeCode] = accountFetchState(claudeResult)
        } else {
            claudeCodeAccountMetrics = [:]
            claudeCodeAccountStates = [:]
            states[.claudeCode] = (.skipped, claudeCodeSkipReason(hasEnabledAccount: hasEnabledClaudeAccount))
        }

        foldUniformAccountPhase(
            .codexCli,
            result: codexResult,
            representative: { representativeCodexMetrics(from: $0.metrics) },
            storeAccountMetrics: { codexAccountMetrics = $0?.metrics ?? [:] },
            newMetrics: &newMetrics,
            states: &states
        )

        foldUniformAccountPhase(
            .grok,
            result: grokResult,
            representative: { representativeGrokMetrics(from: $0.metrics) },
            storeAccountMetrics: { grokAccountMetrics = $0?.metrics ?? [:] },
            newMetrics: &newMetrics,
            states: &states
        )

        foldUniformAccountPhase(
            .openRouter,
            result: openRouterResult,
            representative: { representativeOpenRouterMetrics(from: $0.metrics) },
            storeAccountMetrics: { openRouterAccountMetrics = $0?.metrics ?? [:] },
            newMetrics: &newMetrics,
            states: &states
        )

        // Simple (single-account) providers. On failure the final merge loop
        // below preserves any cached metrics (graceful degradation).
        newMetrics.merge(simpleResults.metrics) { _, refreshed in refreshed }
        states.merge(simpleResults.states) { _, refreshed in refreshed }

        // Merge new metrics with existing cached metrics for services that failed to fetch
        for service in ServiceType.allCases where providerVisibilityStore.isEnabled(service) {
            if service == .claudeCode, !hasEnabledClaudeAccount { continue }
            // Account caches are merged during their provider-specific refresh.
            if service == .codexCli || service == .grok || service == .openRouter { continue }
            if newMetrics[service] == nil, let cachedMetric = self.metrics[service] {
                newMetrics[service] = cachedMetric
            }
        }

        metrics = newMetrics
        publishMetrics()
        await accountFailoverCoordinator.evaluate(
            claudeMetrics: claudeCodeAccountMetrics,
            codexMetrics: codexAccountMetrics
        )

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
    private static let refreshContendedReason = "Another MeterBar refresh is already running."
    private static let refreshLockUnavailableReason = "The shared MeterBar refresh lock is unavailable."

    /// Folds one Codex/Grok/OpenRouter-shaped account phase into the committed
    /// snapshot: publish the fetch result and its representative, or clear the
    /// phase's caches and mark it skipped when it never ran (disabled or no
    /// enabled accounts). Claude has its own block above.
    private func foldUniformAccountPhase(
        _ service: ServiceType,
        result: AccountFetchResult?,
        representative: (AccountFetchResult) -> UsageMetrics?,
        storeAccountMetrics: (AccountFetchResult?) -> Void,
        newMetrics: inout [ServiceType: UsageMetrics],
        states: inout [ServiceType: (state: ProviderRefreshState, reason: String?)]
    ) {
        if let result {
            storeAccountMetrics(result)
            if let representative = representative(result) {
                newMetrics[service] = representative
            }
            states[service] = accountFetchState(result)
        } else {
            storeAccountMetrics(nil)
            states[service] = (
                .skipped,
                providerVisibilityStore.isEnabled(service) ? Self.noEnabledAccountsReason : Self.disabledReason
            )
        }
    }

    private enum RefreshLockLease {
        case acquired(WakeLock?)
        case skipped(reason: String)
    }

    /// `WakeLock.acquire()` includes filesystem work. Keep that work off the
    /// main actor even though `LOCK_NB` guarantees it never waits for a holder.
    private func acquireRefreshLock() async -> RefreshLockLease {
        guard refreshLockMode == .acquirePerRefresh else { return .acquired(nil) }
        let makeLock = refreshLockFactory
        let (lock, acquisition) = await Task.detached(priority: .userInitiated) {
            let lock = makeLock()
            return (lock, lock.acquire())
        }.value

        switch acquisition {
        case .acquired:
            return .acquired(lock)
        case .contended:
            AppLog.usage.info("Skipping provider refresh because the shared refresh lock is held.")
            return .skipped(reason: Self.refreshContendedReason)
        case let .legacyHeld(guidance):
            AppLog.usage.error("Skipping provider refresh because a legacy lock is held: \(guidance)")
            return .skipped(reason: Self.refreshLockUnavailableReason)
        case let .unavailable(reason):
            AppLog.usage.error("Skipping provider refresh because the lock is unavailable: \(reason)")
            return .skipped(reason: Self.refreshLockUnavailableReason)
        }
    }

    private func skippedRefreshReport(startedAt: Date, enabledReason: String) -> UsageRefreshReport {
        UsageRefreshReport(
            startedAt: startedAt,
            finishedAt: Date(),
            outcomes: ServiceType.allCases.map {
                ProviderRefreshOutcome(
                    provider: $0,
                    state: .skipped,
                    reason: providerVisibilityStore.isEnabled($0) ? enabledReason : Self.disabledReason,
                    servedFromCache: metrics[$0] != nil,
                    lastUpdated: metrics[$0]?.lastUpdated
                )
            }
        )
    }

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
        /// First failure in provider order. Reported back rather than written
        /// straight to `lastError` so the caller — not the scheduler — decides
        /// how this phase ranks against the ones racing alongside it.
        let firstFailure: Error?
    }

    private func refreshSimpleProviders() async -> SimpleProviderRefresh {
        var metrics: [ServiceType: UsageMetrics] = [:]
        var states: [ServiceType: (state: ProviderRefreshState, reason: String?)] = [:]
        var pending: [ServiceType] = []

        // Visibility and access are synchronous, so resolve them up front and
        // fan out only the legs that will actually reach a provider.
        // OpenRouter left this path for the account-aware fetcher.
        for service in [ServiceType.cursor] {
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

        // Fold in the original provider order so the reported failure stays
        // deterministic rather than reflecting whichever leg finished last.
        var firstFailure: Error?
        var refreshed: [ServiceType] = []
        for (service, leg) in zip(pending, legs) {
            if let fetched = leg.metrics {
                metrics[service] = fetched
                states[service] = (.refreshed, nil)
                refreshed.append(service)
            } else if let error = leg.error {
                if firstFailure == nil { firstFailure = error }
                let safeMessage = ServiceSupport.safeErrorMessage(for: error)
                let detail = "Failed to fetch \(service.rawValue) metrics: \(safeMessage)"
                AppLog.usage.error("\(detail, privacy: .public)")
                states[service] = (.failed, safeMessage)
            }
        }

        recordUsageObservations(for: refreshed)

        return SimpleProviderRefresh(metrics: metrics, states: states, firstFailure: firstFailure)
    }

    /// Folds this refresh's polled counters into the persisted ledger.
    ///
    /// A poll that is not recorded here is spend that can never reach the
    /// chart: neither provider serves dated history, so the delta between two
    /// consecutive polls is the only measurement of a day that exists, and it
    /// is gone once the next poll overwrites the counter in memory.
    ///
    /// Failure to persist is logged, not surfaced: the refresh itself
    /// succeeded, and the counters are running totals, so the next poll's delta
    /// spans the gap and no spend is lost — only its attribution to a
    /// particular day.
    private func recordUsageObservations(for services: [ServiceType]) {
        guard !demoMode, let store = usageLedgerStore else { return }
        let observations = services.compactMap { simpleProvider(for: $0)?.latestUsageObservation }
        guard !observations.isEmpty else { return }

        var ledger = store.load()
        for observation in observations {
            ledger.record(observation)
        }
        do {
            try store.save(ledger)
        } catch {
            AppLog.usage.error(
                "Failed to persist provider usage observations: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func simpleProvider(for service: ServiceType) -> SimpleUsageProviding? {
        switch service {
        case .cursor:
            return cursorService
        case .claudeCode, .codexCli, .grok, .openRouter:
            return nil
        }
    }

    /// Clears one provider's per-account caches (used on disable and when its
    /// enabled-account set becomes empty). Cursor has no account caches.
    private func clearAccountState(for service: ServiceType) {
        switch service {
        case .claudeCode:
            claudeCodeAccountMetrics = [:]
            claudeCodeAccountStates = [:]
        case .codexCli:
            codexAccountMetrics = [:]
        case .grok:
            grokAccountMetrics = [:]
        case .openRouter:
            openRouterAccountMetrics = [:]
        case .cursor:
            break
        }
    }

    /// How many enabled accounts back `service`'s fetch. `nil` for the
    /// single-account providers, which have no empty-set early-out.
    private func enabledAccountCount(for service: ServiceType) -> Int? {
        switch service {
        case .claudeCode:
            return claudeCodeAccountStore.enabledAccounts.count
        case .codexCli:
            return codexAccountStore.enabledAccounts.count
        case .grok:
            return grokAccountStore.enabledAccounts.count
        case .openRouter:
            return openRouterAccountStore.enabledAccounts.count
        case .cursor:
            return nil
        }
    }

    func refresh(service: ServiceType) async {
        guard !demoMode else { return }
        lastMeterBarInteractionAt = adaptiveNow()
        defer { rescheduleAdaptiveRefreshIfNeeded() }
        guard !isLoading else { return }
        guard case let .acquired(refreshLock) = await acquireRefreshLock() else { return }
        defer { refreshLock?.release() }
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        guard providerVisibilityStore.isEnabled(service) else {
            metrics.removeValue(forKey: service)
            clearAccountState(for: service)
            publishMetrics()
            return
        }

        // Every account-aware provider with zero enabled accounts has nothing
        // to fetch; Cursor (single-account) never takes this early-out.
        if enabledAccountCount(for: service) == 0 {
            clearAccountState(for: service)
            metrics.removeValue(forKey: service)
            publishMetrics()
            return
        }

        do {
            let newMetrics = try await refreshedMetrics(for: service)

            metrics[service] = newMetrics
            publishMetrics()
        } catch {
            if lastError == nil {
                lastError = error
            }
            if service == .codexCli || service == .grok || service == .openRouter {
                // Account-aware aggregate metrics carry no account identity. Scoped
                // per-account caches are restored inside the provider fetcher;
                // if none exist, showing no data is safer than relabeling a
                // different profile's stale quota.
                metrics.removeValue(forKey: service)
                publishMetrics()
            } else if metrics[service] == nil {
                // Preserve existing cached metrics for single-account services.
                if let cachedData = loadCachedMetricsFromDisk()[service] {
                    metrics[service] = cachedData
                    // Restoring from cache still changes what subscribers see,
                    // so it publishes like any other committed snapshot.
                    publishMetrics()
                }
            }
        }
    }

    /// Refreshes one Claude profile without touching its peers.
    ///
    /// Settings uses this for the per-account arrow action. The provider-level
    /// refresh continues to fan out across every enabled profile.
    func refreshClaudeCodeAccount(id: UUID) async {
        guard !demoMode, !isLoading else { return }
        guard providerVisibilityStore.isEnabled(.claudeCode),
              let account = claudeCodeAccountStore.enabledAccounts.first(where: { $0.id == id }) else {
            return
        }
        guard case let .acquired(refreshLock) = await acquireRefreshLock() else { return }
        defer { refreshLock?.release() }

        isLoading = true
        defer { isLoading = false }
        lastError = nil

        let fetch = await fetchClaudeCodeAccountMetrics(
            accounts: [account],
            trigger: .userInitiated,
            recordsProviderHealth: false
        )

        if let refreshed = fetch.metrics[id] {
            claudeCodeAccountMetrics[id] = refreshed
        } else {
            claudeCodeAccountMetrics.removeValue(forKey: id)
        }

        if let state = fetch.accountStates[id] {
            claudeCodeAccountStates[id] = state
        } else {
            claudeCodeAccountStates.removeValue(forKey: id)
        }

        lastError = fetch.firstFailure
        if let representative = representativeClaudeCodeMetrics(from: claudeCodeAccountMetrics) {
            metrics[.claudeCode] = representative
        } else {
            metrics.removeValue(forKey: .claudeCode)
        }
        publishMetrics()
    }

    /// A delayed repeating timer does not replay missed ticks after sleep. The
    /// workspace wake hook calls this method once; it catches up only when an
    /// enabled source has no data or its oldest successful snapshot is at least
    /// ten minutes old. Manual-only mode remains fully manual.
    func refreshAfterWakeIfNeeded(now: Date = Date()) async {
        guard !demoMode else { return }
        guard refreshInterval != .manual, await shouldCatchUpAfterWake(now: now) else { return }
        await refreshAll(trigger: .background)
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
        publishMetrics()
    }

    /// Installs the post-redemption Grok usage response into the same caches
    /// used by the popover, dashboard, widget, and CLI.
    func applyGrokResetCreditRefresh(_ refreshedMetrics: UsageMetrics, accountID: UUID) {
        guard !demoMode else { return }
        grokAccountMetrics[accountID] = refreshedMetrics
        if let representative = representativeGrokMetrics(from: grokAccountMetrics) {
            metrics[.grok] = representative
        }
        lastError = nil
        publishMetrics()
    }

    private func refreshedMetrics(for service: ServiceType) async throws -> UsageMetrics {
        switch service {
        case .cursor:
            return try await refreshedCursorMetrics()
        case .claudeCode, .codexCli, .grok, .openRouter:
            return try await refreshedAccountAwareMetrics(for: service)
        }
    }

    /// Cursor's single-account refresh with cache-preserving degradation.
    private func refreshedCursorMetrics() async throws -> UsageMetrics {
        guard hasProviderAccess(.cursor) else { throw ServiceError.notAuthenticated }
        do {
            return try await fetchSimpleProviderMetrics(.cursor)
        } catch {
            if let cachedMetric = metrics[.cursor] {
                lastError = error
                return cachedMetric
            }
            throw error
        }
    }

    /// The account-aware providers' per-service refresh. Each account fetcher
    /// reports its first failure instead of writing `lastError` itself (see
    /// `refreshAll`), so this path surfaces it.
    private func refreshedAccountAwareMetrics(for service: ServiceType) async throws -> UsageMetrics {
        switch service {
        case .claudeCode:
            let fetch = await fetchClaudeCodeAccountMetrics(trigger: .userInitiated)
            claudeCodeAccountMetrics = fetch.metrics
            claudeCodeAccountStates = fetch.accountStates
            if let failure = fetch.firstFailure { lastError = failure }
            if let representative = representativeClaudeCodeMetrics(from: fetch.metrics) { return representative }
        case .codexCli:
            let fetch = await fetchCodexAccountMetrics()
            codexAccountMetrics = fetch.metrics
            if let failure = fetch.firstFailure { lastError = failure }
            if let representative = representativeCodexMetrics(from: fetch.metrics) { return representative }
            throw ServiceError.notAuthenticated
        case .grok:
            let fetch = await fetchGrokAccountMetrics()
            grokAccountMetrics = fetch.metrics
            if let failure = fetch.firstFailure { lastError = failure }
            if let representative = representativeGrokMetrics(from: fetch.metrics) { return representative }
            throw ServiceError.notAuthenticated
        case .openRouter:
            let fetch = await fetchOpenRouterAccountMetrics()
            openRouterAccountMetrics = fetch.metrics
            if let failure = fetch.firstFailure { lastError = failure }
            if let representative = representativeOpenRouterMetrics(from: fetch.metrics) { return representative }
            throw ServiceError.notAuthenticated
        case .cursor:
            preconditionFailure("Cursor uses refreshedCursorMetrics")
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

    /// Persist and broadcast the current snapshot. Every mutation that changes
    /// what an observer would see funnels through here, so the three caches can
    /// never drift apart and `refreshGeneration` advances exactly once per
    /// committed change — which is what the notification layer subscribes to.
    private func publishMetrics() {
        let quotaMoved = recordQuotaMovement()
        saveCachedData()
        saveCachedAccountMetrics()
        saveSharedData(metrics)
        refreshGeneration &+= 1
        // Codex reset-credit and other publish-only paths skip the refresh
        // methods' adaptive defer, so reschedule here when movement is real.
        if quotaMoved {
            rescheduleAdaptiveRefreshIfNeeded()
        }
    }

    private func saveCachedData() {
        if let data = MetricsCodec.encode(metrics) {
            cacheDefaults.set(data, forKey: cacheKey)
        }
    }

    private func loadCachedAccountMetrics() {
        claudeCodeAccountMetrics = Self.decodedAccountCache(
            StorageKeys.cachedClaudeCodeAccountMetrics, in: cacheDefaults
        ) ?? claudeCodeAccountMetrics
        codexAccountMetrics = Self.decodedAccountCache(
            StorageKeys.cachedCodexAccountMetrics, in: cacheDefaults
        ) ?? codexAccountMetrics
        grokAccountMetrics = Self.decodedAccountCache(
            StorageKeys.cachedGrokAccountMetrics, in: cacheDefaults
        ) ?? grokAccountMetrics
        openRouterAccountMetrics = Self.decodedAccountCache(
            StorageKeys.cachedOpenRouterAccountMetrics, in: cacheDefaults
        ) ?? openRouterAccountMetrics

        guard claudeCodeAccountMetrics.isEmpty
            || codexAccountMetrics.isEmpty
            || grokAccountMetrics.isEmpty
            || openRouterAccountMetrics.isEmpty else {
            return
        }
        let sharedSnapshots = sharedStore.loadAccountMetrics()
        if claudeCodeAccountMetrics.isEmpty {
            claudeCodeAccountMetrics = Self.sharedFallback(.claudeCode, from: sharedSnapshots)
        }
        if codexAccountMetrics.isEmpty {
            codexAccountMetrics = Self.sharedFallback(.codexCli, from: sharedSnapshots)
        }
        if grokAccountMetrics.isEmpty {
            grokAccountMetrics = Self.sharedFallback(.grok, from: sharedSnapshots)
        }
        if openRouterAccountMetrics.isEmpty {
            openRouterAccountMetrics = Self.sharedFallback(.openRouter, from: sharedSnapshots)
        }
    }

    private static func decodedAccountCache(
        _ key: String,
        in defaults: UserDefaults
    ) -> [UUID: UsageMetrics]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([UUID: UsageMetrics].self, from: data)
    }

    private static func sharedFallback(
        _ service: ServiceType,
        from snapshots: [AccountUsageSnapshot]
    ) -> [UUID: UsageMetrics] {
        Dictionary(
            uniqueKeysWithValues: snapshots
                .filter { $0.metrics.service == service }
                .map { ($0.id, $0.metrics) }
        )
    }

    private func saveCachedAccountMetrics() {
        if let data = try? JSONEncoder().encode(claudeCodeAccountMetrics) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedClaudeCodeAccountMetrics)
        }
        if let data = try? JSONEncoder().encode(codexAccountMetrics) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedCodexAccountMetrics)
        }
        if let data = try? JSONEncoder().encode(grokAccountMetrics) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedGrokAccountMetrics)
        }
        if let data = try? JSONEncoder().encode(openRouterAccountMetrics) {
            cacheDefaults.set(data, forKey: StorageKeys.cachedOpenRouterAccountMetrics)
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
        let grokSnapshots = grokAccountStore.enabledAccounts.compactMap { account -> AccountUsageSnapshot? in
            guard let metrics = grokAccountMetrics[account.id] else { return nil }
            return AccountUsageSnapshot(id: account.id, name: account.name, metrics: metrics)
        }
        let openRouterSnapshots: [AccountUsageSnapshot] = openRouterAccountStore.enabledAccounts.compactMap { account in
            guard let metrics = openRouterAccountMetrics[account.id] else { return nil }
            return AccountUsageSnapshot(id: account.id, name: account.name, metrics: metrics)
        }
        let accountSnapshots = claudeSnapshots + codexSnapshots + grokSnapshots + openRouterSnapshots
        sharedStore.saveAccountMetrics(accountSnapshots)
    }

    private func setupAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        scheduledRefreshInterval = nil
        scheduledRefreshRepeats = false

        switch refreshInterval {
        case .manual:
            effectiveRefreshReason = "Automatic refresh is disabled."
            return
        case .adaptive:
            let decision = adaptiveRefreshEngine.decision(signals: adaptiveSignals())
            installRefreshTimer(interval: decision.interval, repeats: false)
            effectiveRefreshReason = decision.reason.displayText
        default:
            let interval = refreshInterval.seconds
            installRefreshTimer(interval: interval, repeats: true)
            effectiveRefreshReason = "Fixed interval selected."
        }
    }

    private func installRefreshTimer(interval: TimeInterval, repeats: Bool) {
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll(trigger: .background)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        scheduledRefreshInterval = interval
        scheduledRefreshRepeats = repeats
    }

    private func rescheduleAdaptiveRefreshIfNeeded() {
        guard refreshInterval == .adaptive else { return }
        setupAutoRefresh()
    }

    private func observeAdaptivePowerChanges() {
        let center = NotificationCenter.default
        Publishers.Merge(
            center.publisher(for: .NSProcessInfoPowerStateDidChange),
            center.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, self.refreshInterval == .adaptive else { return }
            self.objectWillChange.send()
            self.rescheduleAdaptiveRefreshIfNeeded()
        }
        .store(in: &cadenceCancellables)
    }

    private func adaptiveSignals() -> AdaptiveRefreshSignals {
        AdaptiveRefreshSignals(
            lastInteractionAt: lastMeterBarInteractionAt,
            lastQuotaMovementAt: lastQuotaMovementAt,
            power: adaptivePowerState()
        )
    }

    @discardableResult
    private func recordQuotaMovement() -> Bool {
        let latest = makeAdaptiveQuotaSnapshot()
        let moved = adaptiveQuotaSnapshot.hasMovement(comparedTo: latest)
        if moved {
            lastQuotaMovementAt = adaptiveNow()
        }
        adaptiveQuotaSnapshot = latest
        return moved
    }

    private func makeAdaptiveQuotaSnapshot() -> AdaptiveQuotaSnapshot {
        var values: [String: Double] = [:]

        func collect(_ metrics: UsageMetrics, prefix: String) {
            if let limit = metrics.sessionLimit {
                values["\(prefix).session"] = limit.used
            }
            if let limit = metrics.weeklyLimit {
                values["\(prefix).weekly"] = limit.used
            }
            if let limit = metrics.codeReviewLimit {
                values["\(prefix).model"] = limit.used
            }
        }

        for (service, providerMetrics) in metrics {
            collect(providerMetrics, prefix: service.rawValue)
        }
        for (accountID, accountMetrics) in claudeCodeAccountMetrics {
            collect(accountMetrics, prefix: "claude.\(accountID.uuidString)")
        }
        for (accountID, accountMetrics) in codexAccountMetrics {
            collect(accountMetrics, prefix: "codex.\(accountID.uuidString)")
        }
        for (accountID, accountMetrics) in grokAccountMetrics {
            collect(accountMetrics, prefix: "grok.\(accountID.uuidString)")
        }
        for (accountID, accountMetrics) in openRouterAccountMetrics {
            collect(accountMetrics, prefix: "openrouter.\(accountID.uuidString)")
        }
        return AdaptiveQuotaSnapshot(values: values)
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

        if providerVisibilityStore.isEnabled(.grok),
           !grokAccountStore.enabledAccounts.isEmpty {
            for account in grokAccountStore.enabledAccounts where grokService.canAccess(account: account) {
                collect(grokAccountMetrics[account.id])
            }
        }

        if providerVisibilityStore.isEnabled(.openRouter),
           !openRouterAccountStore.enabledAccounts.isEmpty {
            for account in openRouterAccountStore.enabledAccounts
            where openRouterService.canAccess(account: account) {
                collect(openRouterAccountMetrics[account.id])
            }
        }

        for service in [ServiceType.cursor]
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
        /// Claude-only; defaulted because the Codex path shares this type and
        /// has no per-account auth state of its own.
        var accountStates: [UUID: ClaudeCodeAuthState] = [:]
    }

    /// Sentinel that lets the `canAccess` probe move inside the concurrent leg
    /// while still folding back to today's plain-skip semantics: an unreachable
    /// account contributes no metrics, no cached fallback, and no failure.
    private struct CodexAccountUnreachable: Error {}
    private struct GrokAccountUnreachable: Error {}
    /// A key with no Keychain item: a skip, not a failure — the account exists
    /// but its credential was never entered (or was removed).
    private struct OpenRouterKeyUnreachable: Error {}

    private func claudeAccountFetch(
        isEnabled: Bool,
        trigger: ClaudeTokenRefreshTrigger
    ) async -> AccountFetchResult? {
        guard isEnabled else { return nil }
        return await fetchClaudeCodeAccountMetrics(trigger: trigger)
    }

    private func codexAccountFetch(isEnabled: Bool) async -> AccountFetchResult? {
        guard isEnabled else { return nil }
        return await fetchCodexAccountMetrics()
    }

    private func grokAccountFetch(isEnabled: Bool) async -> AccountFetchResult? {
        guard isEnabled else { return nil }
        return await fetchGrokAccountMetrics()
    }

    private func openRouterAccountFetch(isEnabled: Bool) async -> AccountFetchResult? {
        guard isEnabled else { return nil }
        return await fetchOpenRouterAccountMetrics()
    }

    private func fetchClaudeCodeAccountMetrics(
        accounts: [ClaudeCodeAccount]? = nil,
        trigger: ClaudeTokenRefreshTrigger,
        recordsProviderHealth: Bool = true
    ) async -> AccountFetchResult {
        let enabledAccounts = accounts ?? claudeCodeAccountStore.enabledAccounts
        var refreshedMetrics: [UUID: UsageMetrics] = [:]
        var accountStates: [UUID: ClaudeCodeAuthState] = [:]
        var firstFailure: Error?
        var successCount = 0

        let legs = await fanOut(count: enabledAccounts.count) { [enabledAccounts] index in
            try await self.claudeCodeService.fetchUsageMetrics(
                account: enabledAccounts[index],
                trigger: trigger
            )
        }

        let serviceStates = claudeCodeService.accountAuthStates

        // Fold in account-store order, never completion order, so `firstFailure`
        // (and therefore the surfaced reason) is stable across runs. `zip`
        // rather than subscripting: a count mismatch truncates instead of trapping.
        for (account, leg) in zip(enabledAccounts, legs) {
            var cachedLastUpdated: Date?
            if let metrics = leg.metrics {
                refreshedMetrics[account.id] = metrics
                successCount += 1
            } else if let error = leg.error {
                if firstFailure == nil { firstFailure = error }
                if let cachedMetrics = claudeCodeAccountMetrics[account.id] {
                    // Keeping the numbers is deliberate — an empty card is worse
                    // than an old one — but they are only honest alongside the
                    // state resolved below, which says how old and why.
                    refreshedMetrics[account.id] = cachedMetrics
                    cachedLastUpdated = cachedMetrics.lastUpdated
                }
            }
            accountStates[account.id] = ClaudeAccountStateResolver.state(
                serviceState: serviceStates[account.id],
                didSucceed: leg.metrics != nil,
                failure: leg.error,
                cachedLastUpdated: cachedLastUpdated
            )
        }

        // Parse health tracks integration health, not per-account health:
        // if any account parses, the format contract still holds, so one
        // failing account must not dim the whole provider.
        if recordsProviderHealth {
            if successCount > 0 {
                parseHealthStore.recordSuccess(.claudeCode)
            } else if let firstFailure {
                parseHealthStore.recordFailure(.claudeCode, error: firstFailure)
            }
        }

        return AccountFetchResult(
            metrics: refreshedMetrics,
            successCount: successCount,
            firstFailure: firstFailure,
            accountStates: accountStates
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

    private func fetchGrokAccountMetrics() async -> AccountFetchResult {
        let enabledAccounts = grokAccountStore.enabledAccounts
        var refreshedMetrics: [UUID: UsageMetrics] = [:]
        var firstFailure: Error?
        var successCount = 0

        let legs = await fanOut(count: enabledAccounts.count) { [enabledAccounts] index in
            let account = enabledAccounts[index]
            guard self.grokService.canAccess(account: account) else {
                throw GrokAccountUnreachable()
            }
            return try await self.grokService.fetchUsageMetrics(account: account)
        }

        for (account, leg) in zip(enabledAccounts, legs) {
            if let metrics = leg.metrics {
                refreshedMetrics[account.id] = metrics
                successCount += 1
            } else if let error = leg.error {
                if error is GrokAccountUnreachable { continue }
                if firstFailure == nil { firstFailure = error }
                if let cachedMetrics = grokAccountMetrics[account.id] {
                    refreshedMetrics[account.id] = cachedMetrics
                }
            }
        }

        if successCount > 0 {
            parseHealthStore.recordSuccess(.grok)
        } else if let firstFailure {
            parseHealthStore.recordFailure(.grok, error: firstFailure)
        }

        return AccountFetchResult(
            metrics: refreshedMetrics,
            successCount: successCount,
            firstFailure: firstFailure
        )
    }

    private func representativeGrokMetrics(from accountMetrics: [UUID: UsageMetrics]) -> UsageMetrics? {
        if grokAccountStore.defaultAccountIsEnabled,
           let defaultMetrics = accountMetrics[GrokAccount.defaultID] {
            return defaultMetrics
        }
        return grokAccountStore.enabledAccounts.lazy.compactMap { accountMetrics[$0.id] }.first
    }

    private func fetchOpenRouterAccountMetrics() async -> AccountFetchResult {
        let enabledAccounts = openRouterAccountStore.enabledAccounts
        var refreshedMetrics: [UUID: UsageMetrics] = [:]
        var firstFailure: Error?
        var successCount = 0
        // Keys that succeeded *this poll*. Only their observations fold into
        // the ledger — a key that failed keeps a stale counter from an earlier
        // poll, and summing it in would look like spend moved when it didn't.
        var polledObservations: [ProviderUsageObservation] = []

        let legs = await fanOut(count: enabledAccounts.count) { [enabledAccounts] index in
            let account = enabledAccounts[index]
            guard self.openRouterService.canAccess(account: account) else {
                throw OpenRouterKeyUnreachable()
            }
            return try await self.openRouterService.fetchUsageMetrics(account: account)
        }

        for (account, leg) in zip(enabledAccounts, legs) {
            if let metrics = leg.metrics {
                refreshedMetrics[account.id] = metrics
                successCount += 1
                if let observation = openRouterService.latestAccountObservations[account.id] {
                    polledObservations.append(observation)
                }
            } else if let error = leg.error {
                // A keyless account is a skip, not a failure, and must not
                // resurrect a stale cache — same semantics as Codex/Grok.
                if error is OpenRouterKeyUnreachable { continue }
                if firstFailure == nil { firstFailure = error }
                if let cachedMetrics = openRouterAccountMetrics[account.id] {
                    refreshedMetrics[account.id] = cachedMetrics
                }
            }
        }

        if successCount > 0 {
            parseHealthStore.recordSuccess(.openRouter)
        } else if let firstFailure {
            parseHealthStore.recordFailure(.openRouter, error: firstFailure)
        }

        recordOpenRouterLedgerObservation(
            polledObservations,
            allowsAuthoritativeDaily: successCount == enabledAccounts.count
        )

        return AccountFetchResult(
            metrics: refreshedMetrics,
            successCount: successCount,
            firstFailure: firstFailure
        )
    }

    /// Folds this poll's per-key spend readings into the single provider-wide
    /// ledger entry. Only keys that succeeded this poll contribute; the sum of
    /// a partial poll is still honest because each key's counter is its own.
    private func recordOpenRouterLedgerObservation(
        _ observations: [ProviderUsageObservation],
        allowsAuthoritativeDaily: Bool
    ) {
        guard !demoMode, let store = usageLedgerStore, !observations.isEmpty else { return }
        guard let aggregated = OpenRouterService.aggregatedObservation(
            observations,
            observedAt: Date(),
            allowsAuthoritativeDaily: allowsAuthoritativeDaily
        ) else {
            return
        }

        var ledger = store.load()
        ledger.record(aggregated)
        do {
            try store.save(ledger)
        } catch {
            AppLog.usage.error(
                "Failed to persist provider usage observations: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func representativeOpenRouterMetrics(from accountMetrics: [UUID: UsageMetrics]) -> UsageMetrics? {
        if openRouterAccountStore.defaultAccountIsEnabled,
           let defaultMetrics = accountMetrics[OpenRouterAccount.defaultID] {
            return defaultMetrics
        }
        return openRouterAccountStore.enabledAccounts.lazy.compactMap { accountMetrics[$0.id] }.first
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
            // Access means at least one enabled key has its Keychain item.
            return openRouterAccountStore.enabledAccounts.contains {
                openRouterService.canAccess(account: $0)
            }
        case .grok:
            return false
        }
    }

    /// Fetch for the providers without multi-account handling (Claude Code,
    /// Codex, Grok, and OpenRouter have their own account-aware paths).
    private func fetchSimpleProviderMetrics(_ service: ServiceType) async throws -> UsageMetrics {
        do {
            let result: UsageMetrics
            switch service {
            case .cursor:
                result = try await cursorService.fetchUsageMetrics()
            case .claudeCode, .codexCli, .grok, .openRouter:
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
