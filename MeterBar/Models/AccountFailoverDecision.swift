import Foundation
import MeterBarShared

nonisolated enum AccountFailoverProvider: String, CaseIterable, Codable, Sendable {
    case claudeCode
    case codexCli

    var service: ServiceType {
        switch self {
        case .claudeCode: return .claudeCode
        case .codexCli: return .codexCli
        }
    }

    init?(service: ServiceType) {
        switch service {
        case .claudeCode: self = .claudeCode
        case .codexCli: self = .codexCli
        case .cursor, .openRouter, .grok: return nil
        }
    }
}
nonisolated enum AccountFailoverAvailability: Equatable, Sendable {
    case available
    case depleted
    case unknown

    init(metrics: UsageMetrics?) {
        guard let primaryLimit = metrics?.sessionLimit else {
            self = .unknown
            return
        }
        self = primaryLimit.isAtLimit ? .depleted : .available
    }
}

nonisolated struct AccountFailoverDecisionInput: Equatable, Sendable {
    let isEnabled: Bool
    let orderedAccountIDs: [UUID]
    let activeAccountID: UUID?
    let availability: [UUID: AccountFailoverAvailability]
}

nonisolated enum AccountFailoverStayReason: Equatable, Sendable {
    case featureDisabled
    case noAccounts
    case activeAccountAvailable
    case activeAccountUnknown
    case allAccountsDepleted
}

nonisolated enum AccountFailoverSwitchReason: Equatable, Sendable {
    case activeAccountDepleted
    case preferredAccountRecovered
}

nonisolated enum AccountFailoverAdoptionReason: Equatable, Sendable {
    case activeAccountUnavailable
}

nonisolated enum AccountFailoverDecision: Equatable, Sendable {
    case stay(AccountFailoverStayReason)
    case adopt(UUID, reason: AccountFailoverAdoptionReason)
    case switchAccount(from: UUID, to: UUID, reason: AccountFailoverSwitchReason)
}

/// Pure fallback-chain policy. The chain is the enabled account-store order;
/// account zero is always preferred and every target must have a fresh,
/// readable primary quota window that is not exhausted.
nonisolated enum AccountFailoverDecisionEngine {
    static func decide(_ input: AccountFailoverDecisionInput) -> AccountFailoverDecision {
        guard input.isEnabled else { return .stay(.featureDisabled) }
        guard let preferred = input.orderedAccountIDs.first else { return .stay(.noAccounts) }
        guard let active = input.activeAccountID,
              input.orderedAccountIDs.contains(active) else {
            return .adopt(preferred, reason: .activeAccountUnavailable)
        }

        if active != preferred, input.availability[preferred] == .available {
            return .switchAccount(from: active, to: preferred, reason: .preferredAccountRecovered)
        }

        switch input.availability[active] ?? .unknown {
        case .available:
            return .stay(.activeAccountAvailable)
        case .unknown:
            return .stay(.activeAccountUnknown)
        case .depleted:
            guard let target = input.orderedAccountIDs.first(where: {
                $0 != active && input.availability[$0] == .available
            }) else {
                return .stay(.allAccountsDepleted)
            }
            return .switchAccount(from: active, to: target, reason: .activeAccountDepleted)
        }
    }
}
