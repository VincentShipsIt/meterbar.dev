import Foundation

nonisolated enum ClaudeTokenRefreshTrigger: Equatable, Sendable {
    case background
    case userInitiated
}

nonisolated enum ClaudeTokenRefreshOutcome: String, CaseIterable, Codable, Equatable, Sendable {
    case refreshed
    case inconclusive
    case hardFailure
}

nonisolated struct ClaudeRefreshCooldownRecord: Codable, Equatable, Sendable {
    let outcome: ClaudeTokenRefreshOutcome
    let completedAt: Date
}

nonisolated enum ClaudeRefreshDecision: Equatable, Sendable {
    case attempt
    case cooldown(until: Date)
}

/// Pure cooldown policy for delegated refresh attempts.
nonisolated enum ClaudeRefreshPolicy {
    static let inconclusiveCooldown: TimeInterval = 20
    static let settledCooldown: TimeInterval = 5 * 60

    static func decision(
        record: ClaudeRefreshCooldownRecord?,
        trigger: ClaudeTokenRefreshTrigger,
        now: Date
    ) -> ClaudeRefreshDecision {
        if trigger == .userInitiated {
            return .attempt
        }
        guard let record else { return .attempt }

        // A clock correction or corrupt future timestamp must not disable
        // automatic recovery until that future instant finally arrives.
        guard record.completedAt <= now else { return .attempt }

        let deadline = record.completedAt.addingTimeInterval(cooldownDuration(for: record.outcome))
        return now < deadline ? .cooldown(until: deadline) : .attempt
    }

    static func cooldownDuration(for outcome: ClaudeTokenRefreshOutcome) -> TimeInterval {
        outcome == .inconclusive ? inconclusiveCooldown : settledCooldown
    }
}

/// Persisted per-account cooldown records. The payload contains only account
/// UUIDs, outcome labels, and timestamps.
nonisolated final class ClaudeRefreshCooldownStore: @unchecked Sendable {
    private struct Entry: Codable {
        let accountID: UUID
        let record: ClaudeRefreshCooldownRecord
    }

    private let userDefaults: UserDefaults
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func record(for accountID: UUID) -> ClaudeRefreshCooldownRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records()[accountID]
    }

    func record(_ outcome: ClaudeTokenRefreshOutcome, for accountID: UUID, at date: Date) {
        lock.lock()
        defer { lock.unlock() }

        var updated = records()
        updated[accountID] = ClaudeRefreshCooldownRecord(outcome: outcome, completedAt: date)
        let entries = updated
            .map { Entry(accountID: $0.key, record: $0.value) }
            .sorted { $0.accountID.uuidString < $1.accountID.uuidString }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        userDefaults.set(data, forKey: StorageKeys.claudeCodeRefreshCooldowns)
    }

    private func records() -> [UUID: ClaudeRefreshCooldownRecord] {
        guard let data = userDefaults.data(forKey: StorageKeys.claudeCodeRefreshCooldowns),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.accountID, $0.record) })
    }
}

nonisolated enum ClaudeStatusRunResult: Equatable, Sendable {
    case succeeded
    case failed
}

nonisolated enum ClaudeTokenRefreshResult: Equatable, Sendable {
    case refreshed
    case inconclusive
    case hardFailure
    case cooldown(until: Date, previousOutcome: ClaudeTokenRefreshOutcome)

    var didRefresh: Bool {
        self == .refreshed
    }
}

nonisolated enum ClaudeOAuthCredentialAccess: Equatable, Sendable {
    case missing
    case expired
    case valid(token: String)
}

nonisolated enum ClaudeOAuthAccessResolution: Equatable, Sendable {
    case token(String)
    case missing
    case refreshFailed(ClaudeTokenRefreshResult)
}

/// Pure orchestration around the refresher: valid credentials pass through,
/// missing credentials retain the existing CLI fallback, and expired
/// credentials get exactly one verified delegated-refresh attempt plus one
/// credential re-read.
nonisolated enum ClaudeOAuthAccessCoordinator {
    typealias Refresh = @Sendable (
        ClaudeCodeAccount,
        ClaudeTokenRefreshTrigger
    ) async -> ClaudeTokenRefreshResult
    typealias Reread = @Sendable () async -> ClaudeOAuthCredentialAccess

    static func resolve(
        initialAccess: ClaudeOAuthCredentialAccess,
        account: ClaudeCodeAccount,
        trigger: ClaudeTokenRefreshTrigger,
        refresh: Refresh,
        reread: Reread
    ) async -> ClaudeOAuthAccessResolution {
        switch initialAccess {
        case let .valid(token):
            return .token(token)
        case .missing:
            return .missing
        case .expired:
            let result = await refresh(account, trigger)
            guard result.didRefresh else {
                return .refreshFailed(result)
            }
            guard case let .valid(token) = await reread() else {
                return .refreshFailed(result)
            }
            return .token(token)
        }
    }
}

/// Performs the privacy-sensitive process launch. Captures are bounded to zero
/// bytes because delegated refresh needs only the termination result.
nonisolated enum ClaudeStatusRunner {
    private static let processQueue = DispatchQueue(
        label: "dev.meterbar.app.ClaudeStatus.process",
        qos: .utility,
        attributes: .concurrent
    )

    static func run(account: ClaudeCodeAccount) async -> ClaudeStatusRunResult {
        await withCheckedContinuation { continuation in
            processQueue.async {
                guard let binaryPath = ClaudeCodeCLIUsageService.shared.resolveClaudeBinaryPath() else {
                    continuation.resume(returning: .failed)
                    return
                }

                continuation.resume(returning: runBlocking(
                    binaryPath: binaryPath,
                    account: account
                ))
            }
        }
    }

    static func runBlocking(
        binaryPath: String,
        account: ClaudeCodeAccount,
        timeout: TimeInterval = ClaudeCodeCLIUsageService.commandTimeout
    ) -> ClaudeStatusRunResult {
        let result = ManagedProcess.run(
            executable: binaryPath,
            arguments: ["/status"],
            environment: ClaudeCodeCLIUsageService.shared.processEnvironment(account: account),
            workingDirectory: ServiceSupport.realHomeDirectory(),
            timeout: timeout,
            maxCaptureBytes: 0
        )
        return result.isSuccess ? .succeeded : .failed
    }
}

/// Coalesces delegated refreshes by account and verifies success by observing a
/// changed credential fingerprint after Claude exits successfully.
actor ClaudeTokenRefresher {
    typealias FingerprintReader = @Sendable (ClaudeCodeAccount) -> ClaudeCredentialFingerprint?
    typealias StatusRunner = @Sendable (ClaudeCodeAccount) async -> ClaudeStatusRunResult
    typealias Sleeper = @Sendable (TimeInterval) async -> Void
    typealias Clock = @Sendable () -> Date

    static let shared = ClaudeTokenRefresher()

    private let cooldownStore: ClaudeRefreshCooldownStore
    private let fingerprint: FingerprintReader
    private let runStatus: StatusRunner
    private let sleep: Sleeper
    private let pollDelays: [TimeInterval]
    private let now: Clock
    private var inFlight: [UUID: Task<ClaudeTokenRefreshOutcome, Never>] = [:]

    init(
        cooldownStore: ClaudeRefreshCooldownStore = ClaudeRefreshCooldownStore(),
        fingerprint: @escaping FingerprintReader = {
            ClaudeCredentialFingerprintStore.shared.fingerprint(for: $0)
        },
        runStatus: @escaping StatusRunner = { await ClaudeStatusRunner.run(account: $0) },
        sleep: @escaping Sleeper = { delay in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        pollDelays: [TimeInterval] = [0.2, 0.5, 0.8],
        now: @escaping Clock = { Date() }
    ) {
        self.cooldownStore = cooldownStore
        self.fingerprint = fingerprint
        self.runStatus = runStatus
        self.sleep = sleep
        self.pollDelays = pollDelays
        self.now = now
    }

    func refresh(
        account: ClaudeCodeAccount,
        trigger: ClaudeTokenRefreshTrigger
    ) async -> ClaudeTokenRefreshResult {
        // In-flight work wins over cooldown/preemption. A user action bypasses a
        // stored cooldown, but it must not create a second process beside an
        // already-running background attempt.
        if let active = inFlight[account.id] {
            return result(for: await active.value)
        }

        let currentDate = now()
        let record = cooldownStore.record(for: account.id)
        switch ClaudeRefreshPolicy.decision(record: record, trigger: trigger, now: currentDate) {
        case .attempt:
            break
        case let .cooldown(until):
            guard let record else { return .inconclusive }
            return .cooldown(until: until, previousOutcome: record.outcome)
        }

        let fingerprint = self.fingerprint
        let runStatus = self.runStatus
        let sleep = self.sleep
        let pollDelays = self.pollDelays
        let task = Task.detached(priority: .utility) {
            await Self.performRefresh(
                account: account,
                fingerprint: fingerprint,
                runStatus: runStatus,
                sleep: sleep,
                pollDelays: pollDelays
            )
        }
        inFlight[account.id] = task

        let outcome = await task.value
        inFlight[account.id] = nil
        cooldownStore.record(outcome, for: account.id, at: now())
        return result(for: outcome)
    }

    private static func performRefresh(
        account: ClaudeCodeAccount,
        fingerprint: FingerprintReader,
        runStatus: StatusRunner,
        sleep: Sleeper,
        pollDelays: [TimeInterval]
    ) async -> ClaudeTokenRefreshOutcome {
        let before = fingerprint(account)
        guard await runStatus(account) == .succeeded else {
            return .hardFailure
        }

        for delay in pollDelays {
            await sleep(delay)
            if let after = fingerprint(account), after != before {
                return .refreshed
            }
        }
        return .inconclusive
    }

    private func result(for outcome: ClaudeTokenRefreshOutcome) -> ClaudeTokenRefreshResult {
        switch outcome {
        case .refreshed:
            .refreshed
        case .inconclusive:
            .inconclusive
        case .hardFailure:
            .hardFailure
        }
    }
}
