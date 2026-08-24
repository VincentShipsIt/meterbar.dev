import MeterBarShared
import SwiftUI

/// The identity row shared by `ProviderStatusCard` and the hover detail panel.
///
/// Both surfaces hand-rolled their own header and the two drifted: the panel
/// used a larger logo and title, labelled itself with the service name where the
/// card showed the refresh time, and dropped the status word entirely — so
/// hovering a card replaced it with something that read like a different
/// provider, and a logged-out account looked healthy the moment the pointer
/// landed on it. One component keeps them identical; the only legitimate
/// difference is the disclosure chevron, which belongs to the card because the
/// panel is already the thing it discloses. Status always stays beside the
/// provider identity; only compact terminal summaries center it against a card.
struct ProviderCardHeader: View {
    /// Display strings for the header, with no SwiftUI attached so each rule is
    /// directly assertable and the two surfaces can be compared value-to-value.
    /// Internal (not private) for that reason.
    struct Content: Equatable {
        let title: String
        let subtitle: String
        let statusText: String

        init(snapshot: ProviderSnapshot) {
            title = snapshot.title
            subtitle = snapshot.updatedText
            statusText = ProviderCardPresentation.statusText(for: snapshot)
        }
    }

    let snapshot: ProviderSnapshot
    var showsDisclosureChevron: Bool = false

    var content: Content { Content(snapshot: snapshot) }

    var body: some View {
        HStack(spacing: 7) {
            ProviderLogoView(kind: snapshot.logoKind, size: 17, foregroundColor: snapshot.accentColor)
                .accessibilityIdentifier("provider-card-header-logo")

            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .accessibilityIdentifier("provider-card-header-title")
                Text(content.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            ProviderCardStatusLabel(snapshot: snapshot)
                .accessibilityIdentifier("provider-card-header-status")

            if showsDisclosureChevron {
                CardDisclosureChevron()
            }
        }
    }
}
