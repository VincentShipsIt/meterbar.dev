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

    static func makeUsageSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
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
            let (data, response) = try await session.data(for: request)
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
            return .parsingError
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
    static func applyOnMain(_ block: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(block)
        } else {
            DispatchQueue.main.async { block() }
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
}
