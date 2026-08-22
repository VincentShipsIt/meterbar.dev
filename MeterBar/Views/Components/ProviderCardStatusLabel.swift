import MeterBarShared
import SwiftUI

/// Status word on a provider card header or overview row.
///
/// Amber and red bands (plus login/attention overlays) render as uppercase
/// `MeterBarChip`s; healthy and subdued states stay plain semibold text so a
/// wall of green pills does not compete with the quota bars below.
struct ProviderCardStatusLabel: View {
    let snapshot: ProviderSnapshot

    private var text: String {
        ProviderCardPresentation.statusText(for: snapshot)
    }

    private var color: Color {
        ProviderCardPresentation.statusColor(for: snapshot)
    }

    var body: some View {
        if ProviderCardPresentation.statusUsesChip(for: snapshot) {
            MeterBarChip(text.uppercased(), tint: color, style: .flat)
        } else {
            Text(text)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(color)
                .lineLimit(1)
        }
    }
}
