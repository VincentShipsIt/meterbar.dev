import SwiftUI

/// The "Fable 5 — Active / Last seen / No activity" strip on a provider card.
///
/// Its own view because the row is time-driven: the enclosing `TimelineView`
/// re-evaluates every 60s, and keeping that ticker scoped to this row means a
/// minute boundary does not invalidate the rest of the card.
struct ProviderCardFableActivityRow: View {
    let activity: FableSessionCardActivity

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let status = activity.status(now: context.date)

            HStack(spacing: 7) {
                Label("Fable 5", systemImage: "sparkles")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                statusLabel(status)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                ProviderCardPresentation.fableActivityAccessibilityLabel(activity, status: status)
            )
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: FableSessionCardActivity.Status) -> some View {
        switch status {
        case .active:
            Label("Active", systemImage: "circle.fill")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(MeterBarTheme.success)
        case .recent:
            if let lastObservedAt = activity.session?.lastObservedAt {
                HStack(spacing: 3) {
                    Text("Last seen")
                    Text(lastObservedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        case .noActivity:
            Text("No activity")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
