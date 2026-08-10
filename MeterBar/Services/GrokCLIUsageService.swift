import Combine
import Foundation
import MeterBarShared
import os

/// Reads Grok Build subscription usage through the CLI's official ACP stdio
/// extension. MeterBar asks the CLI to authenticate with its cached login and
/// never opens, decodes, logs, or persists `$GROK_HOME/auth.json`.
final class GrokCLIUsageService: ObservableObject {
    nonisolated static let shared = GrokCLIUsageService()

    @Published private(set) var hasAccess = false
    @Published private(set) var subscriptionType: String?

    /// Last fetch failure per Grok profile, keyed by account id. Profiles are
    /// fetched concurrently, so there is deliberately no provider-wide error
    /// property: a shared one would describe whichever profile finished last.
    /// Read it through `firstError(for:)`.
    @Published private(set) var accountErrors: [UUID: ServiceError] = [:]

    nonisolated private let binaryPathProvider: @Sendable () -> String?
    nonisolated private let authAvailableProvider: @Sendable (GrokAccount) -> Bool
    nonisolated private let billingResultProvider: @Sendable (String, String) async throws -> GrokBillingResult

    init(
        binaryPathProvider: @escaping @Sendable () -> String? = {
            CLIBinaryLocator.resolve(command: "grok", overrideEnvVar: "GROK_CLI_PATH")
        },
        authAvailableProvider: @escaping @Sendable (GrokAccount) -> Bool = { account in
            let path = GrokHomeDirectory.authFilePath(for: account)
            return FileManager.default.fileExists(atPath: path)
                && FileManager.default.isReadableFile(atPath: path)
        },
        billingResultProvider: @escaping @Sendable (String, String) async throws -> GrokBillingResult = {
            try await GrokBillingRPC.fetch(binaryPath: $0, grokHome: $1)
        }
    ) {
        self.binaryPathProvider = binaryPathProvider
        self.authAvailableProvider = authAvailableProvider
        self.billingResultProvider = billingResultProvider
        Task.detached(priority: .utility) { [weak self] in
            self?.checkAccess()
        }
    }

    nonisolated func checkAccess() {
        let available = canAccess(account: .defaultAccount)
        ServiceSupport.applyOnMain { [weak self] in
            guard let self else { return }
            self.hasAccess = available
            if !available {
                self.subscriptionType = nil
            }
        }
    }

    nonisolated func canAccess(account: GrokAccount) -> Bool {
        binaryPathProvider() != nil && authAvailableProvider(account)
    }

    func fetchUsageMetrics() async throws -> UsageMetrics {
        try await fetchUsageMetrics(account: .defaultAccount)
    }

    func fetchUsageMetrics(account: GrokAccount) async throws -> UsageMetrics {
        guard let binaryPath = binaryPathProvider(), authAvailableProvider(account) else {
            let error = ServiceError.notAuthenticated
            accountErrors[account.id] = error
            if account.isDefault {
                hasAccess = false
            }
            throw error
        }

        do {
            let result = try await billingResultProvider(binaryPath, GrokHomeDirectory.path(for: account))
            let metrics = try Self.map(result)
            accountErrors.removeValue(forKey: account.id)
            if account.isDefault {
                hasAccess = true
                subscriptionType = result.subscriptionTier
            }
            return metrics
        } catch {
            let serviceError = Self.serviceError(from: error)
            accountErrors[account.id] = serviceError
            if account.isDefault, case .notAuthenticated = serviceError {
                hasAccess = false
                subscriptionType = nil
            }
            AppLog.usage.error(
                "Grok profile usage fetch failed: \(serviceError.localizedDescription, privacy: .public)"
            )
            throw serviceError
        }
    }

    func firstError(for accounts: [GrokAccount]) -> ServiceError? {
        accounts.lazy.compactMap { self.accountErrors[$0.id] }.first
    }

    /// Projects Grok's quota windows onto the shared session/weekly model.
    ///
    /// Throws rather than returning a zeroed-out `UsageMetrics` when nothing
    /// usable is present: a reported 0% is indistinguishable from "plenty left",
    /// so a shape MeterBar cannot read has to surface as an honest unknown
    /// (`.parsingError`, which the parse-health store then counts as drift).
    static func map(_ result: GrokBillingResult, now: Date = Date()) throws -> UsageMetrics {
        let config = result.config
        let periods = config.usagePeriods ?? []
        let sessionPeriod = periods.first { $0.kind == .session }
        let weeklyPeriod = periods.first { $0.kind == .weekly }

        // The account-wide billing-cycle percent, in descending order of trust:
        // the number the provider reports, the one its credits pair implies, and
        // finally proto3's omitted default. It may back-fill the long window when
        // no per-period percent is reported — but never the session one.
        // Synthesizing a session percent from it is exactly the fabricated
        // reading this mapping exists to avoid.
        let accountPercent = config.creditUsagePercent
            ?? config.derivedCreditPercent
            ?? impliedZeroPercent(for: result)
        let weeklyPercent = weeklyPeriod?.usagePercent ?? accountPercent
        let sessionLimit = limit(percent: sessionPeriod?.usagePercent, window: sessionPeriod)
        let weeklyLimit = limit(percent: weeklyPercent, window: weeklyPeriod ?? config.fallbackPeriod)

        guard sessionLimit != nil || weeklyLimit != nil else {
            throw GrokBillingRPC.Error.invalidResponse
        }

        return UsageMetrics(
            service: .grok,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            extraUsage: config.extraUsageStatus,
            lastUpdated: now
        )
    }

    /// `0` when the response is a populated billing config for a dated cycle
    /// that reports no percent at all, and `nil` otherwise.
    ///
    /// The billing payload is a JSON projection of protobuf, and proto3 omits
    /// scalar defaults: `creditUsagePercent` is missing from a brand-new cycle
    /// precisely *because* it is `0.0`. Monetary fields still arrive as
    /// `{"val": 0}` only because they are submessages, not scalars — so their
    /// presence alongside a dated cycle is what separates "nothing spent yet"
    /// from a shape MeterBar cannot read, which still has to surface as an
    /// honest unknown.
    ///
    /// Deliberately keyed off the *cycle* window (`fallbackPeriod`), never a
    /// window from `usagePeriods`: a period the provider listed and left without
    /// a percent is a per-period omission, not this account-wide default.
    private static func impliedZeroPercent(for result: GrokBillingResult) -> Double? {
        let config = result.config
        guard let cycle = config.fallbackPeriod, cycle.endDate != nil else { return nil }
        guard result.hasBillingConfigContainer || config.hasBillingSignals else { return nil }
        return 0
    }

    private static func limit(percent: Double?, window: GrokBillingConfig.Period?) -> UsageLimit? {
        guard let percent else { return nil }
        return UsageLimit(
            used: min(100, max(0, percent)),
            total: 100,
            resetTime: window?.endDate,
            windowSeconds: window?.windowSeconds
        )
    }

    /// Maps a transport failure onto a `ServiceError` whose message is a fixed
    /// `GrokRefreshFailure` string, so readiness can turn it back into specific
    /// advice without any provider-supplied text surviving the trip.
    static func serviceError(from error: Error) -> ServiceError {
        guard let error = error as? GrokBillingRPC.Error else {
            if error is DecodingError {
                return .parsingError(nil)
            }
            return ServiceSupport.serviceError(from: error)
        }
        switch error {
        case .notAuthenticated:
            return .notAuthenticated
        case .invalidResponse:
            return .parsingError(nil)
        case .timedOut:
            return .apiError(GrokRefreshFailure.agentTimedOut.message)
        case .launchFailed:
            return .apiError(GrokRefreshFailure.agentStartFailed.message)
        case .unsupportedVersion:
            return .apiError(GrokRefreshFailure.unsupportedVersion.message)
        case .commandFailed:
            return .apiError(GrokRefreshFailure.requestFailed.message)
        }
    }
}

// MARK: - Tolerant decoding

/// Dynamic coding key, so the decoders below can try several spellings of the
/// same field instead of hard-failing on the one MeterBar happened to see first.
nonisolated struct GrokCodingKey: CodingKey, Sendable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    // An initializer has no return type, so the implicit-return form the rule
    // suggests (`{ nil }`) is not valid Swift here — `return nil` is failability.
    // swiftlint:disable:next implicit_return
    init?(intValue: Int) { return nil }

    /// `creditUsagePercent` → `["creditUsagePercent", "credit_usage_percent"]`.
    static func variants(of name: String) -> [String] {
        var snake = ""
        for character in name {
            if character.isUppercase {
                snake.append("_")
                snake.append(Character(character.lowercased()))
            } else {
                snake.append(character)
            }
        }
        return snake == name ? [name] : [name, snake]
    }
}

/// A number that may arrive bare (`5`), quoted (`"5"`), or wrapped in a small
/// object (`{"val": 5}`) — all three shapes have been seen from this CLI, and a
/// fourth would otherwise take the whole response down with it.
nonisolated struct GrokNumber: Decodable, Sendable {
    private static let wrapperKeys = ["val", "value", "amount", "usd", "cents"]

    let value: Double

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let double = try? single.decode(Double.self) {
                value = double
                return
            }
            if let string = try? single.decode(String.self),
               let parsed = Double(string.trimmingCharacters(in: .whitespaces)) {
                value = parsed
                return
            }
        }
        if let keyed = try? decoder.container(keyedBy: GrokCodingKey.self) {
            for key in Self.wrapperKeys {
                if let nested = try? keyed.decode(GrokNumber.self, forKey: GrokCodingKey(key)) {
                    value = nested.value
                    return
                }
            }
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unreadable number")
        )
    }
}

nonisolated enum GrokDecoding {
    /// Reads the first name that decodes into `T`, ignoring the rest. A field in
    /// a shape MeterBar cannot read is treated as absent, never as fatal.
    static func value<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<GrokCodingKey>,
        names: [String]
    ) -> T? {
        for name in names.flatMap(GrokCodingKey.variants(of:)) {
            // `try?` flattens the optional, so a key that is absent and a key in
            // a shape this type cannot read look the same here — both just move
            // on to the next spelling.
            if let decoded = try? container.decodeIfPresent(type, forKey: GrokCodingKey(name)) {
                return decoded
            }
        }
        return nil
    }

    static func number(
        _ container: KeyedDecodingContainer<GrokCodingKey>,
        _ names: [String]
    ) -> Double? {
        value(GrokNumber.self, from: container, names: names)?.value
    }

    static func string(
        _ container: KeyedDecodingContainer<GrokCodingKey>,
        _ names: [String]
    ) -> String? {
        value(String.self, from: container, names: names)
    }
}

// MARK: - Billing response

nonisolated struct GrokBillingResult: Decodable, Sendable {
    let config: GrokBillingConfig
    let subscriptionTier: String?

    /// Whether the payload carried the config under its own key rather than
    /// inlined. A named container is the provider stating this *is* a billing
    /// config, which is what lets an omitted percent be read as zero.
    let hasBillingConfigContainer: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: GrokCodingKey.self)
        // If the config moves or is inlined at the top level, decode the outer
        // object as the config rather than reporting nothing at all.
        if let nested = GrokDecoding.value(
            GrokBillingConfig.self,
            from: container,
            names: ["config", "billingConfig", "billing"]
        ) {
            config = nested
            hasBillingConfigContainer = true
        } else {
            config = try GrokBillingConfig(from: decoder)
            hasBillingConfigContainer = false
        }
        subscriptionTier = GrokDecoding.string(
            container,
            ["subscriptionTier", "tier", "plan", "planName"]
        )
    }
}

nonisolated struct GrokBillingConfig: Decodable, Sendable {
    struct Period: Decodable, Sendable {
        /// Which shared quota window a provider period belongs to.
        enum Kind: Sendable {
            case session
            case weekly
        }

        let type: String?
        let start: String?
        let end: String?
        let usagePercent: Double?

        init(type: String?, start: String?, end: String?, usagePercent: Double?) {
            self.type = type
            self.start = start
            self.end = end
            self.usagePercent = usagePercent
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: GrokCodingKey.self)
            type = GrokDecoding.string(container, ["type", "periodType", "kind"])
            start = GrokDecoding.string(container, ["start", "startDate", "startTime", "periodStart"])
            end = GrokDecoding.string(container, ["end", "endDate", "endTime", "periodEnd"])
            usagePercent = GrokDecoding.number(
                container,
                ["usagePercent", "percent", "usedPercent", "utilizationPercent"]
            )
        }

        var startDate: Date? { start.flatMap(FlexibleISO8601.date(from:)) }
        var endDate: Date? { end.flatMap(FlexibleISO8601.date(from:)) }

        var windowSeconds: TimeInterval? {
            guard let startDate, let endDate else { return nil }
            let duration = endDate.timeIntervalSince(startDate)
            return duration > 0 ? duration : nil
        }

        /// Classified by the provider's own token where possible, and by window
        /// length otherwise — a new token spelling should re-bucket the period,
        /// not drop it.
        var kind: Kind? {
            if let token = type?.uppercased() {
                if ["WEEK", "MONTH", "BILLING", "CYCLE"].contains(where: token.contains) {
                    return .weekly
                }
                if ["HOUR", "DAILY", "DAY", "SESSION"].contains(where: token.contains) {
                    return .session
                }
            }
            guard let windowSeconds else { return nil }
            return windowSeconds <= 24 * 60 * 60 ? .session : .weekly
        }
    }

    /// The credits pair a unified-billing account reports instead of a percent.
    /// Carried in its own object on some responses and inlined on others, so
    /// both spellings feed the same three fields.
    struct Credits: Decodable, Sendable {
        let monthlyLimit: Double?
        let totalUsed: Double?
        let includedUsed: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: GrokCodingKey.self)
            monthlyLimit = GrokDecoding.number(container, ["monthlyLimit", "limit", "allowance"])
            totalUsed = GrokDecoding.number(container, ["totalUsed", "used"])
            includedUsed = GrokDecoding.number(container, ["includedUsed"])
        }
    }

    let creditUsagePercent: Double?
    let currentPeriod: Period?
    let usagePeriods: [Period]?
    let monthlyLimit: Double?
    let totalUsed: Double?
    let includedUsed: Double?
    let onDemandCap: Double?
    let onDemandUsed: Double?
    let prepaidBalance: Double?
    let isUnifiedBillingUser: Bool?
    let billingPeriodStart: String?
    let billingPeriodEnd: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: GrokCodingKey.self)
        creditUsagePercent = GrokDecoding.number(
            container,
            ["creditUsagePercent", "usagePercent", "creditsUsedPercent"]
        )
        currentPeriod = GrokDecoding.value(Period.self, from: container, names: ["currentPeriod", "period"])
        usagePeriods = GrokDecoding.value(
            [Period].self,
            from: container,
            names: ["usagePeriods", "periods", "quotaPeriods", "rateLimits"]
        )
        let credits = GrokDecoding.value(
            Credits.self,
            from: container,
            names: ["usage", "credits", "latestHistory", "billingCycle"]
        )
        let inlineCredits = try? Credits(from: decoder)
        monthlyLimit = inlineCredits?.monthlyLimit ?? credits?.monthlyLimit
        totalUsed = inlineCredits?.totalUsed ?? credits?.totalUsed
        includedUsed = inlineCredits?.includedUsed ?? credits?.includedUsed
        onDemandCap = GrokDecoding.number(container, ["onDemandCap", "onDemandLimit"])
        onDemandUsed = GrokDecoding.number(container, ["onDemandUsed", "onDemandSpend"])
        prepaidBalance = GrokDecoding.number(container, ["prepaidBalance", "creditBalance"])
        isUnifiedBillingUser = GrokDecoding.value(
            Bool.self,
            from: container,
            names: ["isUnifiedBillingUser"]
        )
        billingPeriodStart = GrokDecoding.string(container, ["billingPeriodStart"])
        billingPeriodEnd = GrokDecoding.string(container, ["billingPeriodEnd"])
    }

    var billingPeriodStartDate: Date? { billingPeriodStart.flatMap(FlexibleISO8601.date(from:)) }
    var billingPeriodEndDate: Date? { billingPeriodEnd.flatMap(FlexibleISO8601.date(from:)) }

    /// The share of the cycle allowance already spent, for accounts that report
    /// the credits pair instead of a percent. Tried before the omitted-default
    /// zero, since falling through to `0` here would under-report real usage.
    var derivedCreditPercent: Double? {
        guard let monthlyLimit, monthlyLimit > 0 else { return nil }
        guard let used = totalUsed ?? includedUsed else { return nil }
        return used / monthlyLimit * 100
    }

    /// Whether any billing field decoded at all. Distinguishes a populated
    /// billing config whose percent is an omitted proto3 default from a shape
    /// that merely happens to carry a period.
    var hasBillingSignals: Bool {
        isUnifiedBillingUser != nil
            || onDemandCap != nil
            || onDemandUsed != nil
            || prepaidBalance != nil
            || monthlyLimit != nil
            || totalUsed != nil
            || includedUsed != nil
    }

    /// The billing-cycle window that `creditUsagePercent` is measured against,
    /// for responses that predate (or drop) the per-period list.
    var fallbackPeriod: Period? {
        if let currentPeriod, currentPeriod.startDate != nil || currentPeriod.endDate != nil {
            return currentPeriod
        }
        guard billingPeriodStart != nil || billingPeriodEnd != nil else { return nil }
        return Period(type: nil, start: billingPeriodStart, end: billingPeriodEnd, usagePercent: nil)
    }

    var extraUsageStatus: ExtraUsageStatus {
        guard onDemandCap != nil || onDemandUsed != nil || prepaidBalance != nil else {
            return .unknown
        }

        let cap = max(0, onDemandCap ?? 0)
        let used = max(0, onDemandUsed ?? 0)
        let balance = max(0, prepaidBalance ?? 0)
        guard cap > 0 || used > 0 || balance > 0 else {
            return ExtraUsageStatus(state: .off)
        }

        var details: [String] = []
        if balance > 0 {
            details.append("\(ExtraUsageStatus.formatAmount(balance)) credits")
        }
        if cap > 0 || used > 0 {
            details.append(
                "\(ExtraUsageStatus.formatAmount(used)) / \(ExtraUsageStatus.formatAmount(cap)) on demand"
            )
        }
        return ExtraUsageStatus(state: .on, detail: details.joined(separator: " · "))
    }
}

// MARK: - ACP transport

nonisolated enum GrokBillingRPC {
    struct Request: Sendable {
        let id: Int
        let method: String
        let data: Data
        private let strings: [String: String]
        private let nestedStrings: [String: [String: String]]

        init(
            id: Int,
            method: String,
            parameters: [String: Any],
            strings: [String: String] = [:],
            nestedStrings: [String: [String: String]] = [:]
        ) {
            self.id = id
            self.method = method
            self.strings = strings
            self.nestedStrings = nestedStrings
            let object: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": parameters
            ]
            data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }

        func stringParameter(_ key: String) -> String? {
            strings[key]
        }

        func nestedStringParameter(_ object: String, key: String) -> String? {
            nestedStrings[object]?[key]
        }
    }

    enum Error: Swift.Error, Equatable {
        case notAuthenticated
        case invalidResponse
        case timedOut
        case launchFailed
        case commandFailed
        /// The agent does not implement the billing method (JSON-RPC -32601).
        case unsupportedVersion
    }

    /// JSON-RPC's "method not found" — the one piece of evidence that separates
    /// "this build is too old" from "the request failed".
    private static let methodNotFoundCode = -32_601
    /// Deliberately shorter than the refresh interval: refreshes run in sequence,
    /// so a hung agent must not hold up every other provider.
    private static let timeout: TimeInterval = 10
    private static let queue = DispatchQueue(label: "dev.meterbar.app.GrokBillingRPC", qos: .userInitiated)

    static func requests(clientVersion: String) -> [Request] {
        [
            Request(
                id: 1,
                method: "initialize",
                parameters: [
                    "protocolVersion": 1,
                    "clientCapabilities": [String: Any](),
                    "clientInfo": ["name": "MeterBar", "version": clientVersion]
                ],
                nestedStrings: ["clientInfo": ["name": "MeterBar", "version": clientVersion]]
            ),
            Request(
                id: 2,
                method: "authenticate",
                parameters: ["methodId": "cached_token", "_meta": ["headless": true]],
                strings: ["methodId": "cached_token"]
            ),
            Request(id: 3, method: "_x.ai/billing", parameters: [:])
        ]
    }

    static func fetch(binaryPath: String, grokHome: String) async throws -> GrokBillingResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try fetchBlocking(binaryPath: binaryPath, grokHome: grokHome))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs the response half of the exchange over a recorded transcript.
    ///
    /// The fixtures that matter here — truncated frame, logged out, agent too
    /// old — are all about how MeterBar reads output, so they are tested against
    /// the real reader without spawning anything.
    static func result(replaying transcript: [String]) throws -> GrokBillingResult {
        let lines = GrokLineBuffer()
        for line in transcript {
            lines.append(Data((line + "\n").utf8))
        }
        lines.finish()

        let reader = TranscriptReader(lines: lines)
        let deadline = Date().addingTimeInterval(timeout)
        _ = try reader.response(id: 1, deadline: deadline)
        _ = try reader.response(id: 2, deadline: deadline, authenticationResponse: true)
        return try decodeBillingResult(from: reader.response(id: 3, deadline: deadline))
    }

    static func processEnvironment(
        grokHome: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = CLIBinaryLocator.augmentedPATH(environment: environment)
        environment["GROK_HOME"] = GrokHomeDirectory.expand(grokHome)
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = "dumb"
        return environment
    }

    private static func fetchBlocking(binaryPath: String, grokHome: String) throws -> GrokBillingResult {
        let environment = processEnvironment(grokHome: grokHome)
        let agent: GrokAgentProcess
        do {
            agent = try GrokAgentProcess(
                executable: binaryPath,
                arguments: ["--no-auto-update", "agent", "--no-leader", "stdio"],
                environment: environment,
                workingDirectory: ServiceSupport.realHomeDirectory()
            )
        } catch {
            throw Error.launchFailed
        }
        // Runs on every exit path, including a thrown timeout: the agent and any
        // process it spawned are killed before this call returns.
        defer { agent.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let requestSequence = requests(clientVersion: clientVersion)
        let reader = TranscriptReader(lines: agent.lines)

        try send(requestSequence[0], to: agent)
        _ = try reader.response(id: 1, deadline: deadline)

        try send(requestSequence[1], to: agent)
        _ = try reader.response(id: 2, deadline: deadline, authenticationResponse: true)

        try send(requestSequence[2], to: agent)
        return try decodeBillingResult(from: reader.response(id: 3, deadline: deadline))
    }

    private static func send(_ request: Request, to agent: GrokAgentProcess) throws {
        guard !request.data.isEmpty else { throw Error.invalidResponse }
        var line = request.data
        line.append(0x0A)
        do {
            try agent.write(line)
        } catch {
            throw Error.commandFailed
        }
    }

    private static func decodeBillingResult(from line: Data) throws -> GrokBillingResult {
        struct Envelope: Decodable {
            let result: GrokBillingResult
        }
        do {
            return try JSONDecoder().decode(Envelope.self, from: line).result
        } catch {
            throw Error.invalidResponse
        }
    }

    /// Reads JSON-RPC responses out of an agent's stdout, tolerating anything it
    /// cannot parse while remembering that it saw it — that memory is what turns
    /// "no answer" into an honest reason instead of a blanket timeout.
    private final class TranscriptReader {
        private let lines: GrokLineBuffer
        private var sawUnreadableOutput = false

        init(lines: GrokLineBuffer) {
            self.lines = lines
        }

        func response(id: Int, deadline: Date, authenticationResponse: Bool = false) throws -> Data {
            while let line = lines.nextLine(until: deadline) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    // Banners, progress chatter and truncated frames all land
                    // here; only the fact that they happened is kept.
                    if !line.isEmpty {
                        sawUnreadableOutput = true
                    }
                    continue
                }
                guard object["id"] as? Int == id else { continue }
                if object["error"] != nil {
                    throw failure(
                        code: (object["error"] as? [String: Any])?["code"] as? Int,
                        authenticationResponse: authenticationResponse
                    )
                }
                guard object["result"] != nil else { throw Error.invalidResponse }
                return line
            }
            throw exhaustionFailure()
        }

        private func failure(code: Int?, authenticationResponse: Bool) -> Error {
            if authenticationResponse {
                return .notAuthenticated
            }
            return code == GrokBillingRPC.methodNotFoundCode ? .unsupportedVersion : .commandFailed
        }

        /// The stream ended without the answer. Which failure that is depends on
        /// *how* it ended: unreadable output means MeterBar could not parse what
        /// it got, a closed stream means the agent gave up, and anything else
        /// means the deadline ran out first.
        private func exhaustionFailure() -> Error {
            if lines.didOverflow || sawUnreadableOutput {
                return .invalidResponse
            }
            return lines.hasFinished ? .commandFailed : .timedOut
        }
    }
}
