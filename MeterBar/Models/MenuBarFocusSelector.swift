import Foundation
import MeterBarShared

/// Everything the focus resolver knows about the frontmost app (issue #341).
///
/// Deliberately only a bundle identifier: MeterBar never asks for accessibility
/// permission, never reads window titles or documents, and never inspects which
/// CLI is running inside a terminal. The user's mapping is the only link between
/// an app and a provider.
nonisolated struct MenuBarFocusContext: Equatable, Sendable {
    /// Bundle identifier of the frontmost app, nil when it has none or when
    /// nothing has been observed yet.
    let bundleID: String?
    /// User-editable bundle identifier → provider mapping.
    let mapping: [String: ServiceType]
    /// Providers the user has not hidden. A mapping onto a hidden provider is
    /// treated as no mapping at all.
    let visibleServices: Set<ServiceType>
}

/// Resolves "the frontmost app is X, so show provider Y" into one candidate.
///
/// Returning nil is the normal, load-bearing outcome: it means *this input has
/// no opinion*, and the caller falls through to `StatusItemLimitSelector` so
/// Auto behaves exactly as it did before the feature existed.
nonisolated enum MenuBarFocusSelector {
    /// Bands at or above this rank take the menu bar back from focus following.
    /// A quota the user cannot see running out is more urgent than the quota
    /// belonging to the app they are looking at.
    private static let overridingBand = QuotaBand.critical

    static func select(
        candidates: [StatusLimitCandidate],
        context: MenuBarFocusContext
    ) -> StatusLimitCandidate? {
        guard let bundleID = context.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty,
              let service = context.mapping[bundleID],
              context.visibleServices.contains(service) else { return nil }

        // Same Auto-window rule as the default selector: other windows exist
        // only so the user can pin them explicitly.
        let autoCandidates = candidates.filter {
            $0.isAutoSelectable && context.visibleServices.contains($0.service)
        }
        let focused = autoCandidates.filter { $0.service == service }
        // No data for the mapped provider is indistinguishable from no mapping.
        guard let selection = tightest(in: focused) else { return nil }

        let urgentElsewhere = autoCandidates.contains {
            $0.service != service
                && QuotaBand.forLimit($0.limit).severityRank >= overridingBand.severityRank
        }
        guard !urgentElsewhere else { return nil }

        return selection
    }

    /// Tightest measurable quota with anything left, falling back to the spent
    /// ones when every window of the focused provider is spent — mirrors the
    /// spent-account rule in `StatusItemLimitSelector` so the two never disagree about
    /// which window of a provider represents it.
    private static func tightest(in candidates: [StatusLimitCandidate]) -> StatusLimitCandidate? {
        // A zero total carries no headroom information — reading it as "100%
        // left" would put the one window MeterBar cannot measure in the menu
        // bar, and ahead of the provider's spent windows at that. Dropped
        // outright rather than kept as a fallback pool: with nothing measurable
        // for the focused provider this input has no opinion, so Auto decides.
        let measurable = candidates.filter { $0.limit.total > 0 }
        let withQuotaLeft = measurable.filter { QuotaMath.percentLeft(for: $0.limit) > 0 }
        let pool = withQuotaLeft.isEmpty ? measurable : withQuotaLeft
        return pool.min { lhs, rhs in
            // Tie-break on key so equal quotas resolve deterministically.
            (QuotaMath.percentLeft(for: lhs.limit), lhs.key)
                < (QuotaMath.percentLeft(for: rhs.limit), rhs.key)
        }
    }
}
