import Foundation
import MeterBarShared
import os
import AppKit
import Combine
import Network
import SQLite3

/// Service for fetching Cursor usage data using the cursor-stats approach.
/// Reads authentication token from Cursor's local SQLite database and calls dashboard APIs.
/// Based on: https://github.com/darzhang/cursor-stats-lite
class CursorLocalService: ObservableObject {
    // nonisolated: lets the nonisolated readiness inspector reference the
    // singleton (methods keep their own isolation).
    nonisolated static let shared = CursorLocalService()

    // API endpoint (from Vibeviewer: https://github.com/MarveleE/Vibeviewer)
    private let usageSummaryEndpoint = "https://cursor.com/api/usage-summary"

    // Shared URLSession with the standard usage-request timeouts
    private let urlSession = ServiceSupport.session

    // Last-resort monthly request quota, used only when the API returns no
    // usable plan quota at all; the resulting limit is marked `isEstimated`.
    // Static so the pure `mapSummary` mapping can share the same constant.
    private static let defaultPlanTotal: Double = 500

    // Display headroom estimate when no explicit on-demand limit is returned by the API
    private static let onDemandHeadroomMultiplier: Double = 1.5

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var lastError: ServiceError?

    /// The running request counter from the last successful poll.
    ///
    /// Cursor keeps no per-session usage log on disk — `~/.cursor` holds an
    /// auth/state database and an AI-authored-lines tracker, neither of which
    /// records tokens or spend — so differencing this scalar across polls is the
    /// only way Cursor can appear in a dated series. See `ProviderUsageLedger`.
    private(set) var latestUsageObservation: ProviderUsageObservation?

    private init() {
        // Defer I/O off main thread; only @Published mutations land on main actor
        Task.detached(priority: .utility) { [weak self] in self?.checkAccess(forceRescan: false) }
    }

    // MARK: - Database Access (cursor-stats approach)

    /// Get the path to Cursor's state database
    /// Scans multiple possible locations and optionally searches recursively.
    /// `nonisolated`: filesystem I/O (recursive when rescanning) — never call
    /// synchronously from the main actor.
    nonisolated private func getCursorDatabasePath(forceRescan: Bool = false) -> String? {
        let homeDir = ServiceSupport.realHomeDirectory()
        let fileManager = FileManager.default

        // Primary paths to check (most common locations)
        let pathsToCheck = [
            "\(homeDir)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            "\(homeDir)/Library/Application Support/Cursor/state.vscdb",
            "\(homeDir)/.config/Cursor/User/globalStorage/state.vscdb",
            // Additional common paths
            "\(homeDir)/Library/Application Support/Cursor/User/workspaceStorage/state.vscdb",
            "\(homeDir)/Library/Application Support/Cursor/globalStorage/state.vscdb",
        ]

        // Check each path
        for path in pathsToCheck where fileManager.fileExists(atPath: path) {
            return path
        }

        // If not found and forceRescan is true, search recursively in Cursor directories
        if forceRescan {
            let cursorBasePaths = [
                "\(homeDir)/Library/Application Support/Cursor",
                "\(homeDir)/.config/Cursor"
            ]

            for basePath in cursorBasePaths {
                if let foundPath = findDatabaseRecursively(in: basePath, filename: "state.vscdb") {
                    return foundPath
                }
            }
        }

        return nil
    }

    /// Recursively search for a database file in a directory
    nonisolated private func findDatabaseRecursively(in directory: String, filename: String) -> String? {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: directory),
              let enumerator = fileManager.enumerator(atPath: directory) else {
            return nil
        }

        for case let path as String in enumerator where path.hasSuffix(filename) {
            let fullPath = "\(directory)/\(path)"
            if fileManager.fileExists(atPath: fullPath) {
                return fullPath
            }
        }

        return nil
    }

    /// Read access token from Cursor's SQLite database.
    /// `nonisolated`: opens and queries `state.vscdb` (often large and actively
    /// WAL-written by Cursor) — never call synchronously from the main actor.
    /// - Parameter forceRescan: If true, will recursively search for database if not found in primary paths
    nonisolated func getAccessTokenFromDatabase(forceRescan: Bool = false) -> (userId: String, token: String)? {
        guard let dbPath = getCursorDatabasePath(forceRescan: forceRescan) else {
            // Database not found - Cursor may not be installed, which is okay
            return nil
        }

        // Verify file exists and is readable before attempting to open
        let isReadable = FileManager.default.isReadableFile(atPath: dbPath)
        if !isReadable {
            AppLog.usage.error("Cursor database not readable (sandbox)")
            return nil
        }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK else {
            AppLog.usage.error("Cursor SQLite open failed: \(result, privacy: .public)")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            AppLog.usage.error("Cursor query prepare failed")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        guard let tokenCString = sqlite3_column_text(statement, 0) else {
            AppLog.usage.error("Cursor token value unreadable")
            return nil
        }

        let token = String(cString: tokenCString)

        // Decode JWT to extract userId from 'sub' claim
        guard let userId = Self.extractUserIdFromJWT(token) else {
            AppLog.usage.error("Cursor JWT userId extraction failed")
            return nil
        }

        return (userId: userId, token: token)
    }

    /// Probe the Cursor state database for provider-readiness diagnostics,
    /// mapping the SQLite read onto the shared `CursorDatabaseProbe` states.
    /// Uses the same path scan and read-only open as `getAccessTokenFromDatabase`,
    /// but reports *why* auth is unavailable (not found / unreadable / no token)
    /// instead of just a token, and never returns the token value itself.
    nonisolated func probeReadinessDatabase() -> CursorDatabaseProbe {
        guard let dbPath = getCursorDatabasePath(forceRescan: false)
            ?? getCursorDatabasePath(forceRescan: true) else {
            return .notFound
        }

        guard FileManager.default.isReadableFile(atPath: dbPath) else {
            return .unreadable
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .unreadable
        }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return .unreadable
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let tokenCString = sqlite3_column_text(statement, 0) else {
            return .missingToken
        }

        return String(cString: tokenCString).isEmpty ? .missingToken : .tokenPresent
    }

    /// Extract userId from JWT token's 'sub' claim.
    /// Static + internal so it is unit-testable without a Cursor DB or network.
    nonisolated static func extractUserIdFromJWT(_ token: String) -> String? {
        guard let sub = JWT.claimString("sub", in: token) else { return nil }

        // Extract userId from sub claim
        // Format may be "auth0|userId" or similar
        if sub.contains("|") {
            return sub.components(separatedBy: "|").last
        }

        return sub
    }

    /// Format authentication cookie for Cursor API
    private static func formatAuthCookie(userId: String, token: String) -> String {
        // Format: userId::token (URL encoded)
        "\(userId)%3A%3A\(token)"
    }

    /// Check and update access status.
    /// `nonisolated`: reads the Cursor SQLite DB (and recursively scans the
    /// Cursor directory when `forceRescan`) — call from a detached task.
    /// - Parameter forceRescan: If true, will recursively search for database if not found in primary paths
    nonisolated func checkAccess(forceRescan: Bool = false) {
        let hasToken = getAccessTokenFromDatabase(forceRescan: forceRescan) != nil
        ServiceSupport.applyOnMain { [weak self] in
            guard let self else { return }
            self.hasAccess = hasToken
            if !hasToken { self.subscriptionType = nil }
        }
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics() async throws -> UsageMetrics {
        // SQLite read (plus a recursive directory scan on a miss) is blocking
        // I/O; the app target runs async bodies on the main actor (default
        // MainActor isolation), so hop off explicitly. Try without rescan first
        // (faster), then with rescan if needed.
        let credentials = await Task.detached(priority: .userInitiated) { [self] in
            getAccessTokenFromDatabase(forceRescan: false)
                ?? getAccessTokenFromDatabase(forceRescan: true)
        }.value

        guard let (userId, token) = credentials else {
            let error = ServiceError.notAuthenticated
            await MainActor.run {
                self.lastError = error
                self.hasAccess = false
            }
            throw error
        }

        await MainActor.run {
            self.hasAccess = true
        }

        // Fetch usage summary data (uses /api/usage-summary endpoint)
        let summaryData = try await fetchUsageSummary(userId: userId, token: token)

        let metrics = CursorLocalService.mapSummary(summaryData)

        // Clear any previous errors on success
        await MainActor.run {
            self.lastError = nil
            self.subscriptionType = summaryData.membershipType
            self.latestUsageObservation = CursorLocalService.observation(summaryData, at: metrics.lastUpdated)
        }

        return metrics
    }

    /// One poll's reading of the plan counter, in requests.
    ///
    /// `.requests`, never `.usd`: `/api/usage-summary` publishes no currency
    /// field — `plan.used`, `plan.limit` and the on-demand figures are integer
    /// counts against a plan allowance, and Cursor publishes no per-request rate
    /// anywhere MeterBar can read. Any dollar figure derived here would be
    /// invented, so this counter is barred from `costs[]` by
    /// `ProviderUsageLedger.dailyUSDSeries(for:)` and surfaces as a request
    /// series instead.
    ///
    /// Two-pool percent payloads (`autoPercentUsed` / `apiPercentUsed`) are the
    /// dashboard's included-usage bars, not a running request counter.
    /// Differencing `plan.used` across that shape change produced a phantom
    /// multi-thousand "request" spike, so those payloads yield no observation.
    ///
    /// On-demand usage is billed and counted separately, so it is deliberately
    /// not summed in: the total would then be in neither unit. No token counts
    /// ride along either — the endpoint reports none.
    ///
    /// The counter zeroes at `billingCycleStart`; the ledger reads a drop as a
    /// reset rather than a negative delta, so no cycle rollover emits a negative
    /// day.
    ///
    /// Returns `nil` when the payload carries no plan counter at all. Defaulting
    /// the absent field to `0` would be indistinguishable from a real reset to
    /// the ledger, which reads a drop as a new billing cycle and re-baselines to
    /// zero — so the next complete poll would charge the entire cycle-to-date
    /// count to a single day as a phantom spike.
    static func observation(
        _ summaryData: CursorUsageSummaryResponse,
        at observedAt: Date
    ) -> ProviderUsageObservation? {
        let plan = selectedUsage(from: summaryData).plan
        if plan?.autoPercentUsed != nil, plan?.apiPercentUsed != nil {
            return nil
        }
        guard let used = plan?.used else { return nil }
        return ProviderUsageObservation(
            provider: .cursor,
            unit: .requests,
            runningTotal: Double(used),
            // Cursor publishes no per-day figure, so there is nothing
            // authoritative to prefer over the poll-to-poll delta.
            authoritativeDailyTotal: nil,
            // Deltas are dated when MeterBar observed them, so the user's own
            // calendar is the right one.
            dayBoundary: .local,
            observedAt: observedAt
        )
    }

    /// Maps a decoded Cursor usage-summary response onto the shared
    /// `UsageMetrics` shape. Pure and side-effect-free so it can be fixture-tested
    /// without the network or Cursor's SQLite DB.
    ///
    /// Current dashboard shape: `plan.autoPercentUsed` (Cursor Models) and
    /// `plan.apiPercentUsed` (Other Models) are the two included pools. Those
    /// land on `sessionLimit` / `weeklyLimit` as percentages of 100 so the
    /// popover can draw the same two bars the dashboard does. Enabled on-demand
    /// spend, when present, is the third window (`codeReviewLimit`) — it must
    /// not occupy the session slot, which would hide Cursor Models.
    ///
    /// Legacy payloads omit the percent fields. They keep the previous mapping:
    /// `plan.used` / server quota as the monthly request window, on-demand as
    /// the session window. The plan denominator comes from the server
    /// (`plan.limit`, else `plan.breakdown`, else the legacy flat `plan.total`);
    /// only when the selected shape carries none of those is the assumed quota
    /// substituted and flagged `isEstimated`.
    static func mapSummary(_ summaryData: CursorUsageSummaryResponse) -> UsageMetrics {
        let cycle = billingCycle(from: summaryData)

        let usage = selectedUsage(from: summaryData)
        let plan = usage.plan

        if let autoPercent = plan?.autoPercentUsed, let apiPercent = plan?.apiPercentUsed {
            return UsageMetrics(
                service: .cursor,
                sessionLimit: percentPoolLimit(
                    autoPercent,
                    resetTime: cycle.resetTime,
                    windowSeconds: cycle.windowSeconds
                ),
                weeklyLimit: percentPoolLimit(
                    apiPercent,
                    resetTime: cycle.resetTime,
                    windowSeconds: cycle.windowSeconds
                ),
                codeReviewLimit: onDemandLimit(
                    from: usage.onDemand,
                    resetTime: cycle.resetTime,
                    windowSeconds: cycle.windowSeconds
                )
            )
        }

        let planUsed = Double(plan?.used ?? 0)
        let serverQuota = plan?.serverQuota
        let planTotalIsEstimated = serverQuota == nil
        let planTotal = Double(serverQuota ?? Int(defaultPlanTotal))

        // Billing-cycle window. Named `weeklyLimit` after the shared long-window
        // slot, not its cadence: it resets at `billingCycleEnd`, which is why
        // the legacy title for this window is "Monthly".
        return UsageMetrics(
            service: .cursor,
            sessionLimit: onDemandLimit(
                from: usage.onDemand,
                resetTime: cycle.resetTime,
                windowSeconds: cycle.windowSeconds
            ),
            weeklyLimit: UsageLimit(
                used: planUsed,
                total: planTotal,
                resetTime: cycle.resetTime,
                windowSeconds: cycle.windowSeconds,
                isEstimated: planTotalIsEstimated
            ),
            codeReviewLimit: nil
        )
    }

    /// `billingCycleEnd` is the reset. `end − start` is the real cycle length
    /// when both parse and the duration is positive — no assumed 30-day month.
    private static func billingCycle(
        from summary: CursorUsageSummaryResponse
    ) -> (resetTime: Date?, windowSeconds: TimeInterval?) {
        let start = summary.billingCycleStart.flatMap(FlexibleISO8601.date(from:))
        let end = summary.billingCycleEnd.flatMap(FlexibleISO8601.date(from:))
        let windowSeconds: TimeInterval?
        if let start, let end {
            let duration = end.timeIntervalSince(start)
            windowSeconds = duration > 0 ? duration : nil
        } else {
            windowSeconds = nil
        }
        return (end, windowSeconds)
    }

    /// One included pool as the dashboard draws it: `used` is already a
    /// 0…100 percent, so the denominator is 100 rather than a request grant.
    private static func percentPoolLimit(
        _ percentUsed: Double,
        resetTime: Date?,
        windowSeconds: TimeInterval?
    ) -> UsageLimit {
        UsageLimit(
            used: max(0, percentUsed),
            total: ServiceType.cursorIncludedPoolTotal,
            resetTime: resetTime,
            windowSeconds: windowSeconds,
            isEstimated: false
        )
    }

    private static func onDemandLimit(
        from onDemand: CursorOnDemandUsage?,
        resetTime: Date?,
        windowSeconds: TimeInterval?
    ) -> UsageLimit? {
        guard let onDemand, onDemand.enabled == true else { return nil }
        let onDemandUsed = Double(onDemand.used ?? 0)
        let onDemandLimit = Double(onDemand.limit ?? 0)
        guard onDemandUsed > 0 || onDemandLimit > 0 else { return nil }
        return UsageLimit(
            used: onDemandUsed,
            total: onDemandLimit > 0 ? onDemandLimit : onDemandUsed * onDemandHeadroomMultiplier,
            resetTime: resetTime,
            windowSeconds: windowSeconds,
            isEstimated: onDemandLimit <= 0
        )
    }

    /// Resolves the two response shapes once so plan and on-demand usage cannot
    /// come from different accounts. An explicit individual counter wins even
    /// when it is zero; team usage is selected only when individual usage has no
    /// counter. If neither has a counter, retain a server-backed quota or the
    /// first available shape for the summary mapper, while `observation` still
    /// rejects the missing counter instead of inventing a reset.
    private static func selectedUsage(
        from summaryData: CursorUsageSummaryResponse
    ) -> (plan: CursorPlanUsage?, onDemand: CursorOnDemandUsage?) {
        let individual = summaryData.individualUsage
        let team = summaryData.teamUsage

        if individual?.plan?.used != nil {
            return (individual?.plan, individual?.onDemand)
        }
        if team?.plan?.used != nil {
            return (team?.plan, team?.onDemand)
        }
        if individual?.plan?.serverQuota != nil {
            return (individual?.plan, individual?.onDemand)
        }
        if team?.plan?.serverQuota != nil {
            return (team?.plan, team?.onDemand)
        }
        if individual != nil {
            return (individual?.plan, individual?.onDemand)
        }
        return (team?.plan, team?.onDemand)
    }

    // MARK: - API Calls

    /// Cursor's session cookie layered on top of the shared browser identity.
    /// Static so the header contract can be asserted without a live service.
    static func dashboardHeaders(userId: String, token: String) -> [String: String] {
        var headers = ServiceSupport.browserHeaders(for: .cursorDashboard, accept: "*/*")
        headers["Content-Type"] = "application/json"
        headers["Cookie"] = "WorkosCursorSessionToken=\(formatAuthCookie(userId: userId, token: token))"
        return headers
    }

    private func fetchUsageSummary(userId: String, token: String) async throws -> CursorUsageSummaryResponse {
        guard let url = URL(string: usageSummaryEndpoint) else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ServiceSupport.usageRequestTimeout

        for (key, value) in Self.dashboardHeaders(userId: userId, token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            try ServiceSupport.validate(response, data: data)
            return try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            AppLog.usage.error("Cursor usage-summary fetch failed: \(serviceError.localizedDescription)")
            await MainActor.run {
                self.lastError = serviceError
                if case .notAuthenticated = serviceError {
                    self.hasAccess = false
                }
            }
            throw serviceError
        }
    }
}

// MARK: - Response Models

/// Response from https://cursor.com/api/usage-summary
/// Based on Vibeviewer implementation
nonisolated struct CursorUsageSummaryResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let individualUsage: CursorIndividualUsage?
    let teamUsage: CursorTeamUsage?
}

nonisolated struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

nonisolated struct CursorPlanUsage: Decodable {
    let used: Int?
    let limit: Int?
    let remaining: Int?
    /// Current shape: the grant is nested under `breakdown`.
    let breakdown: CursorPlanBreakdown?
    /// Legacy shape: `included`/`bonus`/`total` were flat plan properties.
    /// Kept so older payloads (and cached responses) still yield a quota.
    let included: Int?
    let bonus: Int?
    let total: Int?
    /// Included **Cursor Models** pool, 0…100, as the dashboard's first bar.
    let autoPercentUsed: Double?
    /// Included **Other Models** (API) pool, 0…100, as the dashboard's second bar.
    let apiPercentUsed: Double?
    /// Combined included-usage percent. Not mapped — the dashboard draws the
    /// two pools separately, and folding them into one bar is what made MeterBar
    /// disagree with Cursor's own UI.
    let totalPercentUsed: Double?

    /// Quota the dashboard divides by, in precedence order: the enforced
    /// `limit`, then the nested grant, then the legacy flat `total`. Returns
    /// nil when the server sends no usable denominator (absent or zeroed), so
    /// callers can flag the substituted value as estimated instead of silently
    /// presenting a guess as fact.
    var serverQuota: Int? {
        [limit, breakdown?.grantTotal, total]
            .compactMap { $0 }
            .first { $0 > 0 }
    }
}

/// Nested plan grant: `included` is the subscription allowance and `bonus` any
/// promotional top-up, with `total` their sum.
nonisolated struct CursorPlanBreakdown: Decodable {
    let included: Int?
    let bonus: Int?
    let total: Int?

    /// `total` when present, otherwise the sum of its parts — a payload that
    /// only itemizes the grant still carries a real server quota.
    var grantTotal: Int? {
        if let total, total > 0 { return total }
        // Non-positive parts are absent grants, not debits — summing them would
        // shrink the denominator below what the server actually granted.
        let parts = [included, bonus].compactMap { $0 }.filter { $0 > 0 }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0, +)
    }
}

nonisolated struct CursorOnDemandUsage: Decodable {
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let enabled: Bool?
}

nonisolated struct CursorTeamUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}
