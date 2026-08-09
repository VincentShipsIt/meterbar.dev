import Foundation

nonisolated enum QuotaWebhookPostResult: Equatable, Sendable {
    case succeeded
    case failed(String)
}

/// Blocks redirects and records the address URLSession actually connected to.
/// The record closes the DNS-rebinding gap between the policy's pre-flight DNS
/// lookup and URLSession's independent lookup at connection time.
nonisolated final class QuotaWebhookConnectionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var remoteAddresses: [Int: String] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let remoteAddress = metrics.transactionMetrics.last?.remoteAddress else { return }
        recordRemoteAddress(remoteAddress, forTaskIdentifier: task.taskIdentifier)
    }

    /// Removes the entry as part of the read so repeated deliveries and failed
    /// tasks cannot grow the correlation map without bound.
    func takeRemoteAddress(forTaskIdentifier taskIdentifier: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return remoteAddresses.removeValue(forKey: taskIdentifier)
    }

    /// Internal seam used by deterministic URLProtocol tests, whose synthetic
    /// loads do not produce transaction metrics or a remote address.
    func recordRemoteAddress(_ address: String, forTaskIdentifier taskIdentifier: Int) {
        lock.lock()
        remoteAddresses[taskIdentifier] = address
        lock.unlock()
    }

    var observedAddressCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return remoteAddresses.count
    }
}

/// Minimal, ephemeral, cookie-free webhook transport. It discards response
/// bodies and returns only bounded diagnostic copy.
nonisolated final class QuotaWebhookClient: @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval
    private let connectionDelegate: QuotaWebhookConnectionDelegate
    private let hostIsPublic: @Sendable (String) async -> Bool
    private let taskCreatedForTesting: (@Sendable (URLSessionTask) -> Void)?

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        timeout: TimeInterval = 10,
        hostIsPublic: @escaping @Sendable (String) async -> Bool = { host in
            await Task.detached {
                QuotaWebhookURLPolicy.hostResolvesOnlyToPublicAddresses(host)
            }.value
        },
        connectionDelegate: QuotaWebhookConnectionDelegate = QuotaWebhookConnectionDelegate(),
        taskCreatedForTesting: (@Sendable (URLSessionTask) -> Void)? = nil
    ) {
        let safeConfiguration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        safeConfiguration.urlCache = nil
        safeConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        safeConfiguration.httpCookieStorage = nil
        safeConfiguration.httpShouldSetCookies = false
        safeConfiguration.urlCredentialStorage = nil
        safeConfiguration.timeoutIntervalForRequest = max(0.01, timeout)
        safeConfiguration.timeoutIntervalForResource = max(0.01, timeout)

        self.connectionDelegate = connectionDelegate
        session = URLSession(
            configuration: safeConfiguration,
            delegate: connectionDelegate,
            delegateQueue: nil
        )
        self.timeout = max(0.01, timeout)
        self.hostIsPublic = hostIsPublic
        self.taskCreatedForTesting = taskCreatedForTesting
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

        let transport = await perform(request)
        let observedAddress = connectionDelegate.takeRemoteAddress(
            forTaskIdentifier: transport.taskIdentifier
        )

        // URLProtocol stubs and some non-network/OS-specific loads expose no
        // `remoteAddress`. Fail open in that case: treating an absent metric as
        // hostile would break deterministic tests and could disable legitimate
        // webhook delivery if a future OS stops populating the field.
        if let observedAddress,
           QuotaWebhookURLPolicy.isUnsafeAddressLiteral(observedAddress) {
            AppLog.app.error("Webhook connected to a non-public address; delivery rejected.")
            return .failed("Webhook connected to a non-public address.")
        }

        switch transport.result {
        case .success(let response):
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("Webhook returned an invalid response.")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                return .failed("Webhook returned HTTP \(httpResponse.statusCode).")
            }
            return .succeeded
        case .failure(let error):
            if let urlError = error as? URLError, urlError.code == .timedOut {
                return .failed("Webhook request timed out.")
            }
            return .failed("Webhook request failed.")
        }
    }

    /// Uses an explicit task so its identifier can correlate transaction
    /// metrics with this awaiting call. Metrics are documented to arrive before
    /// task completion, so the caller reads once without blocking or polling.
    ///
    /// IP pinning was considered and rejected: replacing the URL host with an
    /// address literal would disable URLSession's normal TLS hostname check and
    /// require hand-rolled certificate validation against the original host, a
    /// larger and harder-to-test security regression than this post-flight gate.
    private func perform(_ request: URLRequest) async -> QuotaWebhookTransport {
        await withCheckedContinuation { continuation in
            let taskIdentity = QuotaWebhookTaskIdentity()
            let task = session.dataTask(with: request) { _, response, error in
                let result: Result<URLResponse, Error>
                if let error {
                    result = .failure(error)
                } else if let response {
                    result = .success(response)
                } else {
                    result = .failure(URLError(.unknown))
                }
                continuation.resume(
                    returning: QuotaWebhookTransport(taskIdentifier: taskIdentity.value, result: result)
                )
            }
            taskIdentity.store(task.taskIdentifier)
            taskCreatedForTesting?(task)
            task.resume()
        }
    }
}

nonisolated private struct QuotaWebhookTransport: @unchecked Sendable {
    let taskIdentifier: Int
    let result: Result<URLResponse, Error>
}

/// Bridges the identifier assigned after `dataTask(with:)` constructs the task
/// into its concurrently executing completion callback without capturing and
/// mutating a local variable across isolation domains.
nonisolated private final class QuotaWebhookTaskIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var taskIdentifier = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return taskIdentifier
    }

    func store(_ value: Int) {
        lock.lock()
        taskIdentifier = value
        lock.unlock()
    }
}
