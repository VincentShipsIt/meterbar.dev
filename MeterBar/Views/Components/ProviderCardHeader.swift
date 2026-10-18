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
/// panel is already the thing it discloses. The status chip appears only for a
/// broken or out-of-date connection (see
/// `ProviderCardPresentation.connectionStatusText`); a working provider shows
/// none. It stays beside the provider identity when present; only compact
/// terminal summaries center it against a card.
struct ProviderCardHeader: View {
    /// Display strings for the header, with no SwiftUI attached so each rule is
    /// directly assertable and the two surfaces can be compared value-to-value.
    /// Internal (not private) for that reason.
    struct Content: Equatable {
        let title: String
        let subtitle: String
        /// `nil` while the connection is fine, so a working provider carries no chip.
        let statusText: String?
        let planLabel: String?

        init(snapshot: ProviderSnapshot) {
            title = snapshot.title
            subtitle = snapshot.updatedText
            statusText = ProviderCardPresentation.connectionStatusText(for: snapshot)
            planLabel = snapshot.planLabel
        }
    }

    let snapshot: ProviderSnapshot
    var showsDisclosureChevron: Bool = false
    var showsLiveAccount: Bool = false

    var content: Content { Content(snapshot: snapshot) }

    /// Fixed metrics for the header grid. The identity column is the name over
    /// the refresh subtitle, so the subtitle's leading edge is the title's x
    /// (logo column + gap) and lines up with the rows under the card. Status,
    /// the live chip, and the chevron stay in that same row, top-aligned with
    /// the name. Hanging the subtitle under the whole row wraps the name and
    /// status onto a second line and drops the wider refresh text out of the
    /// row's width.
    enum Layout {
        static let logoSize: CGFloat = 17
        static let columnSpacing: CGFloat = 7
        static let titleSpacing: CGFloat = 5
        /// Gap between the provider name and the refresh subtitle.
        static let rowSpacing: CGFloat = 1
        /// Subtitle indent: the logo column plus its gap, i.e. the title's x.
        static let subtitleInset: CGFloat = logoSize + columnSpacing
    }

    var body: some View {
        HStack(alignment: .top, spacing: Layout.columnSpacing) {
            ProviderLogoView(kind: snapshot.logoKind, size: Layout.logoSize, foregroundColor: snapshot.accentColor)

            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
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

                Text(content.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            if showsLiveAccount {
                MeterBarChip("Live", tint: snapshot.accentColor, style: .glass)
                    .accessibilityLabel("Live CLI account")
            }

            if content.statusText != nil {
                ProviderCardStatusLabel(snapshot: snapshot)
            }

            if showsDisclosureChevron {
                CardDisclosureChevron()
            }
        }
    }
}
