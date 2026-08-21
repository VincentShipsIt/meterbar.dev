import Foundation

/// Explicit per-provider feature flags consumed via `ServiceType`.
///
/// Provider additions used to rely on scattered hand-written lists. This
/// registry is the single place those lists must be declared; the factory
/// switch is exhaustive so a new `ServiceType` case is a compile error.
///
/// Values here are the current production truth, not the desired end-state
/// of sibling issues. Grok is multi-account, writes local logs, and has
/// account-scoped notifications (#464), guard config directories (#465),
/// and quota events (#469). Session Wake stays false — it needs a dedicated
/// runtime, not a flag flip.
public struct ProviderCapabilities: Equatable, Sendable {
    public let isMultiAccount: Bool
    public let supportsExtraUsage: Bool
    public let supportsResetRedemption: Bool
    public let supportsGuardConfigDirectory: Bool
    /// Session Wake is Claude + Codex only. Grok is multi-account and writes
    /// local logs, but wake is an explicit capability-gated exception — it
    /// needs a dedicated runtime, not a flag flip.
    public let supportsSessionWake: Bool
    public let hasAccountScopedNotifications: Bool
    public let hasAccountScopedQuotaEvents: Bool

    public init(
        isMultiAccount: Bool,
        supportsExtraUsage: Bool,
        supportsResetRedemption: Bool,
        supportsGuardConfigDirectory: Bool,
        supportsSessionWake: Bool,
        hasAccountScopedNotifications: Bool,
        hasAccountScopedQuotaEvents: Bool
    ) {
        self.isMultiAccount = isMultiAccount
        self.supportsExtraUsage = supportsExtraUsage
        self.supportsResetRedemption = supportsResetRedemption
        self.supportsGuardConfigDirectory = supportsGuardConfigDirectory
        self.supportsSessionWake = supportsSessionWake
        self.hasAccountScopedNotifications = hasAccountScopedNotifications
        self.hasAccountScopedQuotaEvents = hasAccountScopedQuotaEvents
    }

    public static func of(_ service: ServiceType) -> ProviderCapabilities {
        switch service {
        case .claudeCode:
            return ProviderCapabilities(
                isMultiAccount: true,
                supportsExtraUsage: true,
                supportsResetRedemption: false,
                supportsGuardConfigDirectory: true,
                supportsSessionWake: true,
                hasAccountScopedNotifications: true,
                hasAccountScopedQuotaEvents: true
            )
        case .codexCli:
            return ProviderCapabilities(
                isMultiAccount: true,
                supportsExtraUsage: false,
                supportsResetRedemption: true,
                supportsGuardConfigDirectory: true,
                supportsSessionWake: true,
                hasAccountScopedNotifications: true,
                hasAccountScopedQuotaEvents: true
            )
        case .grok:
            return ProviderCapabilities(
                isMultiAccount: true,
                supportsExtraUsage: true,
                supportsResetRedemption: true,
                supportsGuardConfigDirectory: true,
                supportsSessionWake: false,
                hasAccountScopedNotifications: true,
                hasAccountScopedQuotaEvents: true
            )
        case .cursor:
            return ProviderCapabilities(
                isMultiAccount: false,
                supportsExtraUsage: false,
                supportsResetRedemption: false,
                supportsGuardConfigDirectory: false,
                supportsSessionWake: false,
                hasAccountScopedNotifications: false,
                hasAccountScopedQuotaEvents: false
            )
        case .openRouter:
            // Multi-key: each managed API key is an account. Extra usage, reset
            // redemption, guard config directories, and Session Wake have no
            // OpenRouter analog.
            return ProviderCapabilities(
                isMultiAccount: true,
                supportsExtraUsage: false,
                supportsResetRedemption: false,
                supportsGuardConfigDirectory: false,
                supportsSessionWake: false,
                hasAccountScopedNotifications: true,
                hasAccountScopedQuotaEvents: true
            )
        }
    }
}

extension ServiceType {
    public var capabilities: ProviderCapabilities { .of(self) }

    public var isMultiAccount: Bool { capabilities.isMultiAccount }
    public var supportsExtraUsage: Bool { capabilities.supportsExtraUsage }
    public var supportsResetRedemption: Bool { capabilities.supportsResetRedemption }
    public var supportsGuardConfigDirectory: Bool { capabilities.supportsGuardConfigDirectory }
    public var supportsSessionWake: Bool { capabilities.supportsSessionWake }
    public var hasAccountScopedNotifications: Bool { capabilities.hasAccountScopedNotifications }
    public var hasAccountScopedQuotaEvents: Bool { capabilities.hasAccountScopedQuotaEvents }

    /// Share-card / history provenance. Same split as `writesLocalTokenLogs` —
    /// do not fork a second list.
    public var hasLocalHistorySource: Bool { writesLocalTokenLogs }
}
