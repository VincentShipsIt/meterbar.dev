import MeterBarShared
import SwiftUI

/// Limits card order. Focus is for scrolling, not ranking — pinning the
/// selected provider reshuffled Overview vs Limits every time a card was
/// clicked.
enum DashboardLimitsLayout {
    static func orderedSnapshots(
        _ snapshots: [ProviderSnapshot],
        focusedProviderID _: ProviderSnapshot.ID?
    ) -> [ProviderSnapshot] {
        snapshots
    }
}

/// Full-width stacked quota cards — the deep inspection surface. Overview stays
/// a glanceable summary; Limits gives every window room to breathe.
struct DashboardLimitsSection: View {
    let snapshots: [ProviderSnapshot]
    let focusedProviderID: ProviderSnapshot.ID?
    let scrollProxy: ScrollViewProxy

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
            if snapshots.isEmpty {
                DashboardCard(title: "No Quota Windows") {
                    Text("Enable providers in Settings to show quota windows.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: MeterBarTheme.Spacing.md) {
                    ForEach(DashboardLimitsLayout.orderedSnapshots(
                        snapshots,
                        focusedProviderID: focusedProviderID
                    )) { snapshot in
                        ProviderStatusCard(
                            snapshot: snapshot,
                            limitDensity: .regular,
                            badgeStyle: .regular,
                            tilePadding: .standard
                        )
                        .id(snapshot.id)
                    }
                }
                .onAppear {
                    scrollToFocusedProvider()
                }
                .onChange(of: focusedProviderID) { _, _ in
                    scrollToFocusedProvider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollToFocusedProvider() {
        guard let focusedProviderID else { return }
        scrollProxy.scrollTo(focusedProviderID, anchor: .top)
    }
}
