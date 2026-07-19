import Foundation
import MeterBarShared

/// One account/provider quota competing for the menu bar percentage slot.
struct StatusLimitCandidate: Equatable, Sendable {
    /// Legacy Auto identity (e.g. "claude:<uuid>", "codex:<uuid>", "cursor")
    /// retained byte-for-byte so sticky selection and equal-quota tie-breaks do
    /// not change when the user leaves the new preference set to Auto.
    let key: String
    /// Stable provider/account/window identity persisted for explicit pins.
    let pinKey: String
    /// Human-readable label for the status item tooltip.
    let displayName: String
    /// Provider-specific quota-window label (Session, Weekly, Sonnet, etc.).
    let windowName: String
    let limit: UsageLimit
    /// Most recent on-disk activity for the account, nil when undetectable.
    let lastActivity: Date?
    /// Only the same session/weekly windows used before #142 participate in
    /// Auto. Other windows exist solely so the user can pin them explicitly.
    let isAutoSelectable: Bool
}

/// One menu-bar-title candidate whose on-disk activity probe has not run yet.
struct StatusLimitCandidateSeed: Sendable {
    let key: String
    let pinKey: String
    let displayName: String
    let windowName: String
    let limit: UsageLimit
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
        case .cursor, .openRouter:
            return "weekly"
        case .grok:
            return nil
        }
    }
}

enum StatusItemLimitCandidateBuilder {
    static func seeds(
        service: ServiceType,
        accountID: UUID?,
        autoSelectionKey: String?,
        displayName: String,
        limits: [SnapshotLimit]
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
                displayName: displayName,
                windowName: limit.title,
                limit: limit.usageLimit,
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
/// becomes clearly tighter — never ping-ponging on small fluctuations.
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

        let active = autoCandidates.filter { candidate in
            guard let lastActivity = candidate.lastActivity else { return false }
            return now.timeIntervalSince(lastActivity) <= activityWindow
        }

        // No detectable activity anywhere: fall back to the old behavior and
        // let every enabled account compete.
        let pool = active.isEmpty ? autoCandidates : active

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
