import Foundation

/// Trims a provider's component list for display. Status pages publish dozens
/// of components (OpenAI lists 20+), so each provider shows at most `limit`
/// top-level rows until the user expands it. Components with an issue are
/// pulled to the front so a degraded row is never hidden behind healthy ones.
struct ProviderStatusComponentPresentation: Equatable {
    static let defaultLimit = 5

    let visible: [ProviderStatusComponent]
    let hiddenCount: Int

    var isTruncated: Bool {
        hiddenCount > 0
    }

    static func make(
        components: [ProviderStatusComponent],
        limit: Int = defaultLimit,
        expanded: Bool = false
    ) -> ProviderStatusComponentPresentation {
        let ordered = prioritized(components)
        guard !expanded, ordered.count > limit else {
            return ProviderStatusComponentPresentation(visible: ordered, hiddenCount: 0)
        }
        return ProviderStatusComponentPresentation(
            visible: Array(ordered.prefix(limit)),
            hiddenCount: ordered.count - limit
        )
    }

    /// Stable partition: components with an issue keep their published order,
    /// followed by healthy ones in their published order.
    static func prioritized(_ components: [ProviderStatusComponent]) -> [ProviderStatusComponent] {
        components.filter(\.hasIssue) + components.filter { !$0.hasIssue }
    }
}
