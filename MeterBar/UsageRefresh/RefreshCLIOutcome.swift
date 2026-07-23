import Foundation

/// Stable outcomes and exit codes for `meterbar refresh`.
nonisolated public enum RefreshCLIOutcome: String, Codable, Equatable, Sendable {
    case success
    case partialFailure
    case refreshFailed
    case alreadyRunning
    case timedOut
    case cancellation

    public var exitCode: Int32 {
        switch self {
        case .success: return 0
        case .alreadyRunning: return 10
        case .timedOut: return 11
        case .partialFailure: return 12
        case .refreshFailed: return 13
        case .cancellation: return 130
        }
    }
}
