import Foundation

public enum QuotaWindowID: Hashable, Sendable {
    case session
    case weekly
    case codeReview
    case additional(UInt)
}

public enum QuotaUnavailable: Sendable, Equatable {
    case parseDrift
    case unauthenticated
    case rateLimited
    case unsupported
    case stale
}

/// Only validated windows can enter an available reading. Credit balances keep
/// their existing Reading semantics; they do not acquire a percentage meter.
public struct QuotaWindow: Sendable, Equatable {
    public let account: ProviderAccount
    public let id: QuotaWindowID
    public let limit: UsageLimit

    public init?(account: ProviderAccount, id: QuotaWindowID, limit: UsageLimit) {
        guard Self.isValid(limit) else { return nil }
        self.account = account
        self.id = id
        self.limit = limit
    }

    public static func isValid(_ limit: UsageLimit) -> Bool {
        guard limit.used.isFinite, limit.used >= 0,
              limit.total.isFinite, limit.total >= 0 else { return false }
        switch limit.reading {
        case .measured, .allowance:
            guard limit.total > 0 else { return false }
        case .remainder, .unlimited:
            break
        }
        if let reset = limit.resetTime, !reset.timeIntervalSinceReferenceDate.isFinite { return false }
        if let seconds = limit.windowSeconds, !seconds.isFinite || seconds <= 0 { return false }
        return true
    }
}

/// Unavailable readings contain no numeric placeholder that could become a gauge.
public enum QuotaReading: Sendable, Equatable {
    case measured(QuotaWindow)
    case estimated(QuotaWindow)
    case unavailable(QuotaUnavailable)

    public init(limit: UsageLimit?, account: ProviderAccount, id: QuotaWindowID) {
        guard let limit else {
            self = .unavailable(.unsupported)
            return
        }
        guard let window = QuotaWindow(account: account, id: id, limit: limit) else {
            self = .unavailable(.parseDrift)
            return
        }
        self = limit.isEstimated ? .estimated(window) : .measured(window)
    }

    public var window: QuotaWindow? {
        switch self {
        case let .measured(window), let .estimated(window): return window
        case .unavailable: return nil
        }
    }

    static func validated(_ limit: UsageLimit?) -> UsageLimit? {
        limit.flatMap { QuotaWindow.isValid($0) ? $0 : nil }
    }
}
