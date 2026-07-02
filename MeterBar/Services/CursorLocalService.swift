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
    static let shared = CursorLocalService()

    // API endpoint (from Vibeviewer: https://github.com/MarveleE/Vibeviewer)
    private let usageSummaryEndpoint = "https://cursor.com/api/usage-summary"

    // Shared URLSession with the standard usage-request timeouts
    private let urlSession = ServiceSupport.session

    // Assumed default monthly request quota when the API omits a plan total
    private let defaultPlanTotal: Double = 500

    // Display headroom estimate when no explicit on-demand limit is returned by the API
    private let onDemandHeadroomMultiplier: Double = 1.5

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var lastError: ServiceError?

    private init() {
        // Defer I/O off main thread; only @Published mutations land on main actor
        Task.detached(priority: .utility) { [weak self] in self?.checkAccess(forceRescan: false) }
    }

    // MARK: - Database Access (cursor-stats approach)

    /// Get the path to Cursor's state database
    /// Scans multiple possible locations and optionally searches recursively
    private func getCursorDatabasePath(forceRescan: Bool = false) -> String? {
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
    private func findDatabaseRecursively(in directory: String, filename: String) -> String? {
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

    /// Read access token from Cursor's SQLite database
    /// - Parameter forceRescan: If true, will recursively search for database if not found in primary paths
    func getAccessTokenFromDatabase(forceRescan: Bool = false) -> (userId: String, token: String)? {
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
        guard let userId = extractUserIdFromJWT(token) else {
            AppLog.usage.error("Cursor JWT userId extraction failed")
            return nil
        }

        return (userId: userId, token: token)
    }

    /// Extract userId from JWT token's 'sub' claim
    private func extractUserIdFromJWT(_ token: String) -> String? {
        guard let sub = JWT.claimString("sub", in: token) else { return nil }

        // Extract userId from sub claim
        // Format may be "auth0|userId" or similar
        if sub.contains("|") {
            return sub.components(separatedBy: "|").last
        }

        return sub
    }

    /// Format authentication cookie for Cursor API
    private func formatAuthCookie(userId: String, token: String) -> String {
        // Format: userId::token (URL encoded)
        "\(userId)%3A%3A\(token)"
    }

    /// Check and update access status
    /// - Parameter forceRescan: If true, will recursively search for database if not found in primary paths
    func checkAccess(forceRescan: Bool = false) {
        let hasToken = getAccessTokenFromDatabase(forceRescan: forceRescan) != nil
        ServiceSupport.applyOnMain { [weak self] in
            guard let self else { return }
            self.hasAccess = hasToken
            if !hasToken { self.subscriptionType = nil }
        }
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics() async throws -> UsageMetrics {
        // Try without rescan first (faster), then with rescan if needed
        guard let (userId, token) = getAccessTokenFromDatabase(forceRescan: false)
            ?? getAccessTokenFromDatabase(forceRescan: true) else {
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

        // Clear any previous errors on success
        await MainActor.run {
            self.lastError = nil
            self.subscriptionType = summaryData.membershipType
        }

        // Parse billing cycle end date for reset time
        var resetTime: Date?
        if let billingEnd = summaryData.billingCycleEnd {
            resetTime = FlexibleISO8601.date(from: billingEnd)
        }

        // Extract usage from individual plan
        let planUsed = Double(summaryData.individualUsage?.plan?.used ?? 0)
        let planTotal = Double(summaryData.individualUsage?.plan?.total ?? Int(defaultPlanTotal))

        // Create usage metrics using plan data
        let weeklyLimit = UsageLimit(
            used: planUsed,
            total: planTotal,
            resetTime: resetTime
        )

        // On-demand usage as secondary metric if enabled
        var sessionLimit: UsageLimit?
        if let onDemand = summaryData.individualUsage?.onDemand, onDemand.enabled == true {
            let onDemandUsed = Double(onDemand.used ?? 0)
            let onDemandLimit = Double(onDemand.limit ?? 0)
            if onDemandUsed > 0 || onDemandLimit > 0 {
                sessionLimit = UsageLimit(
                    used: onDemandUsed,
                    total: onDemandLimit > 0 ? onDemandLimit : onDemandUsed * onDemandHeadroomMultiplier,
                    resetTime: resetTime
                )
            }
        }

        return UsageMetrics(
            service: .cursor,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            codeReviewLimit: nil
        )
    }

    // MARK: - API Calls

    /// Build browser-like headers for Cursor API requests
    private func buildHeaders(userId: String, token: String) -> [String: String] {
        let authCookie = formatAuthCookie(userId: userId, token: token)
        return [
            "Accept": "*/*",
            "Content-Type": "application/json",
            "Cookie": "WorkosCursorSessionToken=\(authCookie)",
            "Origin": "https://cursor.com",
            "Referer": "https://cursor.com/dashboard?tab=usage",
            "User-Agent": ServiceSupport.browserUserAgent
        ]
    }

    private func fetchUsageSummary(userId: String, token: String) async throws -> CursorUsageSummaryResponse {
        guard let url = URL(string: usageSummaryEndpoint) else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30.0

        // Set browser-like headers
        for (key, value) in buildHeaders(userId: userId, token: token) {
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
struct CursorUsageSummaryResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let individualUsage: CursorIndividualUsage?
    let teamUsage: CursorTeamUsage?
}

struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

struct CursorPlanUsage: Decodable {
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let included: Int?
    let bonus: Int?
    let total: Int?
}

struct CursorOnDemandUsage: Decodable {
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let enabled: Bool?
}

struct CursorTeamUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}
