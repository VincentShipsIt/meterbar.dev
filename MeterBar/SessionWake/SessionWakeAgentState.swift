import Darwin
import Foundation
import MeterBarShared

/// Durable configuration handed from the GUI to the managed Session Wake
/// launch agent. The agent reads a fresh snapshot before every scan, so changing
/// the kill switch, account, permission posture, or bounds never relies on an
/// already-running app process.
nonisolated struct SessionWakeAgentConfiguration: Codable, Equatable, Sendable {
    let featureEnabled: Bool
    let isArmed: Bool
    let provider: WakeProvider
    let accountDirectory: String?
    let permissionMode: WakePermissionMode
    let bypassAcknowledged: Bool
    let prompt: String
    let notifyOnCompletion: Bool
    let maxSessionsPerRun: Int
    let maxTurns: Int

    var canRun: Bool {
        featureEnabled
            && isArmed
            && (permissionMode == .safe || bypassAcknowledged)
    }

    var bounds: WakeBounds {
        WakeBounds(
            pollInterval: WakeBounds.default.pollInterval,
            bufferAfterReset: WakeBounds.default.bufferAfterReset,
            gapBetweenSessions: WakeBounds.default.gapBetweenSessions,
            perSessionTimeout: WakeBounds.default.perSessionTimeout,
            maxTurns: maxTurns,
            maxSessionsPerRun: maxSessionsPerRun,
            maxUnknownPolls: WakeBounds.default.maxUnknownPolls
        )
    }

    func withControlFlags(featureEnabled: Bool, isArmed: Bool) -> Self {
        Self(
            featureEnabled: featureEnabled,
            isArmed: isArmed,
            provider: provider,
            accountDirectory: accountDirectory,
            permissionMode: permissionMode,
            bypassAcknowledged: bypassAcknowledged,
            prompt: prompt,
            notifyOnCompletion: notifyOnCompletion,
            maxSessionsPerRun: maxSessionsPerRun,
            maxTurns: maxTurns
        )
    }

    func requiresRuntimeRestart(comparedTo other: Self) -> Bool {
        provider != other.provider
            || accountDirectory != other.accountDirectory
            || permissionMode != other.permissionMode
            || bypassAcknowledged != other.bypassAcknowledged
            || prompt != other.prompt
            || maxSessionsPerRun != other.maxSessionsPerRun
            || maxTurns != other.maxTurns
    }
}

/// Codable representation of the associated-value watcher state. It is kept
/// intentionally metadata-only: no prompt, transcript, command output, or
/// credential material crosses the process boundary.
nonisolated struct SessionWakeAgentStatusRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case off
        case idle
        case scanning
        case waiting
        case quotaUnknown
        case running
        case stopping
        case completed
        case failed
    }

    let phase: Phase
    let processID: Int32
    let heartbeat: Date
    let resetTime: Date?
    let sessionID: String?
    let reason: String?
    let summary: WakeRunSummaryRecord?

    init(
        state: WakeWatcherState,
        processID: Int32 = getpid(),
        heartbeat: Date = Date()
    ) {
        self.processID = processID
        self.heartbeat = heartbeat
        resetTime = state.resetTime
        sessionID = state.sessionID
        reason = state.failureReason
        summary = state.summary.map(WakeRunSummaryRecord.init)
        phase = state.agentPhase
    }

    func refreshingHeartbeat(at date: Date = Date()) -> Self {
        Self(
            phase: phase,
            processID: processID,
            heartbeat: date,
            resetTime: resetTime,
            sessionID: sessionID,
            reason: reason,
            summary: summary
        )
    }

    var watcherState: WakeWatcherState {
        switch phase {
        case .off: return .off
        case .idle: return .idle
        case .scanning: return .scanning
        case .waiting: return .waiting(until: resetTime)
        case .quotaUnknown: return .quotaUnknown(reason: reason ?? "Fresh quota unavailable")
        case .running: return .running(sessionID: sessionID ?? "unknown")
        case .stopping: return .stopping
        case .completed: return .completed(summary: summary?.wakeSummary ?? WakeRunSummary())
        case .failed: return .failed(reason: reason ?? "Background watcher failed")
        }
    }

    private init(
        phase: Phase,
        processID: Int32,
        heartbeat: Date,
        resetTime: Date?,
        sessionID: String?,
        reason: String?,
        summary: WakeRunSummaryRecord?
    ) {
        self.phase = phase
        self.processID = processID
        self.heartbeat = heartbeat
        self.resetTime = resetTime
        self.sessionID = sessionID
        self.reason = reason
        self.summary = summary
    }
}

nonisolated struct WakeRunSummaryRecord: Codable, Equatable, Sendable {
    let resumed: Int
    let failed: Int
    let skipped: Int
    let remaining: Int

    init(_ summary: WakeRunSummary) {
        resumed = summary.resumed
        failed = summary.failed
        skipped = summary.skipped
        remaining = summary.remaining
    }

    var wakeSummary: WakeRunSummary {
        WakeRunSummary(resumed: resumed, failed: failed, skipped: skipped, remaining: remaining)
    }
}

/// App-group-backed process boundary for agent configuration and live status.
/// UserDefaults is thread-safe; instances are immutable wrappers around one
/// suite and therefore safe to use from the agent's background tasks.
nonisolated final class SessionWakeAgentStateStore: @unchecked Sendable {
    static let configurationKey = "SessionWakeAgentConfigurationV1"
    static let statusKey = "SessionWakeAgentStatusV1"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults? = nil) {
        self.userDefaults = userDefaults
            ?? UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier)
            ?? .standard
    }

    func saveConfiguration(_ configuration: SessionWakeAgentConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        userDefaults.set(data, forKey: Self.configurationKey)
    }

    func loadConfiguration() -> SessionWakeAgentConfiguration? {
        guard let data = userDefaults.data(forKey: Self.configurationKey) else { return nil }
        return try? JSONDecoder().decode(SessionWakeAgentConfiguration.self, from: data)
    }

    func saveStatus(_ status: SessionWakeAgentStatusRecord) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        userDefaults.set(data, forKey: Self.statusKey)
    }

    func loadStatus() -> SessionWakeAgentStatusRecord? {
        guard let data = userDefaults.data(forKey: Self.statusKey) else { return nil }
        return try? JSONDecoder().decode(SessionWakeAgentStatusRecord.self, from: data)
    }

    func refreshHeartbeat(at date: Date = Date()) {
        guard let status = loadStatus() else { return }
        saveStatus(status.refreshingHeartbeat(at: date))
    }
}

nonisolated private extension WakeWatcherState {
    var agentPhase: SessionWakeAgentStatusRecord.Phase {
        switch self {
        case .off: return .off
        case .idle: return .idle
        case .scanning: return .scanning
        case .waiting: return .waiting
        case .quotaUnknown: return .quotaUnknown
        case .running: return .running
        case .stopping: return .stopping
        case .completed: return .completed
        case .failed: return .failed
        }
    }

    var resetTime: Date? {
        guard case let .waiting(until) = self else { return nil }
        return until
    }

    var sessionID: String? {
        guard case let .running(sessionID) = self else { return nil }
        return sessionID
    }

    var failureReason: String? {
        switch self {
        case let .quotaUnknown(reason), let .failed(reason): return reason
        default: return nil
        }
    }

    var summary: WakeRunSummary? {
        guard case let .completed(summary) = self else { return nil }
        return summary
    }
}
