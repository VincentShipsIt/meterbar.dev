import Foundation
import os
import Combine
import SwiftUI

@MainActor
class UsageDataManager: ObservableObject {
    static let shared = UsageDataManager()

    @Published var metrics: [ServiceType: UsageMetrics] = [:]
    @Published var claudeCodeAccountMetrics: [UUID: UsageMetrics] = [:]
    @Published var isLoading: Bool = false
    @Published var lastError: Error?

    @AppStorage("refreshInterval") private var refreshIntervalRaw: Int = RefreshInterval.fifteenMinutes.rawValue

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: refreshIntervalRaw) ?? .fifteenMinutes }
        set {
            refreshIntervalRaw = newValue.rawValue
            setupAutoRefresh()
        }
    }

    private let claudeService = ClaudeService.shared
    private let claudeCodeService = ClaudeCodeLocalService.shared
    private let cursorService = CursorLocalService.shared
    private let openaiService = OpenAIService.shared
    private let codexCliService = CodexCliLocalService.shared
    private let authManager = AuthenticationManager.shared
    private let claudeCodeAccountStore = ClaudeCodeAccountStore.shared
    private let providerVisibilityStore = ProviderVisibilityStore.shared

    private var refreshTimer: Timer?
    private let cacheKey = "cached_usage_metrics"
    private let sharedStore = SharedDataStore.shared

    private init() {
        loadCachedData()
        setupAutoRefresh()
    }

    func refreshAll() async {
        isLoading = true
        lastError = nil

        var newMetrics: [ServiceType: UsageMetrics] = [:]

        // Fetch Claude metrics
        if providerVisibilityStore.isEnabled(.claude), authManager.isClaudeAuthenticated {
            do {
                let metrics = try await claudeService.fetchUsageMetrics()
                newMetrics[.claude] = metrics
            } catch {
                lastError = error
                AppLog.usage.error("Failed to fetch Claude metrics: \(error.localizedDescription, privacy: .public)")
            }
        }

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

        // Fetch OpenAI API metrics
        if providerVisibilityStore.isEnabled(.openai), authManager.isOpenAIAuthenticated {
            do {
                let metrics = try await openaiService.fetchUsageMetrics()
                newMetrics[.openai] = metrics
            } catch {
                lastError = error
                AppLog.usage.error("Failed to fetch OpenAI metrics: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Fetch Codex CLI metrics (local auth from ~/.codex/auth.json)
        if providerVisibilityStore.isEnabled(.codexCli), codexCliService.hasAccess {
            do {
                let metrics = try await codexCliService.fetchUsageMetrics()
                newMetrics[.codexCli] = metrics
            } catch {
                lastError = error
                AppLog.usage.error("Failed to fetch Codex CLI metrics: \(error.localizedDescription, privacy: .public)")
                // Preserve cached data if available (graceful degradation)
                if let cachedMetrics = self.metrics[.codexCli] {
                    newMetrics[.codexCli] = cachedMetrics
                }
            }
        }

        // Fetch Cursor metrics (local files)
        if providerVisibilityStore.isEnabled(.cursor), cursorService.hasAccess {
            do {
                let metrics = try await cursorService.fetchUsageMetrics()
                newMetrics[.cursor] = metrics
            } catch {
                lastError = error
                AppLog.usage.error("Failed to fetch Cursor metrics: \(error.localizedDescription, privacy: .public)")
                // Preserve cached data if available (graceful degradation)
                if let cachedMetrics = self.metrics[.cursor] {
                    newMetrics[.cursor] = cachedMetrics
                }
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
            case .claude:
                guard authManager.isClaudeAuthenticated else {
                    throw ServiceError.notAuthenticated
                }
                newMetrics = try await claudeService.fetchUsageMetrics()
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
            case .openai:
                guard authManager.isOpenAIAuthenticated else {
                    throw ServiceError.notAuthenticated
                }
                newMetrics = try await openaiService.fetchUsageMetrics()
            case .codexCli:
                guard codexCliService.hasAccess else {
                    throw ServiceError.notAuthenticated
                }
                do {
                    newMetrics = try await codexCliService.fetchUsageMetrics()
                } catch {
                    // On individual refresh, preserve cached data if fetch fails
                    if let cachedMetric = metrics[service] {
                        newMetrics = cachedMetric
                        lastError = error
                    } else {
                        throw error
                    }
                }
            case .cursor:
                guard cursorService.hasAccess else {
                    throw ServiceError.notAuthenticated
                }
                do {
                    newMetrics = try await cursorService.fetchUsageMetrics()
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
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: UsageMetrics].self, from: data) else {
            return [:]
        }

        return decoded.reduce(into: [ServiceType: UsageMetrics]()) { result, pair in
            if let service = ServiceType(rawValue: pair.key) {
                result[service] = pair.value
            }
        }
    }

    private func saveCachedData() {
        let encoded = metrics.reduce(into: [String: UsageMetrics]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }

        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: cacheKey)
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

    func getNextRefreshTime() -> Date? {
        // Find the earliest reset time across all metrics
        let resetTimes = metrics.values.compactMap { metrics -> Date? in
            let times = [
                metrics.sessionLimit?.resetTime,
                metrics.weeklyLimit?.resetTime,
                metrics.codeReviewLimit?.resetTime
            ].compactMap { $0 }
            return times.min()
        }

        return resetTimes.min()
    }
}
