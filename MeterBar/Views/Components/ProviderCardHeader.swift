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
        let planLabel: String?

        init(snapshot: ProviderSnapshot) {
            title = snapshot.title
            subtitle = snapshot.updatedText
            statusText = ProviderCardPresentation.statusText(for: snapshot)
            planLabel = snapshot.planLabel
        }
    }

    let snapshot: ProviderSnapshot
    var showsDisclosureChevron: Bool = false
    var showsLiveAccount: Bool = false

    var content: Content { Content(snapshot: snapshot) }

    /// Fixed metrics for the header grid. Everything on the top row shares one
    /// centre line, and the subtitle hangs from the title's leading edge, so
    /// the logo, title, plan chip, status badge and chevron can never drift
    /// against a two-line block the way a vertically centred layout did.
    enum Layout {
        static let logoSize: CGFloat = 17
        static let columnSpacing: CGFloat = 7
        static let titleSpacing: CGFloat = 5
        static let rowSpacing: CGFloat = 2
        /// Subtitle indent: the logo column plus its gap, i.e. the title's x.
        static let subtitleInset: CGFloat = logoSize + columnSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack(alignment: .center, spacing: Layout.columnSpacing) {
                ProviderLogoView(kind: snapshot.logoKind, size: Layout.logoSize, foregroundColor: snapshot.accentColor)

                HStack(spacing: Layout.titleSpacing) {
                    Text(content.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let plan = content.planLabel {
                        MeterBarChip(plan, tint: snapshot.accentColor)
                            .accessibilityLabel("\(plan) plan")
                    }
                }

                Spacer(minLength: 0)

                if showsLiveAccount {
                    MeterBarChip("Live", tint: snapshot.accentColor, style: .glass)
                        .accessibilityLabel("Live CLI account")
                }

                ProviderCardStatusLabel(snapshot: snapshot)

                if showsDisclosureChevron {
                    CardDisclosureChevron()
                }
            }

            Text(content.subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .padding(.leading, Layout.subtitleInset)
        }
    }
}
