import Combine
import Foundation
import MeterBarShared
import os

/// Reads Grok Build subscription usage through the CLI's official ACP stdio
/// extension. MeterBar asks the CLI to authenticate with its cached login and
/// never opens, decodes, logs, or persists `~/.grok/auth.json`.
final class GrokCLIUsageService: ObservableObject {
    nonisolated static let shared = GrokCLIUsageService()

    @Published private(set) var hasAccess = false
    @Published private(set) var lastError: ServiceError?
    @Published private(set) var subscriptionType: String?

    nonisolated private let binaryPathProvider: @Sendable () -> String?
    nonisolated private let authAvailableProvider: @Sendable () -> Bool
    nonisolated private let billingResultProvider: @Sendable (String) async throws -> GrokBillingResult

    init(
        binaryPathProvider: @escaping @Sendable () -> String? = {
            CLIBinaryLocator.resolve(command: "grok", overrideEnvVar: "GROK_CLI_PATH")
        },
        authAvailableProvider: @escaping @Sendable () -> Bool = {
            let path = GrokCLIUsageService.authFilePath()
            return FileManager.default.fileExists(atPath: path)
                && FileManager.default.isReadableFile(atPath: path)
        },
        billingResultProvider: @escaping @Sendable (String) async throws -> GrokBillingResult = {
            try await GrokBillingRPC.fetch(binaryPath: $0)
        }
    ) {
        self.binaryPathProvider = binaryPathProvider
        self.authAvailableProvider = authAvailableProvider
        self.billingResultProvider = billingResultProvider
        Task.detached(priority: .utility) { [weak self] in
            self?.checkAccess()
        }
    }

    nonisolated static func authFilePath(home: String = ServiceSupport.realHomeDirectory()) -> String {
        "\(home)/.grok/auth.json"
    }

    nonisolated func checkAccess() {
        let available = binaryPathProvider() != nil && authAvailableProvider()
        ServiceSupport.applyOnMain { [weak self] in
            guard let self else { return }
            self.hasAccess = available
            if !available {
                self.subscriptionType = nil
            }
        }
    }

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let binaryPath = binaryPathProvider(), authAvailableProvider() else {
            let error = ServiceError.notAuthenticated
            hasAccess = false
            lastError = error
            throw error
        }

        do {
            let result = try await billingResultProvider(binaryPath)
            let metrics = Self.map(result)
            hasAccess = true
            subscriptionType = result.subscriptionTier
            lastError = nil
            return metrics
        } catch {
            let serviceError = Self.serviceError(from: error)
            lastError = serviceError
            if case .notAuthenticated = serviceError {
                hasAccess = false
                subscriptionType = nil
            }
            AppLog.usage.error("Grok usage fetch failed: \(serviceError.localizedDescription, privacy: .public)")
            throw serviceError
        }
    }

    static func map(_ result: GrokBillingResult, now: Date = Date()) -> UsageMetrics {
        let periodStart = result.config.currentPeriod?.startDate ?? result.config.billingPeriodStartDate
        let periodEnd = result.config.currentPeriod?.endDate ?? result.config.billingPeriodEndDate
        let windowSeconds: TimeInterval? = {
            guard let periodStart, let periodEnd else { return nil }
            let duration = periodEnd.timeIntervalSince(periodStart)
            return duration > 0 ? duration : nil
        }()
        let weeklyLimit = UsageLimit(
            used: max(0, result.config.creditUsagePercent),
            total: 100,
            resetTime: periodEnd,
            windowSeconds: windowSeconds
        )

        return UsageMetrics(
            service: .grok,
            weeklyLimit: weeklyLimit,
            extraUsage: result.config.extraUsageStatus,
            lastUpdated: now
        )
    }

    private static func serviceError(from error: Error) -> ServiceError {
        guard let error = error as? GrokBillingRPC.Error else {
            if error is DecodingError {
                return .parsingError
            }
            return ServiceSupport.serviceError(from: error)
        }
        switch error {
        case .notAuthenticated:
            return .notAuthenticated
        case .invalidResponse:
            return .parsingError
        case .timedOut:
            return .apiError("Grok billing request timed out")
        case .launchFailed:
            return .apiError("Could not launch the Grok CLI")
        case .commandFailed:
            return .apiError("Grok billing request failed")
        }
    }
}

// MARK: - Billing response

nonisolated struct GrokBillingResult: Decodable, Sendable {
    let config: GrokBillingConfig
    let subscriptionTier: String?

    enum CodingKeys: String, CodingKey {
        case config
        case subscriptionTier = "subscription_tier"
    }
}

nonisolated struct GrokBillingConfig: Decodable, Sendable {
    struct Period: Decodable, Sendable {
        let type: String?
        let start: String?
        let end: String?

        var startDate: Date? { start.flatMap(FlexibleISO8601.date(from:)) }
        var endDate: Date? { end.flatMap(FlexibleISO8601.date(from:)) }
    }

    struct Amount: Decodable, Sendable {
        let val: Double
    }

    let creditUsagePercent: Double
    let currentPeriod: Period?
    let onDemandCap: Amount?
    let onDemandUsed: Amount?
    let prepaidBalance: Amount?
    let isUnifiedBillingUser: Bool?
    let billingPeriodStart: String?
    let billingPeriodEnd: String?

    var billingPeriodStartDate: Date? { billingPeriodStart.flatMap(FlexibleISO8601.date(from:)) }
    var billingPeriodEndDate: Date? { billingPeriodEnd.flatMap(FlexibleISO8601.date(from:)) }

    var extraUsageStatus: ExtraUsageStatus {
        guard onDemandCap != nil || onDemandUsed != nil || prepaidBalance != nil else {
            return .unknown
        }

        let cap = max(0, onDemandCap?.val ?? 0)
        let used = max(0, onDemandUsed?.val ?? 0)
        let balance = max(0, prepaidBalance?.val ?? 0)
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

    enum Error: Swift.Error {
        case notAuthenticated
        case invalidResponse
        case timedOut
        case launchFailed
        case commandFailed
    }

    private static let timeout: TimeInterval = 12
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

    static func fetch(binaryPath: String) async throws -> GrokBillingResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try fetchBlocking(binaryPath: binaryPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fetchBlocking(binaryPath: String) throws -> GrokBillingResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--no-auto-update", "agent", "--no-leader", "stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = CLIBinaryLocator.augmentedPATH(environment: environment)
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = "dumb"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                lines.finish()
                handle.readabilityHandler = nil
            } else {
                lines.append(data)
            }
        }
        // Drain stderr concurrently, but intentionally discard it: the CLI can
        // include account metadata in diagnostics and MeterBar must never log it.
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        do {
            try process.run()
        } catch {
            throw Error.launchFailed
        }

        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let requestSequence = requests(clientVersion: clientVersion)

        try send(requestSequence[0], to: input.fileHandleForWriting)
        _ = try response(id: 1, from: lines, deadline: deadline)

        try send(requestSequence[1], to: input.fileHandleForWriting)
        _ = try response(id: 2, from: lines, deadline: deadline, authenticationResponse: true)

        try send(requestSequence[2], to: input.fileHandleForWriting)
        let billingLine = try response(id: 3, from: lines, deadline: deadline)
        return try decodeBillingResult(from: billingLine)
    }

    private static func send(_ request: Request, to handle: FileHandle) throws {
        guard !request.data.isEmpty else { throw Error.invalidResponse }
        var line = request.data
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            throw Error.commandFailed
        }
    }

    private static func response(
        id: Int,
        from lines: LineBuffer,
        deadline: Date,
        authenticationResponse: Bool = false
    ) throws -> Data {
        while let line = lines.nextLine(until: deadline) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["id"] as? Int == id else {
                continue
            }
            if object["error"] != nil {
                throw authenticationResponse ? Error.notAuthenticated : Error.commandFailed
            }
            guard object["result"] != nil else { throw Error.invalidResponse }
            return line
        }
        throw Error.timedOut
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

    private final class LineBuffer: @unchecked Sendable {
        private let condition = NSCondition()
        private var pending = Data()
        private var lines: [Data] = []
        private var isFinished = false

        func append(_ data: Data) {
            condition.lock()
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
            condition.broadcast()
            condition.unlock()
        }

        func finish() {
            condition.lock()
            if !pending.isEmpty {
                lines.append(pending)
                pending.removeAll(keepingCapacity: false)
            }
            isFinished = true
            condition.broadcast()
            condition.unlock()
        }

        func nextLine(until deadline: Date) -> Data? {
            condition.lock()
            defer { condition.unlock() }
            while lines.isEmpty, !isFinished, Date() < deadline {
                _ = condition.wait(until: deadline)
            }
            guard !lines.isEmpty else { return nil }
            return lines.removeFirst()
        }
    }
}
