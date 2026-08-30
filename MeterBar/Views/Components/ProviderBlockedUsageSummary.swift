import MeterBarShared
import SwiftUI

/// Pure copy rules for the blocked summary row.
///
/// The row used to concatenate three independently-derived phrases — the auth
/// notice, `BlockingLimitResetCounter.titleText`, and its `counterText` — with
/// nothing checking whether they said the same thing twice. A logged-out account
/// with no reported reset rendered "Login required ⏳ Limit exhausted Reset time
/// unavailable": three restatements of one fact, wide enough to squeeze the
/// account title down to a single character. Deciding here, off the view, keeps
/// the collapse assertable without hosting a render.
enum ProviderBlockedSummaryPresentation {
    struct Content: Equatable {
        /// Short status word shown beside the title. Always present.
        var statusText: String
        /// Countdown line, or `nil` when there is no countdown worth showing.
        var resetText: String?

        /// - Parameter title: the account title *as drawn*, or `nil` when the row
        ///   suppresses it because an enclosing card already names the account.
        ///   Passing it unconditionally made VoiceOver say the name twice where
        ///   sighted users saw it once.
        func accessibilityLabel(title: String?) -> String {
            [title, statusText, resetText].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// - Parameter hasAuthNotice: a login/stale/attention overlay explains the
    ///   block better than the countdown can, and the two read as contradictory
    ///   instructions side by side ("sign in" versus "wait 3h"), so the notice
    ///   wins outright.
    static func content(
        statusText: String,
        window: ResetCountdownWindow?,
        now: Date,
        format: ResetTimeFormat = .countdown,
        hasAuthNotice: Bool = false,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> Content {
        Content(
            statusText: statusText,
            resetText: resetText(
                window: window,
                now: now,
                format: format,
                hasAuthNotice: hasAuthNotice,
                locale: locale,
                timeZone: timeZone
            )
        )
    }

    private static func resetText(
        window: ResetCountdownWindow?,
        now: Date,
        format: ResetTimeFormat,
        hasAuthNotice: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        guard !hasAuthNotice, let window else { return nil }

        let counter = BlockingLimitResetCounter.counterText(
            for: window,
            now: now,
            format: format,
            locale: locale,
            timeZone: timeZone
        )
        // The counter narrates its own failure when the provider reported no
        // reset date. Nothing actionable survives that, so drop the line rather
        // than print an apology next to an hourglass.
        guard counter != BlockingLimitResetCounter.unavailableCounterText else { return nil }

        return "\(BlockingLimitResetCounter.titleText(for: window, in: [window])) \(counter)"
    }
}

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
    var showsLiveAccount: Bool = false
    var resetTimeFormat: ResetTimeFormat = .countdown

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            let content = ProviderBlockedSummaryPresentation.content(
                statusText: ProviderCardPresentation.statusText(for: snapshot),
                window: BlockingLimitResetCounter.selectBlockingWindow(snapshot.resetWindows, now: timeline.date),
                now: timeline.date,
                format: resetTimeFormat,
                hasAuthNotice: snapshot.authNotice != nil
            )

            // The countdown stays below the title, while status gets its own
            // trailing rail centered against the complete summary. Sharing all
            // three on one line made the title collapse at popover width.
            HStack(spacing: density == .popoverCard ? MeterBarTheme.Spacing.sm : MeterBarTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.xs) {
                    if showsTitle {
                        HStack(spacing: density == .popoverCard ? MeterBarTheme.Spacing.sm : MeterBarTheme.Spacing.md) {
                            ProviderLogoView(
                                kind: snapshot.logoKind,
                                size: density == .popoverCard ? 17 : 16,
                                foregroundColor: snapshot.accentColor
                            )
                            Text(snapshot.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                        }
                    }

                    if let resetText = content.resetText {
                        Label(resetText, systemImage: "hourglass")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(snapshot.accentColor)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .numericRefreshTransition(value: resetText, reduceMotion: reduceMotion)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsLiveAccount {
                    MeterBarChip("Live", tint: snapshot.accentColor, style: .glass)
                        .accessibilityLabel("Live CLI account")
                }

                ProviderCardStatusLabel(snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(content.accessibilityLabel(title: showsTitle ? snapshot.title : nil))
        }
    }
}
