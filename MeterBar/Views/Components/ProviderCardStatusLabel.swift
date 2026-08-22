import MeterBarShared
import SwiftUI

/// Status word on a provider card header or overview row.
///
/// Every state uses the same uppercase `MeterBarChip` treatment. Keeping the
/// surface stable prevents a provider card from changing its visual grammar
/// when it crosses a quota threshold; only the label and semantic tint change.
struct ProviderCardStatusLabel: View {
    let text: String
    let color: Color

    init(snapshot: ProviderSnapshot) {
        text = ProviderCardPresentation.statusText(for: snapshot)
        color = ProviderCardPresentation.statusColor(for: snapshot)
    }

    init(band: QuotaBand) {
        text = band.shortLabel
        color = band.color
    }

    var body: some View {
        MeterBarChip(text.uppercased(), tint: color, style: .flat)
    }
}
