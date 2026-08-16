import Foundation
import SwiftUI
import MeterBarShared

/// One provider card's worth of display data, shared by the popover and the
/// dashboard. Replaces two near-identical private snapshot/limit type pairs
/// (`PopoverProviderSnapshot`/`PopoverLimit` and `DashboardProviderSnapshot`/
/// `DashboardLimit`) whose duplicated logic had already drifted — the two
/// copies disagreed on the third limit's label rule, and the dashboard's hero
/// icon was re-derived by string-matching rendered title copy.
struct ProviderSnapshot: Identifiable {
    let id: String
    let title: String
    let service: ServiceType
    let updatedAt: Date?
    let limits: [SnapshotLimit]
    let emptyDetail: String
    let extraUsage: ExtraUsageStatus?
    let resetCreditsAvailable: Int?
    let accountID: UUID?
    /// Auth/staleness overlay for this card, or `nil` when the account is
    /// healthy. Deliberately separate from `band`, which stays a pure function
    /// of the percentages even when those percentages came from a stale cache.
    /// Defaulted so direct memberwise construction (mostly tests and previews)
    /// keeps meaning "nothing to overlay" without restating it everywhere. It is
    /// a `var` only because a defaulted `let` is dropped from the memberwise
    /// initializer entirely, which would leave the builder unable to set it.
    var authNotice: ProviderAuthNotice?

    var logoKind: ProviderLogoKind { .forService(service) }
    var accentColor: Color { MeterBarTheme.accent(for: service) }

    var displayedExtraUsage: ExtraUsageStatus? {
        ExtraUsageDisplayPolicy.visibleStatus(for: service, status: extraUsage)
    }

    var updatedText: String {
        guard let updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }

    /// Whether the provider has reported metrics at all (drives whether the
    /// dashboard renders a card for it).
    var hasMetrics: Bool { updatedAt != nil }

    /// The provider-wide limit closest to exhaustion — what the card's status
    /// reflects. Model-scoped Sonnet/Fable and code-review windows remain
    /// visible on their own rows but do not mean the provider is unavailable.
    ///
    /// Cursor's included pools spill over into each other, so the card's status
    /// follows the pool with the most room: emptying Cursor Models while Other
    /// Models still has 73% left is not "Out". Only when every pool is gone does
    /// the roomiest one read exhausted too, and the header agrees with
    /// `blockingLimits`.
    var primaryLimit: SnapshotLimit? {
        let providerLimits = limits.filter(\.isProviderBlocking)
        if hasCursorSpilloverPools {
            return providerLimits.max { $0.percentLeft < $1.percentLeft }
        }
        return providerLimits.min { $0.percentLeft < $1.percentLeft }
    }

    /// Two or more included Cursor pools (Cursor Models / Other Models). Only the
    /// percent-of-100 pools spill into each other, so the check is the pool
    /// denominator, not the window count: a legacy on-demand + monthly pair is
    /// two blocking windows that do NOT share a budget and keeps the normal
    /// tightest-window rules, as does a lone monthly bar.
    private var hasCursorSpilloverPools: Bool {
        guard service == .cursor else { return false }
        let providerLimits = limits.filter(\.isProviderBlocking)
        return providerLimits.count >= 2
            && providerLimits.allSatisfy { ServiceType.isCursorIncludedPool(total: $0.usageLimit.total) }
    }

    /// Severity band of the primary limit; `nil` when no limits are reported.
    var band: QuotaBand? {
        primaryLimit.map { QuotaBand.forPercentLeft($0.percentLeft) }
    }

    /// Session/weekly windows that can block normal provider usage. Secondary
    /// model/code-review quotas remain visible but must not collapse the entire
    /// provider card or claim the provider is unavailable.
    var blockingLimits: [SnapshotLimit] {
        guard extraUsage?.state != .on else { return [] }
        let exhausted = limits.filter {
            $0.isProviderBlocking
                && !$0.usageLimit.isEstimated
                && $0.usageLimit.isAtLimit
        }
        if hasCursorSpilloverPools {
            // Spillover: emptying Cursor Models still leaves Other Models, and
            // the reverse. Collapse the card only when every included pool is
            // gone. A lone legacy monthly bar still blocks on its own.
            let pools = limits.filter(\.isProviderBlocking)
            return exhausted.count == pools.count ? exhausted : []
        }
        return exhausted
    }

    /// Reset windows used by blocking-state UI. Filtering here prevents a
    /// simultaneous secondary-quota reset from being presented as the time at
    /// which normal provider usage resumes.
    var resetWindows: [ResetCountdownWindow] {
        blockingLimits.map {
            ResetCountdownWindow(
                id: "\(id)-\($0.title)",
                title: $0.localizedTitle,
                limit: $0.usageLimit
            )
        }
    }

    var hasExhaustedLimit: Bool { !blockingLimits.isEmpty }

    /// Weekly exhaustion blocks the whole subscription even when the shorter
    /// session window still has room. Compact overview cards should prioritize
    /// that reset instead of spending space on the session gauge.
    var hasExhaustedWeeklyLimit: Bool {
        blockingLimits.contains { $0.kind == .weekly }
    }

    /// Detail surfaces should focus on the limit that is actually blocking use.
    /// When the weekly subscription quota is exhausted, every shorter or
    /// model-specific window is non-actionable until that weekly reset.
    var detailLimits: [SnapshotLimit] {
        guard hasExhaustedWeeklyLimit else { return limits }
        return limits.filter { $0.kind == .weekly }
    }

    // MARK: - Accessibility

    /// VoiceOver label for a provider card: provider name, severity band, and
    /// freshness — the same three facts the card renders in its header. Kept as
    /// a pure computed property (like `DailyUsageDay.chartAccessibilityLabel`)
    /// so the popover and dashboard cards can't drift and the composition is
    /// unit-testable without the network or a rendered view.
    /// The notice leads when present: reading a stale cache's band aloud as
    /// "Healthy" is exactly the failure this overlay exists to prevent.
    var accessibilityLabel: String {
        let status = authNotice?.shortLabel ?? band?.shortLabel ?? "No data"
        return "\(title), \(status), \(updatedText)"
    }

    /// VoiceOver value for a provider card: each quota window's reading spoken
    /// in order, so a `children: .combine` card announces as one coherent
    /// summary instead of a fragmented subview tree. Falls back to the card's
    /// empty-state copy when no windows are reported.
    var accessibilityValue: String {
        guard !limits.isEmpty else { return emptyDetail }
        return limits
            .map { "\($0.accessibilityLabel), \($0.accessibilityValue)" }
            .joined(separator: ", ")
    }
}

enum ExtraUsageDisplayPolicy {
    static func visibleStatus(for service: ServiceType, status: ExtraUsageStatus?) -> ExtraUsageStatus? {
        guard let status else { return nil }
        guard service == .claudeCode, status.state == .unknown else {
            return status
        }
        return ClaudeCodeLocalService.isOAuthUsageEnabled() ? status : nil
    }
}

struct SnapshotLimit: Identifiable {
    enum Kind {
        case session
        case weekly
        case codeReview
    }

    let id: String
    let kind: Kind
    let title: String
    /// Which quota-window title the builder routed this limit to, or `nil` when
    /// the copy was handed in directly (previews, layout fixtures). Localization
    /// switches over this instead of over `title`, so renaming the English words
    /// cannot silently drop a locale back to English.
    let quotaTitleKey: ServiceType.QuotaTitleKey?
    let usageLimit: UsageLimit
    let valueStyle: ValueStyle

    enum ValueStyle: Equatable {
        case quota
        case currency
    }

    /// Routed construction: the shared key decides both the English words and
    /// the translated ones, so the two cannot disagree.
    init(
        id: String,
        kind: Kind,
        quotaTitleKey: ServiceType.QuotaTitleKey,
        usageLimit: UsageLimit,
        valueStyle: ValueStyle = .quota
    ) {
        self.id = id
        self.kind = kind
        self.title = quotaTitleKey.englishTitle
        self.quotaTitleKey = quotaTitleKey
        self.usageLimit = usageLimit
        self.valueStyle = valueStyle
    }

    /// Verbatim construction for copy that is not a routed quota window.
    init(id: String, kind: Kind, title: String, usageLimit: UsageLimit, valueStyle: ValueStyle = .quota) {
        self.id = id
        self.kind = kind
        self.title = title
        self.quotaTitleKey = nil
        self.usageLimit = usageLimit
        self.valueStyle = valueStyle
    }

    var usedPercent: Double {
        usageLimit.rawPercentage
    }

    var percentLeft: Int {
        QuotaMath.percentLeft(for: usageLimit)
    }

    var isProviderBlocking: Bool {
        kind == .session || kind == .weekly
    }

    /// Pace copy differs for rolling session windows vs weekly/billing windows.
    /// Derived from the limit's kind, not by string-matching the display title.
    var paceContext: PaceLabelContext {
        kind == .weekly ? .weekly : .session
    }

    // MARK: - Accessibility

    private var isOut: Bool { percentLeft <= 0 }

    /// VoiceOver label naming this quota window, appending "estimated" when the
    /// total was derived rather than provider-reported (the visual "Estimated"
    /// tag). Shared by all three limit-row renderers so they read identically.
    var accessibilityLabel: String {
        usageLimit.isEstimated ? "\(title), estimated" : title
    }

    /// App-target projection for standard quota-window copy. Parsed model
    /// labels are provider data and remain verbatim.
    ///
    /// Which title applies — the OpenRouter exceptions, Cursor's included-pool
    /// split, Claude Code's model window — is decided once in `ServiceType`.
    /// This switch only supplies the app bundle's words for that decision, the
    /// same way `WidgetLocalizedContent.quotaTitle(for:)` supplies the widget
    /// bundle's. Matching on the English `title` instead would mean a rename in
    /// `ServiceType` quietly shipped English to every locale.
    var localizedTitle: String {
        guard let quotaTitleKey else { return title }
        switch quotaTitleKey {
        case .keyLimit:
            return String(localized: "quota.title.key_limit", defaultValue: "Key limit")
        case let .model(label):
            return label
                ?? String(localized: "quota.title.model", defaultValue: "Model")
        case .onDemand:
            return String(localized: "quota.title.on_demand", defaultValue: "On-demand")
        case .codeReview:
            return String(localized: "quota.title.code_review", defaultValue: "Code Review")
        case .cursorModels:
            return String(localized: "quota.title.cursor_models", defaultValue: "Cursor Models")
        case .session:
            return String(localized: "quota.title.session", defaultValue: "Session")
        case .accountCredits:
            return String(localized: "quota.title.account_credits", defaultValue: "Account credits")
        case .otherModels:
            return String(localized: "quota.title.other_models", defaultValue: "Other Models")
        case .monthly:
            return String(localized: "quota.title.monthly", defaultValue: "Monthly")
        case .weekly:
            return String(localized: "quota.title.weekly", defaultValue: "Weekly")
        }
    }

    /// Localized equivalent used by UI surfaces. The English property above is
    /// retained for existing non-UI callers and compatibility tests.
    var localizedAccessibilityLabel: String {
        usageLimit.isEstimated ? LocalizedUsageFormat.estimatedLabel(localizedTitle) : localizedTitle
    }

    /// VoiceOver value for a quota window: how much is left and how much is
    /// used/spent, mirroring the trailing value + used-value copy the rows
    /// render. Currency-style limits (OpenRouter key/credit balances) speak
    /// dollars; quota-style limits speak percentages.
    var accessibilityValue: String {
        if valueStyle == .currency {
            let left = UsageFormat.cost(max(0, usageLimit.total - usageLimit.used))
            return "\(left) left, \(UsageFormat.cost(usageLimit.used)) spent"
        }
        let trailing = (isOut && !usageLimit.isEstimated) ? "Out" : usageLimit.percentLeftText
        return "\(trailing), \(usageLimit.usedPercentageText)"
    }

    /// Localized equivalent used by app views and VoiceOver.
    var localizedAccessibilityValue: String {
        if valueStyle == .currency {
            let left = LocalizedUsageFormat.amountLeft(
                UsageFormat.cost(max(0, usageLimit.total - usageLimit.used))
            )
            let spent = LocalizedUsageFormat.amountSpent(UsageFormat.cost(usageLimit.used))
            return LocalizedUsageFormat.pairedValue(left, spent)
        }
        let trailing = (isOut && !usageLimit.isEstimated)
            ? LocalizedUsageFormat.out()
            : LocalizedUsageFormat.percentLeft(usageLimit)
        return LocalizedUsageFormat.pairedValue(trailing, LocalizedUsageFormat.percentUsed(usageLimit))
    }
}

enum ProviderSnapshotBuilder {
    struct Input {
        var metrics: [ServiceType: UsageMetrics]
        /// Clock for cache-freshness. Injectable so stale-cache fixtures do not
        /// depend on wall time.
        var now: Date = Date()
        /// Provider-level parse health. Applied only to a card whose own
        /// refresh failed, so one broken custom profile cannot mark siblings.
        var parseHealth: [ServiceType: ProviderParseHealthRecord] = [:]
        var codexAccounts: [CodexAccount] = [.defaultAccount]
        var codexAccountMetrics: [UUID: UsageMetrics] = [:]
        /// Last observed Codex auth result per account id. Empty means "nothing
        /// probed yet", which leaves the default sentinel on `codexCliHasAccess`.
        var codexAccountAccess: [UUID: Bool] = [:]
        var grokAccounts: [GrokAccount] = [.defaultAccount]
        var grokAccountMetrics: [UUID: UsageMetrics] = [:]
        /// Last observed Grok auth result per account id. Empty means unprobed.
        var grokAccountAccess: [UUID: Bool] = [:]
        var claudeAccounts: [ClaudeCodeAccount]
        var claudeAccountMetrics: [UUID: UsageMetrics]
        var enabledServices: Set<ServiceType>
        /// Per-account auth/staleness, keyed by account id. Defaulted so the
        /// non-Claude call sites (and every existing test) keep compiling; an
        /// absent entry simply means "nothing to overlay".
        var claudeAccountStates: [UUID: ClaudeCodeAuthState] = [:]
        var claudeCodeHasAccess: Bool = false
        var codexCliHasAccess: Bool = false
        var cursorHasAccess: Bool = false
        var openRouterHasAccess: Bool = false
        var grokHasAccess: Bool = false
        var lastErrors: ProviderPresentationHealth.LastErrors = .init()

        /// The popover, dashboard, and settings cards all read the same live
        /// stores. Building Input here keeps lastError / parse health / Grok
        /// access from drifting apart across those surfaces.
        @MainActor
        static func live(
            dataManager: UsageDataManager,
            claudeAccounts: [ClaudeCodeAccount],
            codexAccounts: [CodexAccount],
            grokAccounts: [GrokAccount],
            enabledServices: Set<ServiceType>,
            claudeCodeService: ClaudeCodeLocalService,
            codexCliService: CodexCliLocalService,
            cursorService: CursorLocalService,
            openRouterService: OpenRouterService,
            grokService: GrokCLIUsageService,
            parseHealth: [ServiceType: ProviderParseHealthRecord],
            now: Date = Date()
        ) -> Input {
            Input(
                metrics: dataManager.metrics,
                now: now,
                parseHealth: parseHealth,
                codexAccounts: codexAccounts,
                codexAccountMetrics: dataManager.codexAccountMetrics,
                codexAccountAccess: codexCliService.accountAccess,
                grokAccounts: grokAccounts,
                grokAccountMetrics: dataManager.grokAccountMetrics,
                grokAccountAccess: Dictionary(uniqueKeysWithValues: grokAccounts.map {
                    ($0.id, grokService.canAccess(account: $0))
                }),
                claudeAccounts: claudeAccounts,
                claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                enabledServices: enabledServices,
                claudeAccountStates: dataManager.claudeCodeAccountStates,
                claudeCodeHasAccess: claudeCodeService.hasAccess,
                codexCliHasAccess: codexCliService.hasAccess,
                cursorHasAccess: cursorService.hasAccess,
                openRouterHasAccess: openRouterService.hasAccess,
                grokHasAccess: grokService.hasAccess,
                lastErrors: ProviderPresentationHealth.LastErrors(
                    cursor: cursorService.lastError,
                    openRouter: openRouterService.lastError,
                    codexAccounts: codexCliService.accountErrors,
                    grokAccounts: grokService.accountErrors
                )
            )
        }
    }

    /// Builds the provider cards. Emission order follows each store; the
    /// returned array is then sorted for display: same subscription stays
    /// together, groups sit at their earliest label, labels inside a group
    /// are alphabetical. Providers without metrics are included with an
    /// empty-state detail so the popover can render a "waiting / log in"
    /// card; the dashboard filters those out via `hasMetrics`.
    static func snapshots(_ input: Input) -> [ProviderSnapshot] {
        var result: [ProviderSnapshot] = []

        if input.enabledServices.contains(.codexCli) {
            let enabledAccounts = input.codexAccounts.filter(\.isEnabled)
            if !enabledAccounts.isEmpty {
                for account in enabledAccounts {
                    let title = account.isDefault
                        && account.name == CodexAccount.defaultName
                        && enabledAccounts.count == 1
                        ? ServiceType.codexCli.shortName
                        : account.name
                    // A signed-in custom `CODEX_HOME` profile is waiting for a
                    // refresh, not for a login — only ask for one when this
                    // account's own probe says it has no usable token.
                    let emptyDetail = CodexAccountAccessProjection.isAuthenticated(
                        account: account,
                        accountAccess: input.codexAccountAccess,
                        defaultHasAccess: input.codexCliHasAccess
                    )
                        ? "Waiting for refresh"
                        : "Run codex login"
                    let fallbackMetrics = account.isDefault
                        && enabledAccounts.count == 1
                        && input.codexAccountMetrics.isEmpty
                        ? input.metrics[.codexCli]
                        : nil
                    let metrics = input.codexAccountMetrics[account.id] ?? fallbackMetrics
                    result.append(snapshot(
                        title: title,
                        service: .codexCli,
                        metrics: metrics,
                        emptyDetail: emptyDetail,
                        accountID: account.id,
                        authNotice: notice(
                            for: .codexCli,
                            accountID: account.id,
                            metrics: metrics,
                            input: input
                        )
                    ))
                }
            }
        }

        if input.enabledServices.contains(.claudeCode) {
            let enabledAccounts = input.claudeAccounts.filter(\.isEnabled)
            let accountMetrics = input.claudeAccountMetrics
            if !enabledAccounts.isEmpty {
                for account in enabledAccounts {
                    let title = account.isDefault
                        && account.name == ClaudeCodeAccount.defaultName
                        && enabledAccounts.count == 1
                        ? ServiceType.claudeCode.shortName
                        : account.name
                    let emptyDetail = account.isDefault && input.claudeCodeHasAccess
                        ? "Waiting for refresh"
                        : "Run claude login"
                    let metrics = accountMetrics[account.id] ?? (account.isDefault ? input.metrics[.claudeCode] : nil)
                    result.append(snapshot(
                        title: title,
                        service: .claudeCode,
                        metrics: metrics,
                        emptyDetail: emptyDetail,
                        accountID: account.id,
                        authNotice: notice(
                            for: .claudeCode,
                            accountID: account.id,
                            metrics: metrics,
                            input: input
                        )
                    ))
                }
            }
        }

        if input.enabledServices.contains(.cursor) {
            let metrics = input.metrics[.cursor]
            result.append(snapshot(
                title: ServiceType.cursor.shortName,
                service: .cursor,
                metrics: metrics,
                emptyDetail: input.cursorHasAccess ? "Waiting for refresh" : "Log in to Cursor",
                authNotice: notice(for: .cursor, accountID: nil, metrics: metrics, input: input)
            ))
        }

        if input.enabledServices.contains(.openRouter) {
            let metrics = input.metrics[.openRouter]
            result.append(snapshot(
                title: ServiceType.openRouter.shortName,
                service: .openRouter,
                metrics: metrics,
                emptyDetail: input.openRouterHasAccess ? "Waiting for refresh" : "Add an OpenRouter API key",
                authNotice: notice(for: .openRouter, accountID: nil, metrics: metrics, input: input)
            ))
        }

        if input.enabledServices.contains(.grok) {
            let enabledAccounts = input.grokAccounts.filter(\.isEnabled)
            for account in enabledAccounts {
                let title = account.isDefault
                    && account.name == GrokAccount.defaultName
                    && enabledAccounts.count == 1
                    ? ServiceType.grok.shortName
                    : account.name
                let fallbackMetrics = account.isDefault
                    && enabledAccounts.count == 1
                    && input.grokAccountMetrics.isEmpty
                    ? input.metrics[.grok]
                    : nil
                let metrics = input.grokAccountMetrics[account.id] ?? fallbackMetrics
                result.append(snapshot(
                    title: title,
                    service: .grok,
                    metrics: metrics,
                    emptyDetail: account.isDefault && input.grokHasAccess
                        ? "Waiting for refresh"
                        : "Run grok login",
                    accountID: account.id,
                    authNotice: notice(for: .grok, accountID: account.id, metrics: metrics, input: input)
                ))
            }
        }

        return orderedForDisplay(result)
    }

    /// Connection-health overlay for one card. Claude states still win for
    /// login/unavailable/error; lastUpdated and parse health then apply so a
    /// connected-but-aged cache is Stale, not Healthy. Non-Claude cards use
    /// lastError + access + parse health. Provider-level parse health only
    /// upgrades a card whose own refresh failed.
    private static func notice(
        for service: ServiceType,
        accountID: UUID?,
        metrics: UsageMetrics?,
        input: Input
    ) -> ProviderAuthNotice? {
        if service == .claudeCode {
            if let state = accountID.flatMap({ input.claudeAccountStates[$0] }),
               let claudeNotice = ProviderAuthNotice.forState(state) {
                return claudeNotice
            }
            return ProviderPresentationHealth.notice(
                access: .signedIn,
                refresh: metrics == nil ? .unprobed : .success,
                lastUpdated: metrics?.lastUpdated,
                parseHealth: nil,
                now: input.now
            )
        }

        let lastError: ServiceError?
        let probed: Bool?
        let usesAPIKey: Bool
        switch service {
        case .codexCli:
            lastError = accountID.flatMap { input.lastErrors.codexAccounts[$0] }
            probed = accountID.flatMap { input.codexAccountAccess[$0] }
            usesAPIKey = false
        case .grok:
            lastError = accountID.flatMap { input.lastErrors.grokAccounts[$0] }
            probed = accountID.flatMap { input.grokAccountAccess[$0] }
            usesAPIKey = false
        case .cursor:
            lastError = input.lastErrors.cursor
            probed = input.cursorHasAccess ? true : nil
            usesAPIKey = false
        case .openRouter:
            lastError = input.lastErrors.openRouter
            probed = input.openRouterHasAccess ? true : nil
            usesAPIKey = true
        case .claudeCode:
            lastError = nil
            probed = nil
            usesAPIKey = false
        }

        let parseHealth = input.parseHealth[service]
        let refresh = ProviderPresentationHealth.refreshOutcome(
            lastError: lastError,
            parseHealth: parseHealth,
            hasCache: metrics != nil
        )
        return ProviderPresentationHealth.notice(
            access: ProviderPresentationHealth.access(
                probed: probed,
                lastError: lastError,
                usesAPIKey: usesAPIKey
            ),
            refresh: refresh,
            lastUpdated: metrics?.lastUpdated,
            parseHealth: parseHealth,
            now: input.now
        )
    }

    /// Stable card order for the popover, Overview, and Limits.
    ///
    /// Group by subscription so two Claude (or Codex, or Grok) accounts stay
    /// adjacent. Place each group where its alphabetically-earliest label
    /// belongs, then sort labels inside the group. Focus/selection must not
    /// call this with a different ranking — clicking a card scrolls to it.
    static func orderedForDisplay(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        let groupKeyByService: [ServiceType: String] = Dictionary(
            grouping: snapshots,
            by: \.service
        ).mapValues { group in
            group.map(\.title).min { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            } ?? ""
        }

        return snapshots.sorted { lhs, rhs in
            let lhsGroup = groupKeyByService[lhs.service] ?? lhs.title
            let rhsGroup = groupKeyByService[rhs.service] ?? rhs.title
            let groupOrder = lhsGroup.localizedStandardCompare(rhsGroup)
            if groupOrder != .orderedSame {
                return groupOrder == .orderedAscending
            }
            if lhs.service != rhs.service {
                let typeOrder = lhs.service.shortName.localizedStandardCompare(rhs.service.shortName)
                if typeOrder != .orderedSame {
                    return typeOrder == .orderedAscending
                }
            }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    static func snapshot(
        title: String,
        service: ServiceType,
        metrics: UsageMetrics?,
        emptyDetail: String,
        accountID: UUID? = nil,
        authNotice: ProviderAuthNotice? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            // Disambiguate by account id so two accounts that share a display
            // name (e.g. both "Work") don't collide on a single Identifiable
            // id, which would corrupt the ForEach rendering the cards.
            id: "\(service.rawValue)-\(title)-\(accountID?.uuidString ?? "default")",
            title: title,
            service: service,
            updatedAt: metrics?.lastUpdated,
            limits: limits(for: metrics, service: service),
            emptyDetail: emptyDetail,
            extraUsage: metrics?.extraUsage,
            resetCreditsAvailable: metrics?.resetCreditsAvailable,
            accountID: accountID,
            authNotice: authNotice
        )
    }

    static func limits(for metrics: UsageMetrics?, service: ServiceType) -> [SnapshotLimit] {
        guard let metrics else { return [] }

        var result: [SnapshotLimit] = []
        if let session = metrics.sessionLimit {
            result.append(SnapshotLimit(
                id: "session",
                kind: .session,
                quotaTitleKey: service.sessionQuotaTitleKey(limitTotal: session.total),
                usageLimit: session,
                valueStyle: service == .openRouter ? .currency : .quota
            ))
        }
        if let weekly = metrics.weeklyLimit {
            result.append(SnapshotLimit(
                id: "weekly",
                kind: .weekly,
                quotaTitleKey: service.weeklyQuotaTitleKey(limitTotal: weekly.total),
                usageLimit: weekly,
                valueStyle: service == .openRouter ? .currency : .quota
            ))
        }
        if let codeReview = metrics.codeReviewLimit {
            // Claude's third window is model-scoped and has changed names
            // across CLI releases. Preserve the parsed label instead of
            // relabeling Fable as Sonnet; legacy caches use a neutral fallback.
            result.append(SnapshotLimit(
                id: "codeReview",
                kind: .codeReview,
                quotaTitleKey: service.codeReviewQuotaTitleKey(modelLimitLabel: metrics.modelLimitLabel),
                usageLimit: codeReview
            ))
        }
        return result
    }
}

extension Array where Element == ProviderSnapshot {
    var statusItemPinOptions: [StatusItemPinOption] {
        flatMap { snapshot in
            snapshot.limits.map { limit in
                StatusItemPinOption(
                    id: StatusItemPinKey.make(
                        service: snapshot.service,
                        accountID: snapshot.accountID,
                        windowID: limit.id
                    ),
                    title: "\(snapshot.title) · \(limit.title)"
                )
            }
        }
    }
}

extension Array where Element == ProviderSnapshot {
    /// The single tightest provider-wide quota window across every provider —
    /// what the overview hero reports. Model-specific exhaustion is scoped to
    /// its own row and must not collapse the global provider summary.
    var tightestLimit: SnapshotLimit? {
        compactMap(\.primaryLimit).min { $0.percentLeft < $1.percentLeft }
    }

    /// Ranks these providers by remaining headroom — the "what should I use
    /// next?" answer. Pass the *unfiltered* snapshot list: the planner needs the
    /// providers with no cached usage in order to list them under its no-data
    /// state instead of silently dropping them. Hidden providers never appear
    /// here because `ProviderSnapshotBuilder` only emits enabled services, so
    /// they are omitted from every recommendation surface for free.
    func headroomRecommendation(now: Date = Date()) -> ProviderRecommendation {
        var displayOrderByService: [ServiceType: Int] = [:]
        let candidates = map { snapshot -> ProviderRecommendationCandidate in
            let displayOrder = displayOrderByService[snapshot.service, default: 0]
            displayOrderByService[snapshot.service] = displayOrder + 1
            return ProviderRecommendationCandidate(
                id: snapshot.id,
                name: snapshot.title,
                service: snapshot.service,
                displayOrder: displayOrder,
                sessionLimit: snapshot.limits.first { $0.kind == .session }?.usageLimit,
                weeklyLimit: snapshot.limits.first { $0.kind == .weekly }?.usageLimit,
                lastUpdated: snapshot.updatedAt,
                // A signed-out or unreachable account can still hold a fresh,
                // healthy-looking cache. Recommending it would send the user to
                // a tool they cannot actually run.
                unavailableReason: snapshot.authNotice.map { .blocked($0.shortLabel) }
            )
        }
        return ProviderRecommendationPlanner.rank(candidates: candidates, now: now)
    }
}
