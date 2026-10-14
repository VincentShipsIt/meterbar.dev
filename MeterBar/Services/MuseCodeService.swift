import Combine
import Foundation
import MeterBarShared

/// One account-endpoint response. The body is parsed immediately and never stored.
struct MuseCodeHTTPResponse: Sendable {
    var status: Int
    var retryAfter: String?
    var body: Data
}

/// Injected edges for `MuseCodeService`. Production uses `live`; tests replace
/// the file, Keychain, clock, and transport so no test reads a real login.
struct MuseCodeServiceDependencies: Sendable {
    var isEnabled: @Sendable () -> Bool
    var environment: [String: String]
    var realHomeDirectory: String
    var now: @Sendable () -> Date
    var minimumInterval: TimeInterval
    var gate: ClaudeUsageRateLimitGate
    var fileExists: @Sendable (String) -> Bool
    var loadAuth: @Sendable (String) -> MuseCodeAuthLoad
    var keychain: @Sendable (ClaudeKeychainAccessMode) -> ClaudeKeychainReadOutcome<Data>
    var transport: @Sendable (URLRequest) async throws -> MuseCodeHTTPResponse

    static let live = MuseCodeServiceDependencies(
        isEnabled: {
            UserDefaults.standard.bool(forKey: StorageKeys.museCodeProviderEnabled)
        },
        environment: ProcessInfo.processInfo.environment,
        realHomeDirectory: ServiceSupport.realHomeDirectory(),
        now: { Date() },
        minimumInterval: MuseCodeService.minimumRequestInterval,
        gate: ClaudeUsageRateLimitGate(),
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        loadAuth: { MuseCodeCredentialReader.loadAuthFile(at: $0) },
        keychain: { MuseCodeKeychainQuery.read(mode: $0) },
        transport: MuseCodeLiveTransport.send
    )
}

/// Production POST. Ephemeral session, `api.meta.ai` only. A free function on a
/// nonisolated type so the default transport stays sendable off the main actor.
nonisolated enum MuseCodeLiveTransport {
    nonisolated static func send(_ request: URLRequest) async throws -> MuseCodeHTTPResponse {
        let (data, response) = try await ServiceSupport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.apiError("Request failed")
        }
        return MuseCodeHTTPResponse(
            status: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: data
        )
    }
}

/// Fetches Muse Code quota from `POST https://api.meta.ai/muse-code/key`.
///
/// Meta's CLI uses this endpoint for `/usage`. It is not a versioned public
/// API. Each call mints an inference key server-side, so refreshes coalesce and
/// wait at least 60 seconds per account after a request is sent. A disabled
/// provider never reads the login file, the Keychain, or the network.
///
/// The response's minted `api_key`, payment details, and account identity are
/// discarded by `MuseCodeUsageParser` and are never logged, stored, or copied
/// into an error. Background Keychain reads cannot present UI. The prompt
/// exists only for `connect()`.
final class MuseCodeService: ObservableObject, SimpleUsageProviding {
    nonisolated static let shared = MuseCodeService()
    nonisolated static let usageEndpoint = "https://api.meta.ai/muse-code/key"
    static let minimumRequestInterval: TimeInterval = 60

    @Published private(set) var lastError: ServiceError?
    /// `subs_tier_name`, verbatim. Memory only — not a cache or CLI field.
    @Published private(set) var planName: String?
    /// Authored state copy for an empty card and the Settings row.
    @Published private(set) var statusNote: String?
    /// Header stamp for a retained idle reading. Nil when the bars are current.
    @Published private(set) var asOfNote: String?

    private let dependencies: MuseCodeServiceDependencies
    private var lastGood: UsageMetrics?
    private var replay: Replay?
    private var blockedUntil: Date?
    private var inFlight: Flight?

    init(dependencies: MuseCodeServiceDependencies = .live) {
        self.dependencies = dependencies
    }

    /// No-UI sign-in outcome for readiness. Does not mint a key and does not
    /// use a test double.
    nonisolated static func currentProbe() -> MuseCodeCredentialProbe {
        let enabled = UserDefaults.standard.bool(forKey: StorageKeys.museCodeProviderEnabled)
        return MuseCodeCredentialReader.read(
            MuseCodeCredentialReader.Context(
                enabled: enabled,
                environment: ProcessInfo.processInfo.environment,
                realHomeDirectory: ServiceSupport.realHomeDirectory(),
                accessMode: .background,
                loadAuth: { MuseCodeCredentialReader.loadAuthFile(at: $0) },
                keychain: { MuseCodeKeychainQuery.read(mode: $0) }
            )
        ).probe
    }

    /// File existence only. Disabled providers do not stat the login file, and
    /// this never opens the Keychain.
    var hasAccess: Bool {
        guard dependencies.isEnabled() else { return false }
        return dependencies.fileExists(authPath)
    }

    func credentialProbe() -> MuseCodeCredentialProbe {
        MuseCodeCredentialReader.read(credentialContext(interactive: false)).probe
    }

    func fetchUsageMetrics() async throws -> UsageMetrics {
        try await run(interactive: false, honorInterval: true)
    }

    /// The only path allowed to show the macOS Keychain prompt. It still
    /// respects a 429 cooldown and the 60-second mint interval.
    @discardableResult
    func connect() async throws -> UsageMetrics {
        try await run(interactive: true, honorInterval: true)
    }

    // MARK: - Coalesce

    private func run(interactive: Bool, honorInterval: Bool) async throws -> UsageMetrics {
        guard dependencies.isEnabled() else {
            lastError = .notAuthenticated
            throw ServiceError.notAuthenticated
        }
        if let flight = inFlight {
            // A prompt must not ride a silent read. Wait it out, then start
            // the prompted read unless that read already started the interval.
            if interactive, !flight.interactive {
                _ = try? await flight.task.value
                if inFlight?.id == flight.id {
                    inFlight = nil
                }
                return try await run(interactive: true, honorInterval: honorInterval)
            }
            return try await flight.task.value
        }
        let flight = Flight(id: UUID(), interactive: interactive, task: Task {
            try await self.perform(interactive: interactive, honorInterval: honorInterval)
        })
        inFlight = flight
        defer {
            if inFlight?.id == flight.id {
                inFlight = nil
            }
        }
        return try await flight.task.value
    }

    private func perform(interactive: Bool, honorInterval: Bool) async throws -> UsageMetrics {
        if let blockedUntil, dependencies.now() < blockedUntil {
            let error = ServiceError.apiError("HTTP 429")
            lastError = error
            throw error
        }
        if honorInterval, let replay, dependencies.now() < replay.until {
            return try materialize(replay)
        }
        // Off the main actor so a blocking Keychain copy cannot deadlock it.
        let context = credentialContext(interactive: interactive)
        let credential = try await ServiceSupport.detached {
            MuseCodeCredentialReader.read(context)
        }
        switch credential {
        case .disabled:
            lastError = .notAuthenticated
            throw ServiceError.notAuthenticated
        case .notSignedIn:
            try failSignIn(MuseCodeCopy.notSignedIn)
        case .rejectedToken:
            try failSignIn(MuseCodeCopy.rejectedToken)
        case .unreadable:
            try failSignIn(MuseCodeCopy.unreadable)
        case .noSubscription:
            return localAnswer(MuseCodeCopy.noSubscription)
        case .needsConnect:
            return unanswered(MuseCodeCopy.needsConnect)
        case .needsKeychainAccess:
            return unanswered(MuseCodeCopy.needsKeychainAccess)
        case let .token(token):
            return try await fetchQuota(token: token, honorInterval: honorInterval)
        }
    }

    /// An answer with no bars. Clears the retained reading so a later idle
    /// response cannot invent a percentage from it.
    private func localAnswer(_ note: String) -> UsageMetrics {
        applyAnswer(metrics: emptyMetrics(), plan: nil, statusNote: note, asOfNote: nil, error: nil)
    }

    /// Connect and Keychain states are answers. They do not mint a key and they
    /// leave a previous reading in place for a later idle response.
    private func unanswered(_ note: String) -> UsageMetrics {
        applyAnswer(
            metrics: emptyMetrics(),
            plan: planName,
            statusNote: note,
            asOfNote: nil,
            error: nil,
            keepAsLastGood: true
        )
    }

    private func failSignIn(_ note: String) throws -> Never {
        planName = nil
        statusNote = note
        asOfNote = nil
        lastError = .notAuthenticated
        lastGood = nil
        throw ServiceError.notAuthenticated
    }

    // MARK: - Network

    private func fetchQuota(token: String, honorInterval: Bool) async throws -> UsageMetrics {
        let instant = dependencies.now()
        if honorInterval, let replay, instant < replay.until {
            return try materialize(replay)
        }

        let request = try Self.makeRequest(bearer: token)
        let transport = dependencies.transport
        let sentAt = dependencies.now()
        let response: MuseCodeHTTPResponse
        do {
            response = try await ServiceSupport.detached {
                try await transport(request)
            }
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            remember(at: sentAt, metrics: nil, error: serviceError)
            lastError = serviceError
            throw serviceError
        }
        return try interpret(response, token: token, sentAt: sentAt)
    }

    private func interpret(
        _ response: MuseCodeHTTPResponse,
        token: String,
        sentAt: Date
    ) throws -> UsageMetrics {
        let status = response.status
        if status == 429 {
            dependencies.gate.recordRateLimit(token: token, retryAfter: response.retryAfter, now: sentAt)
            blockedUntil = sentAt.addingTimeInterval(
                ClaudeUsageRateLimitGate.cooldown(retryAfter: response.retryAfter, now: sentAt)
            )
            let error = ServiceError.apiError("HTTP 429")
            remember(at: sentAt, metrics: nil, error: error)
            lastError = error
            throw error
        }
        if status == 401 || status == 403 {
            statusNote = MuseCodeCopy.reconnect
            asOfNote = nil
            lastError = .notAuthenticated
            let error = ServiceError.notAuthenticated
            remember(at: sentAt, metrics: nil, error: error)
            throw error
        }
        guard (200 ... 299).contains(status) else {
            let error = ServiceError.apiError("HTTP \(status)")
            remember(at: sentAt, metrics: nil, error: error)
            lastError = error
            throw error
        }

        let reading: MuseCodeUsageReading
        do {
            reading = try MuseCodeUsageParser.parse(response.body)
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            remember(at: sentAt, metrics: nil, error: serviceError)
            lastError = serviceError
            throw serviceError
        }
        blockedUntil = nil
        dependencies.gate.clear(token: token)
        let metrics = apply(reading)
        remember(at: sentAt, metrics: metrics, error: nil)
        return metrics
    }

    private func apply(_ reading: MuseCodeUsageReading) -> UsageMetrics {
        switch reading {
        case let .quota(plan, session, weekly):
            let metrics = UsageMetrics(
                service: .museCode,
                sessionLimit: session,
                weeklyLimit: weekly,
                lastUpdated: dependencies.now()
            )
            return applyAnswer(metrics: metrics, plan: plan, statusNote: nil, asOfNote: nil, error: nil)
        case let .idle(plan):
            if let kept = MuseCodeIdleRetention.retained(from: lastGood, now: dependencies.now()) {
                let stamp = MuseCodeCopy.asOf(Self.iso8601(kept.lastUpdated))
                return applyAnswer(
                    metrics: kept,
                    plan: plan,
                    statusNote: stamp,
                    asOfNote: stamp,
                    error: nil,
                    keepAsLastGood: true
                )
            }
            return applyAnswer(
                metrics: emptyMetrics(),
                plan: plan,
                statusNote: MuseCodeCopy.idle,
                asOfNote: nil,
                error: nil
            )
        case let .inactive(plan):
            return applyAnswer(
                metrics: emptyMetrics(),
                plan: plan,
                statusNote: MuseCodeCopy.noSubscription,
                asOfNote: nil,
                error: nil
            )
        case let .paymentRequired(plan):
            return applyAnswer(
                metrics: emptyMetrics(),
                plan: plan,
                statusNote: MuseCodeCopy.paymentRequired,
                asOfNote: nil,
                error: nil
            )
        }
    }

    // MARK: - State

    @discardableResult
    private func applyAnswer(
        metrics: UsageMetrics,
        plan: String?,
        statusNote: String?,
        asOfNote: String?,
        error: ServiceError?,
        keepAsLastGood: Bool = false
    ) -> UsageMetrics {
        planName = plan
        self.statusNote = statusNote
        self.asOfNote = asOfNote
        lastError = error
        if keepAsLastGood {
            if metrics.hasData {
                lastGood = metrics
            }
        } else if error == nil, metrics.hasData {
            lastGood = metrics
        } else if error == nil {
            lastGood = nil
        }
        return metrics
    }

    private func remember(at sentAt: Date, metrics: UsageMetrics?, error: ServiceError?) {
        if let error {
            lastError = error
        }
        replay = Replay(
            until: sentAt.addingTimeInterval(dependencies.minimumInterval),
            metrics: metrics,
            error: error,
            planName: planName,
            statusNote: statusNote,
            asOfNote: asOfNote,
            lastError: lastError
        )
    }

    private func materialize(_ replay: Replay) throws -> UsageMetrics {
        planName = replay.planName
        statusNote = replay.statusNote
        asOfNote = replay.asOfNote
        lastError = replay.lastError
        if let error = replay.error {
            throw error
        }
        return replay.metrics ?? emptyMetrics()
    }

    private func credentialContext(interactive: Bool) -> MuseCodeCredentialReader.Context {
        MuseCodeCredentialReader.Context(
            enabled: dependencies.isEnabled(),
            environment: dependencies.environment,
            realHomeDirectory: dependencies.realHomeDirectory,
            accessMode: interactive ? .interactive : .background,
            loadAuth: dependencies.loadAuth,
            keychain: dependencies.keychain
        )
    }

    private var authPath: String {
        MuseCodeCredentialReader.authFilePath(
            environment: dependencies.environment,
            realHomeDirectory: dependencies.realHomeDirectory
        )
    }

    private func emptyMetrics() -> UsageMetrics {
        UsageMetrics(service: .museCode)
    }

    nonisolated private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func makeRequest(bearer token: String) throws -> URLRequest {
        let prefix = "dca:"
        guard token.hasPrefix(prefix), token.count > prefix.count else {
            throw ServiceError.notAuthenticated
        }
        guard let url = URL(string: usageEndpoint), url.host == "api.meta.ai" else {
            throw ServiceError.apiError("Request failed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = ServiceSupport.usageRequestTimeout
        return request
    }

    private struct Flight {
        let id: UUID
        let interactive: Bool
        let task: Task<UsageMetrics, Error>
    }

    /// Interval replay. One login, one clock. The token is not hashed or stored.
    private struct Replay {
        let until: Date
        let metrics: UsageMetrics?
        let error: ServiceError?
        let planName: String?
        let statusNote: String?
        let asOfNote: String?
        let lastError: ServiceError?
    }
}
