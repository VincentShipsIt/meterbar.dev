import Foundation

/// The subscription providers MeterBar tracks. The admin-API providers
/// (`Claude`/`OpenAI` raw values) were removed with the admin-key feature;
/// tolerant cache decoding skips their entries in older on-disk payloads.
public enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "Claude Code"
    case codexCli = "Codex CLI"
    case xai = "xAI"
    case openRouter = "OpenRouter"
    case kimiCode = "Kimi Code"
    case zaiCodingPlan = "Z.ai Coding Plan"
    case githubCopilot = "GitHub Copilot"
    case museCode = "Muse Code"
    case claudePlatform = "Claude Platform"

    public var id: String { rawValue }

    /// Raw values older builds persisted for the providers xAI absorbed. Caches,
    /// visibility, widget configuration, routing policy and iCloud payloads
    /// written before the merge still carry them, so every decode funnels
    /// through here instead of dropping the entry.
    public static let legacyXAIRawValues: Set<String> = ["Grok", "Cursor"]

    /// Maps the pre-merge `Grok` / `Cursor` raw values to `.xai`; every other
    /// raw value resolves exactly as the synthesized initializer would.
    public init?(rawValue: String) {
        if Self.legacyXAIRawValues.contains(rawValue) {
            self = .xai
            return
        }
        switch rawValue {
        case "Claude Code": self = .claudeCode
        case "Codex CLI": self = .codexCli
        case "xAI": self = .xai
        case "OpenRouter": self = .openRouter
        case "Kimi Code": self = .kimiCode
        case "Z.ai Coding Plan": self = .zaiCodingPlan
        case "GitHub Copilot": self = .githubCopilot
        case "Muse Code": self = .museCode
        case "Claude Platform": self = .claudePlatform
        default: return nil
        }
    }

    /// The full product name. Use it wherever a provider is being *named*:
    /// settings section headers, sidebar rows, notification titles, CLI JSON,
    /// share cards.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli: return "OpenAI Codex"
        case .xai: return "xAI"
        case .openRouter: return "OpenRouter"
        case .kimiCode: return "Kimi Code"
        case .zaiCodingPlan: return "Z.ai GLM Coding Plan"
        case .githubCopilot: return "GitHub Copilot"
        case .museCode: return "Muse Code"
        case .claudePlatform: return "Claude Platform"
        }
    }

    /// The compact brand form, for places where the full product name would
    /// crowd the layout: chart legends, popover provider cards, "Add account"
    /// sheet copy.
    ///
    /// Centralized here for the same reason as `codeReviewQuotaTitle`: the
    /// dashboard chart, the popover snapshot builder, and the settings sheets
    /// each used to switch over these five cases inline, so renaming a provider
    /// meant finding every copy. Note this is *not* the status-page operator
    /// name — Codex's status page belongs to "OpenAI", which is why
    /// `statusPageDisplayName` stays separate.
    public var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codexCli: return "Codex"
        case .xai: return "xAI"
        case .openRouter: return "OpenRouter"
        case .kimiCode: return "Kimi"
        case .zaiCodingPlan: return "Z.ai"
        case .githubCopilot: return "Copilot"
        case .museCode: return "Muse"
        case .claudePlatform: return "Console"
        }
    }

    /// SF Symbol name used by the app UI.
    public var iconName: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codexCli: return "terminal.fill"
        case .xai: return "bolt.fill"
        case .openRouter: return "point.3.connected.trianglepath.dotted"
        case .kimiCode: return "moon.stars.fill"
        case .zaiCodingPlan: return "z.circle.fill"
        case .githubCopilot: return "sparkles"
        case .museCode: return "circle.grid.cross.fill"
        case .claudePlatform: return "creditcard.fill"
        }
    }

    /// Asset-catalog image name used by the widget extension, which ships
    /// provider logos instead of SF Symbols.
    public var assetName: String {
        switch self {
        case .claudeCode: return "ClaudeIcon"
        case .codexCli: return "CodexIcon"
        case .xai: return "XAIIcon"
        case .openRouter: return "OpenRouterIcon"
        case .kimiCode: return "KimiCodeIcon"
        case .zaiCodingPlan: return "ZaiCodingPlanIcon"
        case .githubCopilot: return "GitHubCopilotIcon"
        case .museCode: return "MuseCodeIcon"
        case .claudePlatform: return "ClaudePlatformIcon"
        }
    }

    /// Stable display ordering (most-used services first).
    public var sortOrder: Int {
        switch self {
        case .claudeCode: return 0
        case .codexCli: return 1
        case .xai: return 2
        case .openRouter: return 3
        case .kimiCode: return 5
        case .zaiCodingPlan: return 6
        case .githubCopilot: return 7
        case .museCode: return 8
        case .claudePlatform: return 9
        }
    }

    /// Whether MeterBar can poll a verified first-party status page for this
    /// provider. Kimi Code's plan has no status page of its own that MeterBar
    /// has verified, so it is left out of the status surfaces rather than
    /// pointed at a neighbouring product's page.
    public var hasStatusPage: Bool {
        switch self {
        case .claudeCode, .codexCli, .xai, .openRouter, .githubCopilot: return true
        case .kimiCode, .zaiCodingPlan, .museCode, .claudePlatform: return false
        }
    }

    /// Whether cached quota supports workload recommendations.
    public var supportsWorkloadRouting: Bool {
        switch self {
        case .claudeCode,
             .codexCli,
             .xai,
             .openRouter: true
        case .kimiCode,
             .zaiCodingPlan,
             .githubCopilot,
             .museCode,
             .claudePlatform: false
        }
    }

    /// The providers that have a status page to poll and show.
    public static var statusPageServices: [ServiceType] {
        allCases.filter(\.hasStatusPage)
    }

    /// Whether the provider is off until the user turns it on.
    ///
    /// OpenRouter needs an API key, so it has always been opt-in. Newer
    /// providers follow it: a card that can only say "not connected" is noise
    /// for everyone who does not use the service, so the Providers settings
    /// page is where they are switched on.
    public var isOptInByDefault: Bool {
        switch self {
        case .openRouter, .kimiCode, .zaiCodingPlan, .githubCopilot, .museCode, .claudePlatform: return true
        case .claudeCode, .codexCli, .xai: return false
        }
    }

    /// Whether the provider's CLI writes per-session logs on disk that MeterBar
    /// can scan into a dated token series.
    ///
    /// The dividing line behind every "where does this provider's history come
    /// from" decision. Claude, Codex and Grok write session logs, so their
    /// history is re-readable and a scan can rebuild it. Cursor and OpenRouter
    /// publish a single running counter and nothing else, so their only dated
    /// series is the one `ProviderUsageLedger` accumulates from MeterBar's own
    /// polls — which also means it cannot be backfilled.
    ///
    /// Centralized here for the same reason as `weeklyQuotaTitle`: the cost
    /// scanners, the usage manager and the popover each encode this split, and
    /// a chart that picks the wrong source draws an empty week rather than an
    /// error.
    public var writesLocalTokenLogs: Bool {
        switch self {
        case .claudeCode, .codexCli, .xai: return true
        case .openRouter, .kimiCode, .zaiCodingPlan, .githubCopilot, .museCode, .claudePlatform:
            return false
        }
    }

    /// Which quota-window title a `(service, window, limit)` triple resolves to,
    /// separated from the English words it resolves *into*.
    ///
    /// The routing below is the single decision — the OpenRouter exceptions, the
    /// Cursor included-pool split, Claude Code's model-scoped third window. The
    /// widget extension has to say the same thing in the user's language, and
    /// re-deriving "which title applies" from `(service, quotaWindow)` on its own
    /// side is how the two answers drift apart. It switches over this key
    /// instead, so a routing change lands in one place and the localized title
    /// follows.
    public enum QuotaTitleKey: Equatable, Sendable {
        case keyLimit
        case session
        case cursorModels
        case accountCredits
        case otherModels
        case monthly
        case weekly
        case daily
        case billingCycle
        /// Neutral title when the provider reported a window MeterBar cannot
        /// name honestly. Never a guessed cadence such as "Weekly".
        case quota
        case codeReview
        case onDemand
        /// Claude Code's model-scoped window. The parsed label is provider data
        /// and stays verbatim in every locale; `nil` falls back to translated
        /// "Model" copy.
        case model(label: String?)

        /// The English source copy. The bundled CLI and every non-UI caller read
        /// their titles from here, so this stays the definition of the words.
        public var englishTitle: String {
            switch self {
            case .keyLimit: return "Key limit"
            case .session: return "Session"
            case .cursorModels: return "Cursor Models"
            case .accountCredits: return "Account credits"
            case .otherModels: return "Other Models"
            case .monthly: return "Monthly"
            case .weekly: return "Weekly"
            case .daily: return "Daily"
            case .billingCycle: return "Billing cycle"
            case .quota: return "Quota"
            case .codeReview: return "Code Review"
            case .onDemand: return "On-demand"
            case let .model(label): return label ?? "Model"
            }
        }
    }

    /// Display title for the third ("code review") quota window. For Claude
    /// Code this window is model-scoped: it echoes the parsed model label
    /// (e.g. "Fable", "Sonnet"), falling back to a neutral "Model" when no
    /// label is available — never a hardcoded model name, since the label
    /// changes across CLI releases. Cursor's third window is on-demand spend.
    /// Every other provider shows "Code Review".
    /// Centralized here because the popover, dashboard, widget, and
    /// notification copy previously each spelled out this rule — and
    /// historically did so with inverted defaults.
    public func codeReviewQuotaTitle(modelLimitLabel: String?) -> String {
        codeReviewQuotaTitleKey(modelLimitLabel: modelLimitLabel).englishTitle
    }

    public func codeReviewQuotaTitleKey(modelLimitLabel: String?) -> QuotaTitleKey {
        switch self {
        case .claudeCode: return .model(label: modelLimitLabel)
        case .xai: return .onDemand
        case .codexCli, .openRouter, .kimiCode, .zaiCodingPlan, .githubCopilot, .museCode, .claudePlatform:
            return .codeReview
        }
    }

    /// xAI's included pools arrive as a percentage of 100 (Grok's billing
    /// periods and Cursor's dashboard both report `used` as a percent). Limits
    /// mapped from those fields use this denominator so the popover, widget and
    /// notifications can tell a percent pool from Cursor's legacy request quota.
    public static let xaiPercentPoolTotal: Double = 100

    public static func isXAIPercentPool(total: Double) -> Bool {
        abs(total - xaiPercentPoolTotal) < 0.000_001
    }

    /// Labels legacy Cursor accounts keep for their monthly included pools.
    /// They ride in `additionalLimits` as provider data, and the title routing
    /// below maps the exact strings back to the localized titles.
    public static let legacyCursorModelsLabel = "Cursor Models"
    public static let legacyOtherModelsLabel = "Other Models"

    /// Display title for the short ("session") quota window. OpenRouter's is a
    /// key spend cap; every other provider's is "Session" unless the reported
    /// cadence says otherwise.
    public func sessionQuotaTitle(
        limitTotal: Double?,
        periodKind: UsageLimit.PeriodKind? = nil
    ) -> String {
        sessionQuotaTitleKey(limitTotal: limitTotal, periodKind: periodKind).englishTitle
    }

    public func sessionQuotaTitleKey(
        limitTotal: Double?,
        periodKind: UsageLimit.PeriodKind? = nil
    ) -> QuotaTitleKey {
        // OpenRouter's key spend cap is never a reported cadence, so the
        // `periodKind` override below must not eclipse it.
        if self == .openRouter {
            return .keyLimit
        }
        if let periodKind, let titled = quotaTitleKey(overridingWith: periodKind) {
            return titled
        }
        return .session
    }

    /// Display title for the long ("weekly") quota window. The shared window id
    /// stays `weekly` across providers, but its real cadence does not: a
    /// provider can report a monthly window there, and OpenRouter's is a credit
    /// balance rather than a window at all. Centralized here for the same
    /// reason as `codeReviewQuotaTitle` — the popover, widget, and CLI each
    /// used to spell out the OpenRouter exception inline.
    public func weeklyQuotaTitle(
        limitTotal: Double?,
        periodKind: UsageLimit.PeriodKind? = nil
    ) -> String {
        weeklyQuotaTitleKey(limitTotal: limitTotal, periodKind: periodKind).englishTitle
    }

    public func weeklyQuotaTitleKey(
        limitTotal: Double?,
        periodKind: UsageLimit.PeriodKind? = nil
    ) -> QuotaTitleKey {
        // OpenRouter's credit balance is never a reported cadence, so the
        // `periodKind` override below must not retitle it "Monthly".
        if self == .openRouter || self == .claudePlatform {
            return .accountCredits
        }
        if let periodKind, let titled = quotaTitleKey(overridingWith: periodKind) {
            return titled
        }
        return .weekly
    }

    public var weeklyQuotaTitle: String { weeklyQuotaTitle(limitTotal: nil) }

    /// Title for a reported period that did not land in a named slot.
    ///
    /// A provider-supplied label wins over every cadence rule below: Codex's
    /// Luna reserve is a weekly window beside the plan's own weekly window, and
    /// naming it from its cadence would draw two bars both called "Weekly".
    /// The two labels legacy Cursor accounts carry map back to their localized
    /// titles; any other label stays provider data, verbatim.
    public func additionalQuotaTitleKey(for limit: UsageLimit) -> QuotaTitleKey {
        if let label = limit.label, !label.isEmpty {
            if self == .xai {
                if label == Self.legacyCursorModelsLabel { return .cursorModels }
                if label == Self.legacyOtherModelsLabel { return .otherModels }
            }
            return .model(label: label)
        }
        return quotaTitleKey(for: limit.periodKind, limitTotal: limit.total, unspecified: .quota)
    }

    /// Shared cadence → title mapping. `session` / `weekly` keep each
    /// provider's existing slot exceptions; every other kind is named honestly
    /// so a monthly Grok allowance cannot render as "Weekly".
    public func quotaTitleKey(
        for periodKind: UsageLimit.PeriodKind?,
        limitTotal: Double? = nil,
        unspecified: QuotaTitleKey = .quota
    ) -> QuotaTitleKey {
        guard let periodKind else { return unspecified }
        if let titled = quotaTitleKey(overridingWith: periodKind) {
            return titled
        }
        switch periodKind {
        case .session:
            return sessionQuotaTitleKey(limitTotal: limitTotal)
        case .weekly:
            return weeklyQuotaTitleKey(limitTotal: limitTotal)
        case .daily, .monthly, .billing, .unknown:
            return unspecified
        }
    }

    /// Cadences that replace the slot's default title. `session` and `weekly`
    /// return `nil` so OpenRouter / Cursor exceptions still apply.
    private func quotaTitleKey(overridingWith periodKind: UsageLimit.PeriodKind) -> QuotaTitleKey? {
        switch periodKind {
        case .daily: return .daily
        case .monthly: return .monthly
        case .billing: return .billingCycle
        case .unknown: return .quota
        case .session, .weekly: return nil
        }
    }
}
