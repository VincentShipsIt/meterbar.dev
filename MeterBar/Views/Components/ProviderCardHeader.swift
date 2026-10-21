import MeterBarShared
import SwiftUI

/// The identity row shared by `ProviderStatusCard` and the hover detail panel.
///
/// Both surfaces hand-rolled their own header and the two drifted: the panel
/// used a larger logo and title, labelled itself with the service name where the
/// card showed the refresh time, and dropped the status word entirely — so
/// hovering a card replaced it with something that read like a different
/// provider, and a logged-out account looked healthy the moment the pointer
/// landed on it. One component keeps them identical. The card carries no
/// disclosure chevron: the whole card is the control, and hovering it opens the
/// panel. The status chip appears only for a broken or out-of-date connection (see
/// `ProviderCardPresentation.connectionStatusText`); a successful answer without
/// quota can instead show a neutral idle state. It stays beside the provider identity when present; only compact
/// terminal summaries center it against a card.
struct ProviderCardHeader: View {
    /// Display strings for the header, with no SwiftUI attached so each rule is
    /// directly assertable and the two surfaces can be compared value-to-value.
    /// Internal (not private) for that reason.
    struct Content: Equatable {
        let title: String
        let subtitle: String
        /// No chip for working quota; an idle answer may carry a neutral state.
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
    var showsLiveAccount: Bool = false

    var content: Content { Content(snapshot: snapshot) }

    /// Name and badges share the top row. The subtitle spans the row below,
    /// indented to the name, so a long plan cannot truncate the explanation.
    enum Layout {
        static let logoSize: CGFloat = 17
        static let columnSpacing: CGFloat = 7
        static let badgeSpacing: CGFloat = 5
        /// Gap between the provider name and the refresh subtitle.
        static let rowSpacing: CGFloat = 1
        /// Subtitle indent: the logo column plus its gap, i.e. the title's x.
        static let subtitleInset: CGFloat = logoSize + columnSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack(alignment: .top, spacing: Layout.columnSpacing) {
                ProviderLogoView(
                    kind: snapshot.logoKind,
                    size: Layout.logoSize,
                    foregroundColor: snapshot.accentColor
                )
                Text(content.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(alignment: .top, spacing: Layout.badgeSpacing) {
                    if let plan = content.planLabel {
                        MeterBarChip(plan, tint: snapshot.accentColor)
                            .accessibilityLabel("\(plan) plan")
                    }
                    if showsLiveAccount {
                        MeterBarChip("Live", tint: snapshot.accentColor, style: .glass)
                            .accessibilityLabel("Live CLI account")
                    }
                    if content.statusText != nil {
                        ProviderCardStatusLabel(snapshot: snapshot)
                    }
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
