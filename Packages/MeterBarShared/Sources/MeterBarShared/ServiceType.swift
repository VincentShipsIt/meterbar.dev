import Foundation

/// The subscription providers MeterBar tracks. The admin-API providers
/// (`Claude`/`OpenAI` raw values) were removed with the admin-key feature;
/// tolerant cache decoding skips their entries in older on-disk payloads.
public enum ServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "Claude Code"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"
    case openRouter = "OpenRouter"
    case grok = "Grok"

    public var id: String { rawValue }

    /// The full product name. Use it wherever a provider is being *named*:
    /// settings section headers, sidebar rows, notification titles, CLI JSON,
    /// share cards.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli: return "OpenAI Codex"
        case .cursor: return "Cursor"
        case .openRouter: return "OpenRouter"
        case .grok: return "Grok"
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
        case .cursor: return "Cursor"
        case .openRouter: return "OpenRouter"
        case .grok: return "Grok"
        }
    }

    /// SF Symbol name used by the app UI.
    public var iconName: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codexCli: return "terminal.fill"
        case .cursor: return "cursorarrow.click"
        case .openRouter: return "point.3.connected.trianglepath.dotted"
        case .grok: return "bolt.fill"
        }
    }

    /// Asset-catalog image name used by the widget extension, which ships
    /// provider logos instead of SF Symbols.
    public var assetName: String {
        switch self {
        case .claudeCode: return "ClaudeIcon"
        case .codexCli: return "CodexIcon"
        case .cursor: return "CursorIcon"
        case .openRouter: return "OpenRouterIcon"
        case .grok: return "GrokIcon"
        }
    }

    /// Stable display ordering (most-used services first).
    public var sortOrder: Int {
        switch self {
        case .claudeCode: return 0
        case .codexCli: return 1
        case .cursor: return 2
        case .openRouter: return 3
        case .grok: return 4
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
        case .claudeCode, .codexCli, .grok: return true
        case .cursor, .openRouter: return false
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
        case .cursor: return .onDemand
        case .codexCli, .openRouter, .grok: return .codeReview
        }
    }

    /// Cursor's dashboard reports each included pool as a percentage of 100
    /// (`autoPercentUsed` / `apiPercentUsed`), not as a request count. Limits
    /// mapped from those fields use this denominator so the popover, widget,
    /// and notifications can tell a percent pool from the legacy request quota.
    public static let cursorIncludedPoolTotal: Double = 100

    public static func isCursorIncludedPool(total: Double) -> Bool {
        abs(total - cursorIncludedPoolTotal) < 0.000_001
    }

    /// Display title for the short ("session") quota window. OpenRouter's is a
    /// key spend cap. Cursor's is the **Cursor Models** pool when the payload
    /// used the percent-of-100 shape, and "Session" for the legacy on-demand
    /// mapping.
    public func sessionQuotaTitle(limitTotal: Double?) -> String {
        sessionQuotaTitleKey(limitTotal: limitTotal).englishTitle
    }

    public func sessionQuotaTitleKey(limitTotal: Double?) -> QuotaTitleKey {
        switch self {
        case .openRouter: return .keyLimit
        case .cursor:
            if let limitTotal, Self.isCursorIncludedPool(total: limitTotal) {
                return .cursorModels
            }
            return .session
        case .claudeCode, .codexCli, .grok: return .session
        }
    }

    /// Display title for the long ("weekly") quota window. The shared window id
    /// stays `weekly` across providers, but its real cadence does not: Cursor's
    /// resets with `billingCycleEnd` (monthly), and OpenRouter's is a credit
    /// balance rather than a window at all. Centralized here for the same reason
    /// as `codeReviewQuotaTitle` — the popover, widget, and CLI each used to
    /// spell out the OpenRouter exception inline.
    ///
    /// Pass `limitTotal` when the concrete window is known: Cursor's percent
    /// pools title as **Other Models**, matching the dashboard; a request-count
    /// billing-cycle quota stays **Monthly**.
    public func weeklyQuotaTitle(limitTotal: Double?) -> String {
        weeklyQuotaTitleKey(limitTotal: limitTotal).englishTitle
    }

    public func weeklyQuotaTitleKey(limitTotal: Double?) -> QuotaTitleKey {
        switch self {
        case .openRouter: return .accountCredits
        case .cursor:
            if let limitTotal, Self.isCursorIncludedPool(total: limitTotal) {
                return .otherModels
            }
            return .monthly
        case .claudeCode, .codexCli, .grok: return .weekly
        }
    }

    public var weeklyQuotaTitle: String { weeklyQuotaTitle(limitTotal: nil) }
}
