import Combine
import MeterBarShared
import Foundation
import os

/// Publishes the cost summary the UI renders and owns its cache.
///
/// The scanning itself lives in focused collaborators (audit C1d): `CostWindow`
/// for the reporting boundary, `ClaudeCostScanner` and `CodexCostScanner` for
/// the per-provider log reads, `CostSummaryBuilder` for folding both windows
/// into a `CostSummary`.
class CostTracker: ObservableObject {
    static let shared = CostTracker(demoMode: DemoMode.isActive)

    @Published var costSummary: CostSummary?
    @Published var isScanning: Bool = false
    @Published var isRefreshingMissingDays: Bool = false
    @Published var lastScanDate: Date?

    /// Polled running counters, accumulated into a dated series.
    ///
    /// Published separately from `costSummary` because it refreshes on a
    /// different clock: `UsageDataManager` appends to the artifact on every
    /// provider poll, while `costSummary` is rebuilt only by a scan. Folding
    /// this into the scan alone would leave the request series days stale.
    ///
    /// Its dollar-denominated entries still travel through `costSummary` — see
    /// `ProviderUsageCostBuilder`. What only lives here is the part that has no
    /// honest place in `costs[]`: Cursor's request counter.
    @Published private(set) var usageLedger = ProviderUsageLedger()

    private let providerVisibilityStore = ProviderVisibilityStore.shared

    /// When true, the tracker publishes the synthetic `DemoData.costSummary`
    /// fixture and performs no real log scans or cache writes. Gated at `shared`
    /// on `DemoMode.isActive`.
    private let demoMode: Bool

    /// True while either a manual scan or a background missing-day backfill runs.
    var isRefreshInProgress: Bool {
        isScanning || isRefreshingMissingDays
    }

    init(demoMode: Bool = false) {
        self.demoMode = demoMode
        guard !demoMode else {
            // Publish the synthetic fixture; never read the real cache or scan
            // real CLI logs. Real cost data on disk is left untouched.
            costSummary = DemoData.costSummary()
            lastScanDate = Date()
            return
        }
        loadCachedSummary()
        refreshUsageLedger()
    }

    /// Re-reads the polled series from disk.
    ///
    /// Cheap enough to call on every Costs view appearance: one small JSON read,
    /// no log scan. Called from there rather than only at init because
    /// `UsageDataManager` writes the artifact from its own refresh cycle, so the
    /// copy loaded at launch goes stale within a poll interval.
    func refreshUsageLedger() {
        guard !demoMode else { return }
        usageLedger = ProviderUsageLedgerStore.applicationSupport?
            .load()
            .filtered(to: providerVisibilityStore.enabledServices) ?? ProviderUsageLedger()
    }

    /// What a `scanCosts` call actually did, for callers that stamp a timestamp
    /// or otherwise present the totals as freshly read.
    enum ScanOutcome: Sendable {
        /// Demo mode, or another scan/backfill already held the tracker, so no
        /// log was read and the published totals are exactly as stale as before.
        case skipped
        /// Slices ran, but the scan stopped before it saw the whole corpus, so
        /// the published totals are an undercount that later slices will raise.
        case partial
        /// A scan saw the whole corpus.
        case completed

        /// True only when the published totals came from a scan that finished.
        var isAuthoritative: Bool { self == .completed }
    }

    @discardableResult
    func scanCosts(days: Int = 30) async -> ScanOutcome {
        guard !demoMode else { return .skipped }
        let shouldStart = await MainActor.run {
            guard !isRefreshInProgress else { return false }
            isScanning = true
            return true
        }
        guard shouldStart else { return .skipped }

        let scan = await makeCostSummary(days: days)

        return await MainActor.run {
            apply(scan)
            isScanning = false
            return scan?.isComplete == true ? .completed : .partial
        }
    }

    /// Quietly backfills a legacy cache's missing lifetime snapshot or missing
    /// daily rows when Overview/Costs opens, without the visible "Scanning" UI
    /// a manual scan shows.
    func refreshMissingDaysInBackground(days: Int = 30) async {
        guard !demoMode else { return }
        let shouldStart = await MainActor.run {
            guard !isRefreshInProgress,
                  let visibleSummary = costSummary?.filtered(to: providerVisibilityStore.enabledServices),
                  visibleSummary.lifetime == nil
                    || visibleSummary.needsMissingDailyUsageRefresh(days: days, lastScanDate: lastScanDate) else {
                return false
            }
            isRefreshingMissingDays = true
            return true
        }
        guard shouldStart else { return }

        let scan = await makeCostSummary(days: days)

        await MainActor.run {
            apply(scan)
            isRefreshingMissingDays = false
        }
    }

    /// Publishes one refresh's result, and records it as authoritative only when
    /// it saw the whole corpus.
    ///
    /// An incomplete scan still publishes its partial total — the number on
    /// screen should improve as slices land — but must not touch `lastScanDate`
    /// or the cache. Both are read elsewhere as "a full scan finished":
    /// `saveCachedSummary` makes the partial survive relaunch, and
    /// `needsMissingDailyUsageRefresh` returns `false` for the rest of the
    /// calendar day once `lastScanDate` is today. Stamping a budget-truncated
    /// slice would therefore freeze an undercount on screen until tomorrow —
    /// exactly the failure the resumable offsets exist to avoid.
    ///
    /// `nil` means no slice completed at all, so there is nothing to publish and
    /// nothing has been learned.
    @MainActor
    func apply(_ scan: CostSummaryBuilder.CostSummaryScan?) {
        guard let scan else { return }
        costSummary = scan.summary
        guard scan.isComplete else { return }
        lastScanDate = Date()
        saveCachedSummary()
    }

    /// Backstop against a refresh that never reports completion.
    ///
    /// Every slice that defers work has, by construction, spent budget reading
    /// bytes — so the loop terminates on its own after ~20 slices on a cold
    /// 10 GB corpus. This bound only exists so a corrupted cache or a
    /// pathological transcript cannot pin the scan queue indefinitely; hitting
    /// it costs nothing but a later refresh finishing the remainder.
    private static let maxScanSlices = 64

    /// Scans the corpus in budgeted slices, publishing after each one.
    ///
    /// The slices run on `CostScanExecutor`'s serial queue rather than a
    /// detached `Task`: the work is blocking disk I/O, and a detached task
    /// holds a cooperative-pool thread hostage while it waits on `read(2)`
    /// (see the header of `CostScanExecutor` for the full rationale). Between
    /// slices the queue is free, so a cancelled refresh — the user closing the
    /// menu, or a second scan starting — stops at the next file boundary
    /// instead of after the whole corpus.
    ///
    /// - Returns: the last slice's result, or `nil` when the refresh was
    ///   cancelled before a single slice finished. The `isComplete` flag rides
    ///   along because the caller must not record a budget-truncated total as a
    ///   finished scan — see `apply(_:)`.
    private func makeCostSummary(days: Int) async -> CostSummaryBuilder.CostSummaryScan? {
        // Read off `CostScanProvider` itself rather than a hand-listed set, so a
        // provider added to the enum reaches the scan without a second edit here.
        let enabledProviders = Set(
            CostScanProvider.allCases.filter { providerVisibilityStore.isEnabled($0.service) }
        )
        let claudeAccounts = ClaudeCodeAccountStore.shared.accounts
        // Every configured account, not just the enabled ones — matching the
        // Claude line above. Both scanners are looking for the home directories
        // spend was written to, and disabling an account hides its quota gauge
        // without unspending what it already cost.
        let grokAccounts = GrokAccountStore.shared.accounts
        let cutoff = CostWindow.start(days: days)
        let store = CostScanCacheStore.applicationSupport
        // Read once, outside the slice loop: polling providers contribute no
        // bytes, so their rows are identical in every slice and re-reading the
        // artifact 64 times would buy nothing. Refreshed here rather than
        // reused as-is so a scan never folds in a ledger older than itself.
        refreshUsageLedger()
        let usageLedger = usageLedger
        var latest: CostSummaryBuilder.CostSummaryScan?

        for _ in 0..<Self.maxScanSlices {
            let slice = try? await CostScanExecutor.run { token in
                let session = CostScanSession(
                    cutoff: cutoff,
                    options: .default,
                    store: store,
                    token: token
                )
                let scan = CostSummaryBuilder.makeScan(
                    days: days,
                    enabledProviders: enabledProviders,
                    claudeAccounts: claudeAccounts,
                    grokAccounts: grokAccounts,
                    session: session,
                    usageLedger: usageLedger
                )
                // Persist even when the slice was cut short: offsets commit on
                // line boundaries, so partial progress is exactly what the next
                // slice needs to resume from.
                return ScanSlice(scan: scan, persistence: session.persist())
            }
            // Cancelled. Whatever earlier slices published stands, and the
            // offsets they committed are already on disk.
            guard let slice else { break }

            latest = slice.scan
            if slice.scan.isComplete { break }
            // Publish the partial total so the number on screen improves with
            // every slice instead of only when the last one lands.
            await MainActor.run { costSummary = slice.scan.summary }

            guard Self.shouldRunAnotherSlice(after: slice.scan, persistence: slice.persistence) else {
                Self.logStoppedScan(slice)
                break
            }
        }

        return latest
    }

    /// One budgeted slice: what it computed, and whether the next one can pick
    /// up where it stopped.
    private struct ScanSlice: Sendable {
        let scan: CostSummaryBuilder.CostSummaryScan
        let persistence: CostScanPersistReport
    }

    /// Whether another slice can improve on the one that just finished.
    ///
    /// A provider that could not write its cache — or had no store to write it
    /// to — left that artifact exactly as it found it, so the next slice would
    /// re-read the same bytes, defer in the same place, and fail to persist
    /// again — 63 times over, pinning the scan queue for nothing.
    ///
    /// Asked per provider because the two caches fail independently: a blocked
    /// Claude write must neither end Codex's scan while Codex is still resuming,
    /// nor keep the loop alive once Codex has finished and Claude is the only
    /// one still deferring. Stopping costs one refresh — the next one retries
    /// the write from the last durable offsets.
    static func shouldRunAnotherSlice(
        after scan: CostSummaryBuilder.CostSummaryScan,
        persistence: CostScanPersistReport
    ) -> Bool {
        scan.deferredProviders.contains { persistence.outcome(for: $0) == .persisted }
    }

    private static func logStoppedScan(_ slice: ScanSlice) {
        for provider in slice.scan.deferredProviders {
            let name = provider.logName
            switch slice.persistence.outcome(for: provider) {
            case .persisted:
                continue
            case .unavailable:
                AppLog.cost.error(
                    """
                    Stopping the \(name, privacy: .public) cost scan: no cache store, \
                    so every slice would re-read the corpus from zero
                    """
                )
            case .failed:
                AppLog.cost.error(
                    """
                    Stopping the \(name, privacy: .public) cost scan: this slice's progress \
                    was not persisted, so no later slice can resume
                    """
                )
            }
        }
    }

    private func loadCachedSummary() {
        guard let cache = CostSummaryStore.load() else { return }
        costSummary = cache.summary
        lastScanDate = cache.lastScanDate
    }

    private func saveCachedSummary() {
        guard !demoMode else { return }
        guard let costSummary, let lastScanDate else { return }

        do {
            try CostSummaryStore.save(CostSummaryCache(summary: costSummary, lastScanDate: lastScanDate))
        } catch {
            AppLog.cost.error("Failed to save cost summary cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
