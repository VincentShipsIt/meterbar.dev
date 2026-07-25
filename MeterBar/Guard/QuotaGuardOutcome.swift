import Foundation

/// Stable outcomes and exit codes for `meterbar guard`.
///
/// Scripts branch on these numbers, so they are a published contract
/// (`docs/cli-json-schema.md`): the values never change meaning within schema
/// version 1. "Below threshold" stays distinct from "exhausted" so a caller can
/// throttle before it is actually blocked.
nonisolated public enum QuotaGuardOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case belowThreshold
    case exhausted
    case dataUnavailable
    case usageError

    public var exitCode: Int32 {
        switch self {
        case .available: return 0
        case .belowThreshold: return 10
        case .exhausted: return 11
        case .dataUnavailable: return 12
        case .usageError: return 13
        }
    }
}

/// A non-success reason with a stable machine code.
///
/// The outcome travels with the failure so callers can distinguish "you passed
/// something invalid" (usage error) from "MeterBar has nothing trustworthy to
/// answer with" (data unavailable) without a second lookup table.
nonisolated struct QuotaGuardFailure: Error, Equatable, Sendable {
    let outcome: QuotaGuardOutcome
    let code: String
    let message: String
    let flag: String?
    let value: String?

    init(
        outcome: QuotaGuardOutcome,
        code: String,
        message: String,
        flag: String? = nil,
        value: String? = nil
    ) {
        self.outcome = outcome
        self.code = code
        self.message = message
        self.flag = flag
        self.value = value
    }
}
