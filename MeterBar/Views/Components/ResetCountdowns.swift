import SwiftUI
import MeterBarShared

// Reset-countdown components shared by the popover and dashboard.
// Extracted from MenuBarView.swift.

struct ResetCountdownWindow: Identifiable {
    let id: String
    let title: String
    let limit: UsageLimit
}

/// Shared tick schedule for all reset-countdown labels. Anchoring to a fixed
/// reference date (a whole-minute boundary) keeps every label in phase so ticks
/// land on real minute boundaries instead of drifting per-view. A 60s cadence is
/// sufficient since the displayed granularity is minutes.
enum ResetCountdownSchedule {
    static let anchor = Date(timeIntervalSinceReferenceDate: 0)
    static let interval: TimeInterval = 60
}

struct ResetCountdownLabel: View {
    let title: String?
    let limit: UsageLimit
    var font: Font = .caption
    var foregroundColor: Color = .secondary
    var iconSize: CGFloat = 10

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            Group {
                if let text = Self.counterText(title: title, limit: limit, now: timeline.date) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: iconSize, weight: .semibold))
                        Text(text)
                            .font(font)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .numericRefreshTransition(value: text, reduceMotion: reduceMotion)
                    }
                    .foregroundColor(foregroundColor)
                    .help(text)
                }
            }
        }
    }

    static func counterText(title: String?, limit: UsageLimit, now: Date) -> String? {
        guard let countdown = limit.resetCountdownText(now: now) else { return nil }
        if countdown == "now" {
            return title.map { "\($0) reset due" } ?? "Reset due"
        }
        return title.map { "\($0) reset in \(countdown)" } ?? "Resets in \(countdown)"
    }
}

struct NextResetCountdownLabel: View {
    let windows: [ResetCountdownWindow]
    var font: Font = .caption
    var foregroundColor: Color = .secondary
    var iconSize: CGFloat = 10

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// How long after a window's reset time we keep showing "reset due" before
    /// treating the data as stale and hiding the label (until a refresh repopulates
    /// a future reset time). Prevents a perpetual "reset due" when a provider goes offline.
    static let resetDueGracePeriod: TimeInterval = 5 * 60

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            Group {
                if let window = Self.selectNextWindow(windows, now: timeline.date),
                   let text = ResetCountdownLabel.counterText(
                       title: window.title,
                       limit: window.limit,
                       now: timeline.date
                   ) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: iconSize, weight: .semibold))
                        Text(text)
                            .font(font)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .numericRefreshTransition(value: text, reduceMotion: reduceMotion)
                    }
                    .foregroundColor(foregroundColor)
                    .help(text)
                }
            }
        }
    }

    /// Picks the window each provider card should count down to: the soonest
    /// upcoming reset, or — if every window has already passed — the most recently
    /// due one, but only while it is within `gracePeriod` of now. Beyond that the
    /// data is treated as stale and `nil` is returned so the label hides instead of
    /// showing "reset due" indefinitely.
    static func selectNextWindow(
        _ windows: [ResetCountdownWindow],
        now: Date,
        gracePeriod: TimeInterval = resetDueGracePeriod
    ) -> ResetCountdownWindow? {
        let candidates = windows.compactMap { window -> (window: ResetCountdownWindow, seconds: TimeInterval)? in
            guard let seconds = window.limit.secondsUntilReset(now: now) else { return nil }
            return (window, seconds)
        }

        let futureCandidates = candidates.filter { $0.seconds > 0 }
        if let next = futureCandidates.min(by: { $0.seconds < $1.seconds }) {
            return next.window
        }

        if let mostRecent = candidates.max(by: { $0.seconds < $1.seconds }),
           mostRecent.seconds >= -gracePeriod {
            return mostRecent.window
        }

        return nil
    }
}

struct BlockingLimitResetCounter: View {
    let windows: [ResetCountdownWindow]
    let accentColor: Color

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            let blockingWindow = Self.selectBlockingWindow(windows, now: timeline.date)
            let title = Self.titleText(for: blockingWindow, in: windows)
            let counter = Self.counterText(for: blockingWindow, now: timeline.date)
            let detail = Self.detailText(for: blockingWindow, in: windows)

            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "hourglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accentColor)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(counter)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .numericRefreshTransition(value: counter, reduceMotion: reduceMotion)
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .help("\(title) \(counter)")
        }
    }

    /// Selects the exhausted window that actually gates usage — the exhausted
    /// window with the latest known reset time (or the most recently passed one
    /// within the grace period). If any exhausted window has no known reset time,
    /// returns `nil` so the card shows a plain "exhausted" state without an
    /// unreliable countdown rather than guessing.
    static func selectBlockingWindow(
        _ windows: [ResetCountdownWindow],
        now: Date,
        gracePeriod: TimeInterval = NextResetCountdownLabel.resetDueGracePeriod
    ) -> ResetCountdownWindow? {
        let exhaustedWindows = windows.filter { $0.limit.isAtLimit }
        guard !exhaustedWindows.isEmpty else { return nil }

        let candidates = exhaustedWindows.compactMap { w -> (window: ResetCountdownWindow, seconds: TimeInterval)? in
            guard let seconds = w.limit.secondsUntilReset(now: now) else { return nil }
            return (w, seconds)
        }

        guard candidates.count == exhaustedWindows.count else { return nil }

        let futureCandidates = candidates.filter { $0.seconds > 0 }
        if let blocking = futureCandidates.max(by: { $0.seconds < $1.seconds }) {
            return blocking.window
        }

        if let mostRecent = candidates.max(by: { $0.seconds < $1.seconds }),
           mostRecent.seconds >= -gracePeriod {
            return mostRecent.window
        }

        return nil
    }

    static func titleText(for window: ResetCountdownWindow?, in windows: [ResetCountdownWindow]) -> String {
        if let window {
            return "\(window.title) reset"
        }

        let exhaustedCount = windows.filter { $0.limit.isAtLimit }.count
        return exhaustedCount > 1 ? "Limits exhausted" : "Limit exhausted"
    }

    static func counterText(for window: ResetCountdownWindow?, now: Date) -> String {
        guard let window,
              let countdown = window.limit.resetCountdownText(now: now) else {
            return "Reset time unavailable"
        }

        return countdown == "now" ? "due now" : "in \(countdown)"
    }

    static func detailText(for window: ResetCountdownWindow?, in windows: [ResetCountdownWindow]) -> String {
        guard window != nil else {
            return "Usage is unavailable until the reset is reported."
        }

        let exhaustedCount = windows.filter { $0.limit.isAtLimit }.count
        return exhaustedCount > 1
            ? "Usage resumes after exhausted limits reset."
            : "Usage is unavailable until this limit resets."
    }
}

/// Condensed single-row variant of `BlockingLimitResetCounter` for the popover
/// card when a provider's quota is exhausted — one line (icon + title/counter +
/// detail) so the exhausted card can shrink instead of reserving full height.
struct CompactBlockingLimitResetRow: View {
    let windows: [ResetCountdownWindow]
    let accentColor: Color

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            let blockingWindow = BlockingLimitResetCounter.selectBlockingWindow(windows, now: timeline.date)
            let title = BlockingLimitResetCounter.titleText(for: blockingWindow, in: windows)
            let counter = BlockingLimitResetCounter.counterText(for: blockingWindow, now: timeline.date)
            let detail = BlockingLimitResetCounter.detailText(for: blockingWindow, in: windows)

            HStack(alignment: .center, spacing: 7) {
                Image(systemName: "hourglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(title) \(counter)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .numericRefreshTransition(value: counter, reduceMotion: reduceMotion)
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(title) \(counter)")
        }
    }
}
