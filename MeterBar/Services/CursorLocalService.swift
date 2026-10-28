import Foundation
import MeterBarShared
import os
import AppKit
import Combine
import Network

/// Service for fetching Cursor usage data using the cursor-stats approach.
/// Reads authentication token from Cursor's local SQLite database and calls dashboard APIs.
/// Based on: https://github.com/darzhang/cursor-stats-lite
class CursorLocalService: ObservableObject {
    // nonisolated: lets the nonisolated readiness inspector reference the
    // singleton (methods keep their own isolation).
    nonisolated static let shared = CursorLocalService()

    // API endpoint (from Vibeviewer: https://github.com/MarveleE/Vibeviewer)
    nonisolated private static let usageSummaryEndpoint = "https://cursor.com/api/usage-summary"

    /// Weekly included pool. On a merged Cursor / SpaceXAI / X account this is
    /// the shared allowance. Not present on `/api/usage-summary`.
    nonisolated private static let sandUsageEndpoint =
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"

    /// Plan cadence for the included pool. `includedUsagePeriod` says whether
    /// that pool is weekly; `billingCycleEnd` on usage-summary is the invoice.
    nonisolated private static let planInfoEndpoint =
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"

    /// Production and tests share this seam so the off-main regression can
    /// probe through a *stored* `@Sendable` closure — the exact shape that
    /// crashed 1.8.38 entering `NSURLSession.data(for:)` (OpenRouter #480,
    /// Codex #328).
    private let fetchData: @Sendable (URLRequest) async throws -> Data

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var lastError: ServiceError?
    @Published private(set) var credentialProbe: CursorDatabaseProbe?

    /// The running request counter from the last successful poll.
    ///
    /// Cursor keeps no per-session usage log on disk — `~/.cursor` holds an
    /// auth/state database and an AI-authored-lines tracker, neither of which
    /// records tokens or spend — so differencing this scalar across polls is the
    /// only way Cursor can appear in a dated series. See `ProviderUsageLedger`.
    private(set) var latestUsageObservation: ProviderUsageObservation?

    init(fetchData: (@Sendable (URLRequest) async throws -> Data)? = nil) {
        self.fetchData = fetchData ?? ServiceSupport.fetchValidatedData
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

    nonisolated func readCredentials(
        forceRescan: Bool = false,
        mode: ClaudeKeychainAccessMode = .background
    ) -> CursorCredentialReader.Result {
        CursorCredentialReader.read(
            databasePath: getCursorDatabasePath(forceRescan: forceRescan), mode: mode
        )
    }

    nonisolated func getAccessTokenFromDatabase(forceRescan: Bool = false) -> (userId: String, token: String)? {
        guard case let .credentials(userID, token) = readCredentials(forceRescan: forceRescan) else { return nil }
        return (userID, token)
    }

    /// Only the subject leaves the credential reader; tokens stay in memory.
    nonisolated func externalAccountIdentity() -> String? {
        getAccessTokenFromDatabase(forceRescan: true)?.userId
    }

    nonisolated func probeReadinessDatabase() -> CursorDatabaseProbe {
        readCredentials(forceRescan: true).probe
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
    nonisolated private static func formatAuthCookie(userId: String, token: String) -> String {
        // Format: userId::token (URL encoded)
        "\(userId)%3A%3A\(token)"
    }

    /// Check and update access status.
    /// `nonisolated`: reads the Cursor SQLite DB (and recursively scans the
    /// Cursor directory when `forceRescan`) — call from a detached task.
    /// - Parameter forceRescan: If true, will recursively search for database if not found in primary paths
    @discardableResult
    nonisolated func checkAccess(
        forceRescan: Bool = false,
        mode: ClaudeKeychainAccessMode = .background
    ) -> Bool {
        let result = readCredentials(forceRescan: forceRescan, mode: mode)
        ServiceSupport.applyOnMain { [weak self] in
            guard let self else { return }
            self.hasAccess = result.probe == .tokenPresent
            self.credentialProbe = result.probe
            if !self.hasAccess { self.subscriptionType = nil }
        }
        return result.probe == .tokenPresent
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics() async throws -> UsageMetrics {
        // SQLite read (plus a recursive directory scan on a miss) is blocking
        // I/O; the app target runs async bodies on the main actor (default
        // MainActor isolation), so hop off explicitly. The path resolver checks
        // known locations before falling back to a recursive rescan.
        let credentials = await Task.detached(priority: .userInitiated) { [self] in
            readCredentials(forceRescan: true)
        }.value
        await MainActor.run { self.credentialProbe = credentials.probe }
        guard case let .credentials(userId, token) = credentials else {
            let error = Self.credentialError(for: credentials.probe)
            await MainActor.run {
                self.lastError = error
                self.hasAccess = false
            }
            throw error
        }

        await MainActor.run { self.hasAccess = true }

        do {
            let fetched = try await Self.fetchRemotely(
                userId: userId,
                token: token,
                fetchData: fetchData
            )
            await MainActor.run {
                self.lastError = nil
                self.subscriptionType = fetched.membershipType
                self.latestUsageObservation = fetched.observation
            }
            return fetched.metrics
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

    nonisolated static func credentialError(for probe: CursorDatabaseProbe) -> ServiceError {
        switch probe {
        case .notFound, .missingToken, .invalidToken, .tokenPresent:
            return .notAuthenticated
        case .unreadable:
            return .apiError("Cursor's local database could not be read. Check file access and rescan.")
        case .needsKeychainAccess:
            return .apiError("Cursor Keychain access is needed. Open xAI settings and choose Connect Cursor.")
        case .encryptedCredentialUnavailable:
            return .apiError("Cursor's encrypted sign-in could not be decrypted. Open Cursor and sign in again.")
        }
    }

    /// Outcome of one off-main poll — only `Sendable` values cross back so the
    /// main-actor side never touches network state.
    nonisolated struct FetchedUsage: Sendable {
        let metrics: UsageMetrics
        let observation: ProviderUsageObservation?
        let membershipType: String?
    }

    /// Runs the network legs and the decode off the main actor — see
    /// `ServiceSupport.detached` for the SIGSEGV rationale (the 1.8.38 Cursor
    /// refresh crash is this service's case). Nothing in the detached scope
    /// touches main-actor state.
    nonisolated static func fetchRemotely(
        userId: String,
        token: String,
        fetchData: @escaping @Sendable (URLRequest) async throws -> Data
    ) async throws -> FetchedUsage {
        try await ServiceSupport.detached {
            let summaryData = try await fetchUsageSummary(
                userId: userId,
                token: token,
                fetchData: fetchData
            )
            // Independent optional reads. Concurrent so a hung call costs one
            // timeout, not two. A failure must not drop the usage-summary bars.
            async let sandFetch = fetchSandUsageStatus(token: token, fetchData: fetchData)
            async let planFetch = fetchPlanInfo(token: token, fetchData: fetchData)
            let (sandStatus, planInfo) = await (sandFetch, planFetch)
            let metrics = CursorUsageParser.metrics(
                summaryData,
                sandStatus: sandStatus,
                planInfo: planInfo
            )
            return FetchedUsage(
                metrics: metrics,
                observation: CursorUsageParser.observation(summaryData, at: metrics.lastUpdated),
                membershipType: CursorUsageParser.membershipType(
                    summary: summaryData.membershipType, planInfo: planInfo
                )
            )
        }
    }

    // MARK: - API Calls

    /// Cursor's session cookie layered on top of the shared browser identity.
    /// Static so the header contract can be asserted without a live service.
    nonisolated static func dashboardHeaders(userId: String, token: String) -> [String: String] {
        var headers = ServiceSupport.browserHeaders(for: .cursorDashboard, accept: "*/*")
        headers["Content-Type"] = "application/json"
        headers["Cookie"] = "WorkosCursorSessionToken=\(formatAuthCookie(userId: userId, token: token))"
        return headers
    }

    /// Connect-RPC headers for DashboardService/GetSandUsageStatus.
    /// Auth is the same Cursor JWT already read from `state.vscdb`.
    /// Static so the header contract can be asserted without a live token.
    nonisolated static func aiserverHeaders(token: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(token)",
            "Connect-Protocol-Version": "1",
            "x-ghost-mode": "true",
            "x-request-id": UUID().uuidString,
            "x-cursor-client-type": "ide",
            "x-cursor-client-version": "1.0.0",
        ]
    }

    nonisolated private static func fetchUsageSummary(
        userId: String,
        token: String,
        fetchData: @Sendable (URLRequest) async throws -> Data
    ) async throws -> CursorUsageSummaryResponse {
        guard let url = URL(string: usageSummaryEndpoint) else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ServiceSupport.usageRequestTimeout

        for (key, value) in dashboardHeaders(userId: userId, token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data = try await fetchData(request)
        return try CursorUsageParser.summary(from: data)
    }

    /// Optional Grok Bot weekly status. Network, 401, and decode failures
    /// return nil so the required usage-summary path still succeeds.
    nonisolated private static func fetchSandUsageStatus(
        token: String,
        fetchData: @Sendable (URLRequest) async throws -> Data
    ) async -> CursorSandUsageStatusResponse? {
        guard let url = URL(string: sandUsageEndpoint) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = ServiceSupport.usageRequestTimeout

        for (key, value) in aiserverHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let data = try await fetchData(request)
            return try CursorUsageParser.sandStatus(from: data)
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            AppLog.usage.error(
                "Cursor Grok Bot usage fetch failed: \(serviceError.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Optional plan cadence. Network, 401, and decode failures return nil so
    /// the required usage-summary path still succeeds.
    nonisolated private static func fetchPlanInfo(
        token: String,
        fetchData: @Sendable (URLRequest) async throws -> Data
    ) async -> CursorPlanInfoResponse? {
        guard let url = URL(string: planInfoEndpoint) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = ServiceSupport.usageRequestTimeout

        for (key, value) in aiserverHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let data = try await fetchData(request)
            return try CursorUsageParser.planInfo(from: data)
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            AppLog.usage.error(
                "Cursor plan info fetch failed: \(serviceError.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
