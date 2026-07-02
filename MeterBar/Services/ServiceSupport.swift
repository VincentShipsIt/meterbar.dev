import Foundation

/// Shared helpers for the local provider usage services.
///
/// Centralizes the URLSession configuration, HTTP response validation, error
/// mapping, browser-spoof headers, main-thread state application, and the real
/// (non-sandboxed) home directory lookup so all services behave consistently.
enum ServiceSupport {
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
    static func validate(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.apiError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            throw ServiceError.notAuthenticated
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ServiceError.apiError("HTTP \(httpResponse.statusCode): \(body.prefix(200))")
        }

        return httpResponse
    }

    /// Maps an arbitrary fetch error onto `ServiceError` consistently.
    /// (Catch-alls previously mislabeled network failures as `.parsingError`,
    /// so users saw "Failed to parse response" for connectivity problems.)
    static func serviceError(from error: Error) -> ServiceError {
        switch error {
        case let serviceError as ServiceError:
            return serviceError
        case let urlError as URLError:
            return .apiError(message(for: urlError))
        case is DecodingError:
            return .parsingError
        default:
            return .apiError(error.localizedDescription)
        }
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
        default:
            return urlError.localizedDescription
        }
    }

    /// Runs `block` on the main thread — synchronously when already there, so
    /// callers on the main thread observe the state change immediately
    /// (SettingsView reads `hasAccess` right after calling `checkAccess()`).
    static func applyOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
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
