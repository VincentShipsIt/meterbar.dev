import Foundation

nonisolated enum QuotaWebhookPostResult: Equatable, Sendable {
    case succeeded
    case failed(String)
}

/// Blocks every redirect. A public endpoint cannot redirect the request into a
/// loopback/private target after the configured URL passed validation.
nonisolated private final class QuotaWebhookRedirectBlocker: NSObject, URLSessionTaskDelegate {
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

/// Minimal, ephemeral, cookie-free webhook transport. It discards response
/// bodies and returns only bounded diagnostic copy.
nonisolated final class QuotaWebhookClient: @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval
    private let redirectBlocker: QuotaWebhookRedirectBlocker
    private let hostIsPublic: @Sendable (String) async -> Bool

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        timeout: TimeInterval = 10,
        hostIsPublic: @escaping @Sendable (String) async -> Bool = { host in
            await Task.detached {
                QuotaWebhookURLPolicy.hostResolvesOnlyToPublicAddresses(host)
            }.value
        }
    ) {
        let safeConfiguration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        safeConfiguration.urlCache = nil
        safeConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        safeConfiguration.httpCookieStorage = nil
        safeConfiguration.httpShouldSetCookies = false
        safeConfiguration.urlCredentialStorage = nil
        safeConfiguration.timeoutIntervalForRequest = max(0.01, timeout)
        safeConfiguration.timeoutIntervalForResource = max(0.01, timeout)

        let redirectBlocker = QuotaWebhookRedirectBlocker()
        self.redirectBlocker = redirectBlocker
        session = URLSession(
            configuration: safeConfiguration,
            delegate: redirectBlocker,
            delegateQueue: nil
        )
        self.timeout = max(0.01, timeout)
        self.hostIsPublic = hostIsPublic
    }

    func post(
        payload: QuotaEventPayload,
        to url: URL
    ) async -> QuotaWebhookPostResult {
        guard QuotaWebhookURLPolicy.validatedURL(url.absoluteString) != nil else {
            return .failed("Webhook URL is not allowed.")
        }
        guard let host = url.host, await hostIsPublic(host) else {
            return .failed("Webhook host is not public.")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            return .failed("Webhook payload could not be encoded.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MeterBar/\(QuotaEventPayload.currentSchemaVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("Webhook returned an invalid response.")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                return .failed("Webhook returned HTTP \(httpResponse.statusCode).")
            }
            return .succeeded
        } catch let error as URLError where error.code == .timedOut {
            return .failed("Webhook request timed out.")
        } catch {
            return .failed("Webhook request failed.")
        }
    }
}
