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
    }

    func scanCosts(days: Int = 30) async {
        guard !demoMode else { return }
        let shouldStart = await MainActor.run {
            guard !isRefreshInProgress else { return false }
            isScanning = true
            return true
        }
        guard shouldStart else { return }

        let summary = await makeCostSummary(days: days, priority: .userInitiated)

        await MainActor.run {
            costSummary = summary
            lastScanDate = Date()
            saveCachedSummary()
            isScanning = false
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

        let summary = await makeCostSummary(days: days, priority: .utility)

        await MainActor.run {
            costSummary = summary
            lastScanDate = Date()
            saveCachedSummary()
            isRefreshingMissingDays = false
        }
    }

    private func makeCostSummary(days: Int, priority: TaskPriority) async -> CostSummary {
        let includeClaudeCode = providerVisibilityStore.isEnabled(.claudeCode)
        let includeCodexCli = providerVisibilityStore.isEnabled(.codexCli)
        let claudeAccounts = ClaudeCodeAccountStore.shared.accounts
        return await Task.detached(priority: priority) {
            CostSummaryBuilder.makeSummary(
                days: days,
                includeClaudeCode: includeClaudeCode,
                includeCodexCli: includeCodexCli,
                claudeAccounts: claudeAccounts
            )
        }.value
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
