import Foundation

/// Shared helpers for the local provider usage services.
///
/// Centralizes the URLSession configuration, HTTP response validation, error
/// mapping, browser-spoof headers, main-thread state application, and the real
/// (non-sandboxed) home directory lookup so all services behave consistently.
nonisolated enum ServiceSupport {
    /// The one `URLSession` all usage requests share, configured with the
    /// standard MeterBar timeouts. Previously each service built its own
    /// session — and some code paths silently used `URLSession.shared`,
    /// skipping this configuration.
    static let session: URLSession = makeUsageSession()

    /// Browser-like User-Agent for provider dashboard APIs that block
    /// non-browser clients. Codex and Cursor previously each hardcoded a
    /// different spoof string.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Per-request timeout for provider usage calls. Matches the session-level
    /// timeout so a request built by hand behaves like one built from `session`.
    static let usageRequestTimeout: TimeInterval = 30

    /// The dashboard a spoofed request claims to originate from.
    ///
    /// `Origin` and `Referer` are checked together by these APIs, so they are
    /// paired in one value rather than passed as two strings that a call site
    /// could let drift apart.
    struct BrowserSite {
        let origin: String
        let referer: String

        static let cursorDashboard = BrowserSite(
            origin: "https://cursor.com",
            referer: "https://cursor.com/dashboard?tab=usage"
        )

        static let chatGPT = BrowserSite(
            origin: "https://chatgpt.com",
            referer: "https://chatgpt.com/"
        )
    }

    /// Headers that make a request look like it came from `site`'s own web
    /// dashboard. Cursor and Codex each hand-rolled this set; the only thing
    /// that legitimately varies between them is `accept`.
    static func browserHeaders(for site: BrowserSite, accept: String = "application/json") -> [String: String] {
        [
            "Accept": accept,
            "Origin": site.origin,
            "Referer": site.referer,
            "User-Agent": browserUserAgent
        ]
    }

    /// Applies `browserHeaders(for:accept:)` plus the standard timeout to a
    /// request. Uses `setValue` so re-applying replaces rather than comma-joins.
    static func applyBrowserHeaders(
        to request: inout URLRequest,
        for site: BrowserSite,
        accept: String = "application/json"
    ) {
        for (field, value) in browserHeaders(for: site, accept: accept) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = usageRequestTimeout
    }

    /// Minimal, ephemeral, cookie-free transport for provider usage requests.
    /// It keeps credentials in their provider-managed stores and prevents
    /// responses from persisting cookies, cached data, or credential state.
    static func makeUsageSession(
        configuration: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        let safeConfiguration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        safeConfiguration.urlCache = nil
        safeConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        safeConfiguration.httpCookieStorage = nil
        safeConfiguration.httpShouldSetCookies = false
        safeConfiguration.urlCredentialStorage = nil
        safeConfiguration.timeoutIntervalForRequest = 30
        safeConfiguration.timeoutIntervalForResource = 60
        safeConfiguration.waitsForConnectivity = true
        return URLSession(configuration: safeConfiguration)
    }

    /// Byte-transport that does **not** use `URLSession.data(for:)`.
    ///
    /// The Swift overlay of that method SIGSEGVs with a nil receiver when the
    /// app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// (OpenRouter 1.8.37, Cursor 1.8.38, Claude 1.8.39–1.8.40). `dataTask(with:)`
    /// is the ObjC API and does not go through that overlay.
    nonisolated static func data(
        for request: URLRequest,
        session: URLSession = session
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }

    /// Runs `operation` in a detached task and returns its value.
    ///
    /// The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    /// where awaiting network + decode work directly from a main-actor caller
    /// runs it as main-actor jobs. The hop back through a *stored*
    /// `fetchData` closure's reabstraction thunk then SIGSEGVs at launch
    /// (OpenRouter 1.8.37 #480, Cursor 1.8.38, Claude 1.8.39–1.8.40 #488/#490).
    /// `operation` is forwarded to `Task.detached` directly — no wrapping
    /// closure literal — so no extra thunk or isolation inference is added.
    /// `@concurrent` keeps the parameter convertible to `Task.detached`'s
    /// `@isolated(any)` operation under the app target's
    /// `SWIFT_APPROACHABLE_CONCURRENCY` (NonisolatedNonsendingByDefault),
    /// where a bare `@Sendable` async type would be `nonisolated(nonsending)`.
    nonisolated static func detached<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @concurrent @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: priority, operation: operation).value
    }

    /// `data` + `validate` on the shared session, returning the raw body.
    /// Shaped as an unapplied function reference so services can default their
    /// injectable transport with `fetchData ?? ServiceSupport.fetchValidatedData`.
    nonisolated static func fetchValidatedData(_ request: URLRequest) async throws -> Data {
        try await fetchValidatedData(request, session: session)
    }

    /// `data` + `validate` on an explicit session, returning the raw body.
    /// (An overload, not a defaulted parameter — a defaulted-param function
    /// cannot be referenced unapplied at arity 1.)
    nonisolated static func fetchValidatedData(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> Data {
        let (data, response) = try await data(for: request, session: session)
        try validate(response, data: data)
        return data
    }

    /// Validates an HTTP response, mapping 401 to `.notAuthenticated` and any
    /// other non-2xx status to `.apiError` with a consistent message format.
    /// Returns the typed response for callers that need headers/status.
    @discardableResult
    static func validate(_ response: URLResponse, data _: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.apiError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            throw ServiceError.notAuthenticated
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Provider bodies can contain account data or echoed request
            // details. Keep only the status code in errors and logs.
            throw ServiceError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return httpResponse
    }

    /// Performs a request on the shared session, validates the HTTP response,
    /// and decodes the body — mapping every failure onto `ServiceError`. Used by
    /// the org API-usage services.
    static func fetchDecoded<T: Decodable>(
        _ request: URLRequest,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        do {
            let (data, response) = try await data(for: request)
            try validate(response, data: data)
            return try decoder.decode(T.self, from: data)
        } catch {
            throw serviceError(from: error)
        }
    }

    /// Maps an arbitrary fetch error onto `ServiceError` consistently.
    /// (Catch-alls previously mislabeled network failures as `.parsingError`,
    /// so users saw "Failed to parse response" for connectivity problems.)
    static func serviceError(from error: Error) -> ServiceError {
        switch error {
        case let serviceError as ServiceError:
            return sanitize(serviceError)
        case let urlError as URLError:
            return sanitize(.apiError(message(for: urlError)))
        case is DecodingError:
            return .parsingError(nil)
        default:
            return .apiError("Request failed")
        }
    }

    /// A stable message safe for user-visible state and `.public` unified logs.
    /// Unknown error descriptions are deliberately discarded because arbitrary
    /// provider and transport errors may embed response bodies or credentials.
    static func safeErrorMessage(for error: Error) -> String {
        serviceError(from: error).localizedDescription
    }

    /// Human-readable message for a `URLError`, shared so error copy stays consistent.
    static func message(for urlError: URLError) -> String {
        switch urlError.code {
        case .notConnectedToInternet:
            return "No internet connection"
        case .cannotFindHost, .dnsLookupFailed:
            return "DNS lookup failed"
        case .timedOut:
            return "Request timed out"
        case .cancelled:
            return "Request cancelled"
        case .networkConnectionLost:
            return "Network connection lost"
        case .cannotConnectToHost:
            return "Could not connect to provider"
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return "Secure connection failed"
        default:
            return "Network request failed"
        }
    }

    private static func sanitize(_ error: ServiceError) -> ServiceError {
        // A parse detail is only ever displayable when MeterBar wrote it. Any
        // other text may be provider output, so it collapses to the generic
        // message rather than reaching a view.
        if case let .parsingError(detail) = error {
            guard let detail, ClaudeCodeParseFailure.messages.contains(detail) else {
                return .parsingError(nil)
            }
            return error
        }

        guard case let .apiError(message) = error else { return error }

        let knownSafeMessages: Set<String> = [
            "No internet connection",
            "DNS lookup failed",
            "Request timed out",
            "Request cancelled",
            "Network connection lost",
            "Could not connect to provider",
            "Secure connection failed",
            "Network request failed",
            "Invalid response type",
            "Request failed"
        ]
        if knownSafeMessages.contains(message) {
            return error
        }

        if let range = message.range(of: #"HTTP \d{3}"#, options: .regularExpression) {
            return .apiError(String(message[range]))
        }
        return .apiError("Request failed")
    }

    /// Runs `block` on the main thread — synchronously when already there, so
    /// callers on the main thread observe the state change immediately
    /// (SettingsView reads `hasAccess` right after calling `checkAccess()`).
    /// `@MainActor` on the closure lets nonisolated service code mutate
    /// main-actor `@Published` state through here without isolation warnings.
    static func applyOnMain(_ block: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(block)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(block)
            }
        }
    }

    /// The real home directory for the current user.
    ///
    /// In sandboxed builds `FileManager.homeDirectoryForCurrentUser` returns the
    /// app container path; CLI credential/log files live under the user's actual
    /// home, so resolve it via `getpwuid` (with environment and FileManager
    /// fallbacks).
    static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Expand `~` / `~/…` against the real home directory, and standardize every
    /// other path. Shared by account homes, config dirs, and CLI state roots so
    /// providers cannot diverge on `~/`-expansion edge cases.
    static func expandUserPath(
        _ rawValue: String,
        realHomeDirectory: String = realHomeDirectory()
    ) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return realHomeDirectory
        }
        if trimmed.hasPrefix("~/") {
            return (realHomeDirectory as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return (trimmed as NSString).standardizingPath
    }

    /// Compact an absolute path under the real home directory back to `~/…` for
    /// user-facing copy. Paths outside the home stay absolute.
    static func compactPathForDisplay(
        _ path: String,
        realHomeDirectory: String = realHomeDirectory()
    ) -> String {
        let resolvedPath = (path as NSString).standardizingPath
        let standardizedHome = (realHomeDirectory as NSString).standardizingPath
        let homePrefix = standardizedHome.hasSuffix("/") ? standardizedHome : "\(standardizedHome)/"

        guard resolvedPath.hasPrefix(homePrefix) else {
            return resolvedPath
        }
        return "~/\(resolvedPath.dropFirst(homePrefix.count))"
    }
}
