import Foundation
import MeterBarShared

/// One account/provider quota competing for the menu bar percentage slot.
nonisolated struct StatusLimitCandidate: Equatable, Sendable {
    // MARK: Lifecycle

    init(
        key: String,
        pinKey: String,
        service: ServiceType,
        accountKey: String? = nil,
        displayName: String,
        windowID: String? = nil,
        windowName: String,
        limit: UsageLimit,
        lastUpdated: Date = Date(),
        lastActivity: Date?,
        isAutoSelectable: Bool
    ) {
        self.key = key
        self.pinKey = pinKey
        self.service = service
        self.accountKey = accountKey
        self.displayName = displayName
        self.windowID = windowID ?? Self.inferredWindowID(from: windowName)
        self.windowName = windowName
        self.limit = limit
        self.lastUpdated = lastUpdated
        self.lastActivity = lastActivity
        self.isAutoSelectable = isAutoSelectable
    }

    // MARK: Internal

    /// Legacy Auto identity (e.g. "claude:<uuid>", "codex:<uuid>", "cursor")
    /// retained byte-for-byte so sticky selection and equal-quota tie-breaks do
    /// not change when the user leaves the new preference set to Auto.
    let key: String
    /// Stable provider/account/window identity persisted for explicit pins.
    let pinKey: String
    /// Provider this quota belongs to, used for per-provider status item icons
    /// and deterministic left-to-right ordering in the menu bar.
    let service: ServiceType
    /// `MenuBarAccountKey` of the owning account, nil for single-account
    /// providers. Scopes a per-account status item to its own quotas (#266).
    let accountKey: String?
    /// Human-readable label for the status item tooltip.
    let displayName: String
    /// Stable provider window id (`session`, `weekly`, `codeReview`) used to
    /// pair combined labels without string-matching localized display copy.
    let windowID: String
    /// Provider-specific quota-window label (Session, Weekly, Sonnet, etc.).
    let windowName: String
    let limit: UsageLimit
    /// Provider snapshot timestamp. Formatting re-evaluates this against `now`
    /// so cached values become an honest unknown state once they age out.
    let lastUpdated: Date
    /// Most recent on-disk activity for the account, nil when undetectable.
    let lastActivity: Date?
    /// Only the same session/weekly windows used before #142 participate in
    /// Auto. Other windows exist solely so the user can pin them explicitly.
    let isAutoSelectable: Bool

    private static func inferredWindowID(from windowName: String) -> String {
        windowName.caseInsensitiveCompare("Weekly") == .orderedSame ? "weekly" : "session"
    }
}

/// One menu-bar-title candidate whose on-disk activity probe has not run yet.
nonisolated struct StatusLimitCandidateSeed: Sendable {
    init(
        key: String,
        pinKey: String,
        service: ServiceType,
        accountKey: String? = nil,
        displayName: String,
        windowID: String? = nil,
        windowName: String,
        limit: UsageLimit,
        lastUpdated: Date = Date(),
        isAutoSelectable: Bool
    ) {
        self.key = key
        self.pinKey = pinKey
        self.service = service
        self.accountKey = accountKey
        self.displayName = displayName
        self.windowID = windowID
            ?? (windowName.caseInsensitiveCompare("Weekly") == .orderedSame ? "weekly" : "session")
        self.windowName = windowName
        self.limit = limit
        self.lastUpdated = lastUpdated
        self.isAutoSelectable = isAutoSelectable
    }

    let key: String
    let pinKey: String
    let service: ServiceType
    /// `var` so the memberwise init defaults it to nil: single-account providers
    /// and the provider-level tests never name it.
    let accountKey: String?
    let displayName: String
    let windowID: String
    let windowName: String
    let limit: UsageLimit
    let lastUpdated: Date
    let isAutoSelectable: Bool
}

nonisolated enum StatusItemPinKey {
    static func make(service: ServiceType, accountID: UUID?, windowID: String) -> String {
        "\(service.rawValue):\(accountID?.uuidString ?? "default"):\(windowID)"
    }
}

/// Identifies the quota window each provider contributes to automatic menu-bar
/// selection. Other windows remain available for explicit pinning only.
nonisolated enum StatusItemAutoSelectionPolicy {
    static func windowID(for service: ServiceType) -> String? {
        switch service {
        case .claudeCode, .codexCli:
            return "session"
        case .cursor, .openRouter, .grok:
            return "weekly"
        }
    }
}

enum StatusItemLimitCandidateBuilder {
    static func seeds(
        service: ServiceType,
        accountID: UUID?,
        accountKey: String? = nil,
        autoSelectionKey: String?,
        displayName: String,
        limits: [SnapshotLimit],
        lastUpdated: Date = Date()
    ) -> [StatusLimitCandidateSeed] {
        let autoWindowID = StatusItemAutoSelectionPolicy.windowID(for: service)
        return limits.map { limit in
            let pinKey = StatusItemPinKey.make(
                service: service,
                accountID: accountID,
                windowID: limit.id
            )
            return StatusLimitCandidateSeed(
                key: limit.id == autoWindowID ? autoSelectionKey ?? pinKey : pinKey,
                pinKey: pinKey,
                service: service,
                accountKey: accountKey,
                displayName: displayName,
                windowID: limit.id,
                windowName: limit.title,
                limit: limit.usageLimit,
                lastUpdated: lastUpdated,
                isAutoSelectable: limit.id == autoWindowID
            )
        }
    }
}

struct StatusItemPinOption: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Picks which quota the menu bar title shows.
///
/// The menu bar used to pin the tightest quota across *all* enabled accounts,
/// so a drained account that wasn't in use dominated the number forever. This
/// selector instead follows the accounts with recent on-disk activity, and is
/// sticky: when several accounts are active at once (one Claude + one Codex),
/// the shown account only changes when it goes idle or another active account
/// becomes clearly tighter — never ping-ponging on small fluctuations. Accounts
/// with nothing left are skipped entirely, since "tightest" would otherwise mean
/// "the one you can't use" for as long as it stays drained.
enum StatusItemLimitSelector {
    /// Activity newer than this counts as "in use".
    static let activityWindow: TimeInterval = 30 * 60
    /// Keep the previously shown account while it is within this many
    /// %-left points of the tightest candidate.
    static let hysteresisPoints = 5

    static func select(
        candidates: [StatusLimitCandidate],
        previousKey: String?,
        pinnedKey: String? = nil,
        now: Date = Date(),
        activityWindow: TimeInterval = Self.activityWindow,
        hysteresisPoints: Int = Self.hysteresisPoints
    ) -> StatusLimitCandidate? {
        if let pinnedKey, let pinned = candidates.first(where: { $0.pinKey == pinnedKey }) {
            return pinned
        }

        let autoCandidates = candidates.filter(\.isAutoSelectable)
        guard !autoCandidates.isEmpty else { return nil }

        // A spent quota is always the tightest, so without this it wins every
        // round it enters and freezes the menu bar on 0% for days — the exact
        // symptom that made the title read "Codex 0%" while Claude had half its
        // session left. Filtered before the activity pass, since a spent account
        // is usually also the *only* recently active one. If everything is spent
        // the whole pool comes back so the title still shows a number.
        let withQuotaLeft = autoCandidates.filter { QuotaMath.percentLeft(for: $0.limit) > 0 }
        let selectable = withQuotaLeft.isEmpty ? autoCandidates : withQuotaLeft

        let active = selectable.filter { candidate in
            guard let lastActivity = candidate.lastActivity else { return false }
            return now.timeIntervalSince(lastActivity) <= activityWindow
        }

        // No detectable activity anywhere: fall back to the old behavior and
        // let every enabled account compete.
        let pool = active.isEmpty ? selectable : active

        guard let tightest = pool.min(by: { lhs, rhs in
            let lhsLeft = QuotaMath.percentLeft(for: lhs.limit)
            let rhsLeft = QuotaMath.percentLeft(for: rhs.limit)
            // Tie-break on key so equal quotas resolve deterministically.
            return (lhsLeft, lhs.key) < (rhsLeft, rhs.key)
        }) else { return nil }

        if let previousKey,
           let previous = pool.first(where: { $0.key == previousKey }),
           QuotaMath.percentLeft(for: previous.limit)
               <= QuotaMath.percentLeft(for: tightest.limit) + hysteresisPoints {
            return previous
        }

        return tightest
    }
}
