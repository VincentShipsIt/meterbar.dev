import MeterBarShared
import SwiftUI

/// Collapsed "you are blocked until this reset" summary shared by the popover
/// provider card and Settings → Providers usage section.
///
/// When weekly (or another provider-blocking window) is exhausted, shorter
/// gauges are non-actionable. Both surfaces must show the same status +
/// hourglass reset line instead of drifting into a red bar in one place and a
/// countdown chip in the other.
struct ProviderBlockedUsageSummary: View {
    enum Density {
        /// Popover card header row (compact type, logo + title).
        case popoverCard
        /// Settings Usage panel (regular type, optional multi-account title).
        case settings
    }

    let snapshot: ProviderSnapshot
    var density: Density = .popoverCard
    var showsTitle: Bool = true
    var resetTimeFormat: ResetTimeFormat = .countdown

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            let blockingWindow = BlockingLimitResetCounter.selectBlockingWindow(
                snapshot.resetWindows,
                now: timeline.date
            )
            let title = BlockingLimitResetCounter.titleText(
                for: blockingWindow,
                in: snapshot.resetWindows
            )
            let counter = BlockingLimitResetCounter.counterText(
                for: blockingWindow,
                now: timeline.date,
                format: resetTimeFormat
            )
            let statusText = ProviderCardPresentation.statusText(for: snapshot)
            let statusColor = ProviderCardPresentation.statusColor(for: snapshot)

            HStack(spacing: density == .popoverCard ? 7 : 10) {
                if showsTitle {
                    ProviderLogoView(
                        kind: snapshot.logoKind,
                        size: density == .popoverCard ? 17 : 16,
                        foregroundColor: snapshot.accentColor
                    )
                    Text(snapshot.title)
                        .font(density == .popoverCard ? .subheadline : .subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Label("\(title) \(counter)", systemImage: "hourglass")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(snapshot.accentColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: true, vertical: false)
                    .numericRefreshTransition(value: counter, reduceMotion: reduceMotion)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(snapshot.title), \(statusText), \(title) \(counter)"
            )
        }
    }
}
