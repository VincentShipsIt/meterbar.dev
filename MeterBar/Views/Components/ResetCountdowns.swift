import SwiftUI
import MeterBarShared

// Reset-countdown components shared by the popover and dashboard.
// Extracted from MenuBarView.swift.

struct ResetCountdownWindow: Identifiable {
    let id: String
    let title: String
    let limit: UsageLimit

    /// One template driven by reset cadence, shared across every provider's
    /// blocked-card headline — "Monthly reset in 3d", "Weekly reset in 2d" —
    /// instead of each provider's raw window name ("Cursor Models reset in
    /// 3d"). Falls back to `title` when the provider didn't report a period
    /// kind, or reported `.unknown`, so the headline still reads as
    /// *something* rather than a blank cadence. Reuses the same
    /// `quota.title.*` keys `SnapshotLimit.localizedTitle` draws from.
    var cadenceTitle: String {
        switch limit.periodKind {
        case .monthly:
            return String(localized: "quota.title.monthly", defaultValue: "Monthly")
        case .weekly:
            return String(localized: "quota.title.weekly", defaultValue: "Weekly")
        case .daily:
            return String(localized: "quota.title.daily", defaultValue: "Daily")
        case .billing:
            return String(localized: "quota.title.billing_cycle", defaultValue: "Billing cycle")
        case .session:
            return String(localized: "quota.title.session", defaultValue: "Session")
        case .unknown, nil:
            return title
        }
    }
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
    let font: Font
    let foregroundColor: Color
    let iconSize: CGFloat
    let usesPopoverPreference: Bool

    @ObservedObject private var preferences: MenuBarDisplayPreferencesStore

    init(
        title: String?,
        limit: UsageLimit,
        font: Font = .caption,
        foregroundColor: Color = .secondary,
        iconSize: CGFloat = 10,
        usesPopoverPreference: Bool = false,
        preferences: MenuBarDisplayPreferencesStore? = nil
    ) {
        self.title = title
        self.limit = limit
        self.font = font
        self.foregroundColor = foregroundColor
        self.iconSize = iconSize
        self.usesPopoverPreference = usesPopoverPreference
        _preferences = ObservedObject(wrappedValue: preferences ?? .shared)
    }

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            Group {
                if let text = Self.counterText(
                    title: title,
                    limit: limit,
                    format: usesPopoverPreference ? preferences.resetTimeFormat : .countdown,
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
                }
            }
        }
    }

    static func counterText(
        title: String?,
        limit: UsageLimit,
        format: ResetTimeFormat = .countdown,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let resetTime = limit.resetTime,
              let seconds = limit.secondsUntilReset(now: now) else { return nil }
        if seconds <= 0 {
            if let title {
                return String(
                    localized: "reset.titled_due",
                    defaultValue: "\(title) reset due",
                    comment: "Reset countdown that is due. The variable is the quota window title."
                )
            }
            return String(localized: "reset.due", defaultValue: "Reset due", comment: "Reset is due now.")
        }

        switch format {
        case .countdown:
            let countdown = LocalizedUsageFormat.countdown(seconds: seconds, locale: locale)
            if let title {
                return String(
                    localized: "reset.titled_in",
                    defaultValue: "\(title) reset in \(countdown)",
                    locale: locale,
                    comment: "Reset countdown. The first variable is the quota title; the second is a duration."
                )
            }
            return String(
                localized: "reset.in",
                defaultValue: "Resets in \(countdown)",
                locale: locale,
                comment: "Reset countdown. The variable is a localized duration."
            )
        case .clock:
            let clock = formattedClockTime(resetTime, locale: locale, timeZone: timeZone)
            if let title {
                return String(
                    localized: "reset.titled_at",
                    defaultValue: "\(title) resets at \(clock)",
                    locale: locale,
                    comment: "Reset clock time. The first variable is the quota title; the second is a localized time."
                )
            }
            return String(
                localized: "reset.at",
                defaultValue: "Resets at \(clock)",
                locale: locale,
                comment: "Reset clock time. The variable is a localized time."
            )
        }
    }

    static func formattedClockTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct NextResetCountdownLabel: View {
    let windows: [ResetCountdownWindow]
    var font: Font = .caption
    var foregroundColor: Color = .secondary
    var iconSize: CGFloat = 10
    /// Countdown vs. clock-time rendering. The caller resolves this from
    /// `MenuBarDisplayPreferencesStore` and passes the value in — the same
    /// division of responsibility `BlockingLimitResetCounter.format` uses —
    /// rather than this view observing the store itself, since its one caller
    /// (`ProviderStatusCard`) already resolves the preference once per render
    /// for that sibling component.
    var format: ResetTimeFormat = .countdown

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// How long after a window's reset time we keep showing "reset due" before
    /// treating the data as stale and hiding the label (until a refresh repopulates
    /// a future reset time). Prevents a perpetual "reset due" when a provider goes offline.
    static let resetDueGracePeriod = ProviderBlockingPolicy.resetDueGracePeriod

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            Group {
                if let window = Self.selectNextWindow(windows, now: timeline.date),
                   let text = Self.counterText(for: window, now: timeline.date, format: format) {
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
                }
            }
        }
    }

    /// Reset text for the selected window, titled by its reset cadence (e.g.
    /// "Monthly reset in 3d") rather than the raw window name — matching
    /// `BlockingLimitResetCounter.titleText`'s blocked-card headline so the
    /// popover's healthy- and blocked-card reset lines read the same way.
    static func counterText(
        for window: ResetCountdownWindow,
        now: Date,
        format: ResetTimeFormat = .countdown,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        ResetCountdownLabel.counterText(
            title: window.cadenceTitle,
            limit: window.limit,
            format: format,
            now: now,
            locale: locale,
            timeZone: timeZone
        )
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
    var format: ResetTimeFormat = .countdown

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
            let blockingWindow = Self.selectBlockingWindow(windows, now: timeline.date)
            let title = Self.titleText(for: blockingWindow, in: windows)
            let counter = Self.counterText(for: blockingWindow, now: timeline.date, format: format)
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
        let candidates = windows.map {
            ProviderBlockingCandidate(id: $0.id, role: .weekly, limit: $0.limit)
        }
        guard let headline = ProviderBlockingPolicy.headline(
            from: candidates.filter { $0.limit.isAtLimit },
            now: now,
            gracePeriod: gracePeriod
        ), headline.visibleResetTime != nil else {
            return nil
        }
        return windows.first { $0.id == headline.blocker.id }
    }

    static func titleText(for window: ResetCountdownWindow?, in windows: [ResetCountdownWindow]) -> String {
        if let window {
            return String(
                localized: "reset.window_reset",
                defaultValue: "\(window.cadenceTitle) reset",
                comment: "Blocking quota title. The variable is the reset cadence (Monthly, Weekly, Daily, ...)."
            )
        }

        let exhaustedCount = windows.filter { $0.limit.isAtLimit }.count
        return String(
            localized: "reset.exhausted_limits",
            defaultValue: "\(exhaustedCount) limits exhausted",
            comment: "Blocking quota title. The variable is the number of exhausted limits."
        )
    }

    /// Returned whenever no reset instant is known. Callers that can omit the
    /// countdown entirely compare against this rather than re-deriving the
    /// "is there anything to count down to?" test from the window.
    static var unavailableCounterText: String {
        String(
            localized: "reset.time_unavailable",
            defaultValue: "Reset time unavailable",
            comment: "Shown when a provider has not reported a reset time."
        )
    }

    static func counterText(
        for window: ResetCountdownWindow?,
        now: Date,
        format: ResetTimeFormat = .countdown,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let window,
              let seconds = window.limit.secondsUntilReset(now: now) else {
            return unavailableCounterText
        }

        if seconds <= 0 {
            return String(localized: "reset.due_now", defaultValue: "due now", comment: "Reset is due now.")
        }

        switch format {
        case .countdown:
            let countdown = LocalizedUsageFormat.countdown(seconds: seconds, locale: locale)
            return String(
                localized: "reset.counter_in",
                defaultValue: "in \(countdown)",
                locale: locale,
                comment: "Condensed reset countdown. The variable is a localized duration."
            )
        case .clock:
            guard let resetTime = window.limit.resetTime else { return unavailableCounterText }
            let clock = ResetCountdownLabel.formattedClockTime(resetTime, locale: locale, timeZone: timeZone)
            return String(
                localized: "reset.counter_at",
                defaultValue: "at \(clock)",
                locale: locale,
                comment: "Condensed reset time. The variable is a localized clock time."
            )
        }
    }

    static func detailText(for window: ResetCountdownWindow?, in windows: [ResetCountdownWindow]) -> String {
        guard window != nil else {
            return String(
                localized: "reset.unavailable_until_reported",
                defaultValue: "Usage is unavailable until the reset is reported.",
                comment: "Detail shown when an exhausted quota has no known reset time."
            )
        }

        let exhaustedCount = windows.filter { $0.limit.isAtLimit }.count
        return String(
            localized: "reset.exhausted_detail",
            defaultValue: "Usage resumes after \(exhaustedCount) exhausted limits reset.",
            comment: "Blocking quota detail. The variable is the number of exhausted limits."
        )
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
        }
    }
}
