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
    /// What this refresh listed and how far it has got. `nil` when idle.
    @Published var scanProgress: CostScanProgress?

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
    func scanCosts(days: Int = CostWindow.scanWindowDays) async -> ScanOutcome {
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
            scanProgress = nil
            return scan?.isComplete == true ? .completed : .partial
        }
    }

    /// Resolves a summary safe for private-CloudKit publication. Missing daily
    /// coverage and caches written before daily cache-creation tokens existed
    /// are not evidence; the first opt-in replaces either with a completed scan.
    /// If that scan cannot complete, the caller must stay local-only.
    func prepareSummaryForICloudPublication(
        _ candidate: CostSummary?
    ) async -> ICloudUsageSummaryPreparationResult {
        let outcome = await scanCosts(
            days: max(CostWindow.scanWindowDays, candidate?.periodDays ?? CostWindow.scanWindowDays)
        )
        switch outcome {
        case .skipped:
            return .skipped
        case .partial:
            return .partial
        case .completed:
            guard let summary = costSummary,
                  summary.hasAuthoritativeDailyCacheCreationTokens else {
                return .failed
            }
            return .completed(summary)
        }
    }

    /// Quietly backfills missing daily or hourly rows when Overview/Costs
    /// opens, without the visible "Scanning" UI a manual scan shows.
    ///
    /// A missing lifetime snapshot is not a reason to rescan. Lifetime is no
    /// longer published; treating `lifetime == nil` as incomplete was what
    /// walked multi-gigabyte archives on every Costs open.
    func refreshMissingDaysInBackground(days: Int = CostWindow.scanWindowDays) async {
        guard !demoMode else { return }

        guard let snapshot = await MainActor.run(body: { () -> (CostSummary?, Date?, Set<ServiceType>)? in
            guard !isRefreshInProgress else { return nil }
            return (costSummary, lastScanDate, providerVisibilityStore.enabledServices)
        }) else { return }
        let (summary, scanDate, enabledServices) = snapshot

        // The filesystem walk `needsBackgroundRefresh` can require is the
        // expensive half of this gate (issue #545): resolve it off the main
        // actor, on the dedicated I/O queue real scans use, before taking the
        // lock below that starts a refresh. Skipped when the decision would
        // not consult it anyway — a fresh install with no summary yet, or no
        // prior scan to compare against — matching `needsBackgroundRefresh`'s
        // own early-outs so an unnecessary walk is never kicked off.
        let evidence: Bool?
        if summary != nil, let scanDate {
            evidence = await Self.evidenceOfNewTranscripts(
                since: scanDate,
                enabledServices: enabledServices
            )
        } else {
            evidence = nil
        }

        let shouldStart = await MainActor.run {
            guard !isRefreshInProgress else { return false }
            guard Self.needsBackgroundRefresh(
                summary: summary,
                lastScanDate: scanDate,
                enabledServices: enabledServices,
                days: days,
                newTranscriptsSinceLastScan: { _, _ in evidence }
            ) else {
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
            scanProgress = nil
        }
    }

    /// Whether opening Costs should start a windowed backfill.
    ///
    /// Extracted so the "lifetime is gone on purpose" rule is unit-testable
    /// without constructing a full tracker.
    ///
    /// `newTranscriptsSinceLastScan` is the mtime-evidence probe backing
    /// `CostSummary`'s "already scanned" gate (issue #517): injectable so
    /// tests can drive the gate without touching real files on disk.
    /// Production leaves it at `CostScanFreshnessProbe.hasNewTranscripts`,
    /// which walks the enabled providers' roots; the same evidence is reused
    /// for all three `needsMissing*` checks below rather than walking the
    /// corpus three times.
    static func needsBackgroundRefresh(
        summary: CostSummary?,
        lastScanDate: Date?,
        enabledServices: Set<ServiceType>,
        days: Int,
        now: Date = Date(),
        newTranscriptsSinceLastScan: (Date, Set<ServiceType>) -> Bool? = CostScanFreshnessProbe.hasNewTranscripts
    ) -> Bool {
        let hasEnabled = hasEnabledCostScanProvider(in: enabledServices)
        guard let summary else { return hasEnabled }

        let visibleSummary = summary.filtered(to: enabledServices)
        let evidence = lastScanDate.flatMap { newTranscriptsSinceLastScan($0, enabledServices) }
        return visibleSummary.needsMissingDailyUsageRefresh(
            days: days,
            lastScanDate: lastScanDate,
            newTranscriptsSinceLastScan: evidence,
            now: now
        )
            || (hasEnabled
                && visibleSummary.needsMissingHourlyUsageRefresh(
                    lastScanDate: lastScanDate,
                    newTranscriptsSinceLastScan: evidence,
                    now: now
                ))
            || visibleSummary.needsMissingEnabledProviderRefresh(
                enabledServices: enabledServices,
                lastScanDate: lastScanDate,
                newTranscriptsSinceLastScan: evidence,
                now: now
            )
    }

    /// Runs the disk-evidence probe behind `needsBackgroundRefresh` off the
    /// main actor, on the same dedicated I/O queue real scans use
    /// (`CostScanExecutor`).
    ///
    /// Issue #545: `CostScanFreshnessProbe.hasNewTranscripts` recursively
    /// walks every enabled provider's roots — roughly 10 GB / 10k files in a
    /// working corpus (see `CostScanExecutor`'s header for why that work
    /// belongs off the cooperative pool) — and used to run synchronously
    /// *inside* `MainActor.run` from `refreshMissingDaysInBackground`, so the
    /// popover's own `.task` — and everything else queued behind the main
    /// actor — blocked on the walk.
    ///
    /// `probe` is injectable, mirroring `needsBackgroundRefresh`'s own seam,
    /// so tests can drive this without touching real files, the real home
    /// directory, or the main actor at all. Production leaves it at
    /// `CostScanFreshnessProbe.hasNewTranscripts`. A cancelled or failed hop
    /// to the scan queue answers `nil` — "unknown," the same value the probe
    /// itself returns for a root it could not finish walking — rather than
    /// silently claiming there is no new evidence.
    static func evidenceOfNewTranscripts(
        since lastScanDate: Date,
        enabledServices: Set<ServiceType>,
        probe: @escaping @Sendable (Date, Set<ServiceType>) -> Bool? = { date, services in
            CostScanFreshnessProbe.hasNewTranscripts(since: date, enabledServices: services)
        }
    ) async -> Bool? {
        guard let evidence = try? await CostScanExecutor.run({ _ in probe(lastScanDate, enabledServices) }) else {
            return nil
        }
        return evidence
    }

    /// Hourly rows come from local log scanners, not from providers whose
    /// history is accumulated only by polling. Without this gate a
    /// Cursor/OpenRouter-only setup would run a fruitless full scan each day.
    static func hasEnabledCostScanProvider(in enabledServices: Set<ServiceType>) -> Bool {
        CostScanProvider.allCases.contains { enabledServices.contains($0.service) }
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
    /// bytes — so the loop terminates on its own after a few slices of a
    /// windowed corpus. This bound only exists so a corrupted cache or a
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
        let scanTime = Date()
        let cutoff = CostWindow.start(days: days, now: scanTime)
        let hourlyCutoff = CostWindow.start(days: 7, now: scanTime)
        let store = CostScanCacheStore.applicationSupport
        // Read once, outside the slice loop: polling providers contribute no
        // bytes, so their rows are identical in every slice and re-reading the
        // artifact 64 times would buy nothing. Refreshed here rather than
        // reused as-is so a scan never folds in a ledger older than itself.
        refreshUsageLedger()
        let usageLedger = usageLedger
        var latest: CostSummaryBuilder.CostSummaryScan?
        await MainActor.run {
            scanProgress = CostScanProgress(windowDays: days)
        }
        let progressBridge = CostScanProgressBridge(tracker: self)

        for _ in 0..<Self.maxScanSlices {
            let slice = try? await CostScanExecutor.run { token in
                // Attached first, from this slice's own token, before the
                // session can publish a single milestone through it: a
                // milestone this closure hands off to the main queue can still
                // be in flight when `token` flips cancelled and this call
                // returns early. Re-checking that same token right before the
                // hop lands lets a late milestone be dropped instead of
                // rendered — see `CostScanProgressBridge.publish`.
                progressBridge.attach(token: token)
                let session = CostScanSession(
                    cutoff: cutoff,
                    hourlyCutoff: hourlyCutoff,
                    options: .default,
                    store: store,
                    token: token
                )
                session.observeProgress(windowDays: days, progressBridge.publish)
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
                return ScanSlice(
                    scan: scan,
                    persistence: session.persist(),
                    progress: session.progress(windowDays: days)
                )
            }
            guard let slice else {
                // Cancelled. Whatever earlier slices published stands, and the
                // offsets they committed are already on disk.
                //
                // The `queue.async` body behind this call does not stop the
                // instant the continuation above resumes — it runs until its own
                // next file boundary (`CostScanExecutor`'s documented shape) —
                // so returning here immediately would let the caller clear
                // `isScanning` / `isRefreshingMissingDays` while that orphaned
                // slice is still walking the corpus (issue #547 part 3). Waiting
                // for the scan queue to actually go idle first keeps the flag
                // accurate: it stays set for exactly as long as work it guards
                // is still running, not for as long as this call's own
                // continuation took to resume.
                await CostScanExecutor.waitForIdle()
                break
            }

            latest = slice.scan
            await MainActor.run {
                scanProgress = slice.progress
                // Publish the partial total so the number on screen improves with
                // every slice instead of only when the last one lands.
                if !slice.scan.isComplete {
                    costSummary = slice.scan.summary
                }
            }
            if slice.scan.isComplete { break }

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
        let progress: CostScanProgress
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
            AppLog.cost.error(
                """
                Failed to save cost summary cache: \
                \(SecureFileWriterError.logDescription(for: error), privacy: .public)
                """
            )
        }
    }
}

/// Hops listing/read milestones off the scan queue onto the main actor so the
/// Costs banner updates during a single-slice refresh.
nonisolated final class CostScanProgressBridge: @unchecked Sendable {
    private weak var tracker: CostTracker?
    private let lock = NSLock()
    private var token: CostScanCancellationToken = .never

    init(tracker: CostTracker) {
        self.tracker = tracker
    }

    /// Attaches the token of the slice about to run through this bridge.
    ///
    /// Called once per slice, from inside `CostScanExecutor.run`'s closure,
    /// before that slice's session is given the chance to publish a single
    /// milestone — `CostTracker.makeCostSummary` builds one bridge for the
    /// whole refresh, reused slice to slice, so each slice's own token has to
    /// be handed in rather than fixed at construction.
    func attach(token: CostScanCancellationToken) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    /// Re-checks the attached token *inside* the dispatched block, not at this
    /// call's own site: `publish` runs on the scan queue, but the slice's
    /// token can flip cancelled at any point between this call and the
    /// `DispatchQueue.main.async` hop actually landing. A milestone that is
    /// already stale by the time it would render is dropped rather than
    /// shown — issue #547 part 3's second bug, a stale progress flash at the
    /// start of the next scan.
    func publish(_ progress: CostScanProgress) {
        lock.lock()
        let sliceToken = token
        lock.unlock()
        DispatchQueue.main.async { [weak tracker] in
            guard !sliceToken.isCancelled else { return }
            tracker?.scanProgress = progress
        }
    }
}
