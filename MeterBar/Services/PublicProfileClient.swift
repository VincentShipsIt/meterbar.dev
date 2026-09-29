import Foundation

nonisolated enum PublicProfileResult: Equatable, Sendable {
    case ok
    /// The server refused the key for this slug (401/403/409): someone else
    /// holds the slug, or the key was lost. Retrying cannot fix it.
    case rejected
    case failed(String)
}

/// Refuses every redirect: the request carries the publish key as a bearer
/// token and must not follow a 3xx to another host.
nonisolated final class PublicProfileRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Talks to the two profile endpoints on meterbar.dev and to nothing else.
///
/// Ephemeral, cookie-free, cache-free, and redirect-blocked.
nonisolated final class PublicProfileClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = PublicProfileEndpoint.baseURL, configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        let safe = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        safe.urlCache = nil
        safe.requestCachePolicy = .reloadIgnoringLocalCacheData
        safe.httpCookieStorage = nil
        safe.httpShouldSetCookies = false
        safe.urlCredentialStorage = nil
        safe.timeoutIntervalForRequest = 15
        safe.timeoutIntervalForResource = 30
        session = URLSession(configuration: safe, delegate: PublicProfileRedirectBlocker(), delegateQueue: nil)
    }

    func publish(_ document: PublicProfileDocument, slug: String, publishKey: String) async -> PublicProfileResult {
        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            body = try encoder.encode(document)
        } catch {
            return .failed("The profile could not be encoded.")
        }
        var request = makeRequest(method: "PUT", slug: slug, publishKey: publishKey)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return await perform(request, successCodes: 200...204, missingIsSuccess: false)
    }

    /// Idempotent: a profile that is already gone counts as deleted.
    func delete(slug: String, publishKey: String) async -> PublicProfileResult {
        await perform(
            makeRequest(method: "DELETE", slug: slug, publishKey: publishKey),
            successCodes: 200...204,
            missingIsSuccess: true
        )
    }

    private func makeRequest(method: String, slug: String, publishKey: String) -> URLRequest {
        var request = URLRequest(url: PublicProfileEndpoint.apiURL(slug: slug, base: baseURL))
        request.httpMethod = method
        request.setValue("Bearer \(publishKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MeterBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func perform(
        _ request: URLRequest,
        successCodes: ClosedRange<Int>,
        missingIsSuccess: Bool
    ) async -> PublicProfileResult {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("The server sent an invalid response.")
            }
            switch http.statusCode {
            case successCodes:
                return .ok
            case 404 where missingIsSuccess:
                return .ok
            case 401, 403, 409:
                return .rejected
            default:
                return .failed("meterbar.dev answered HTTP \(http.statusCode).")
            }
        } catch {
            return .failed("Could not reach meterbar.dev.")
        }
    }
}
