import Foundation
import MeterBarShared

/// One provider's trailing-week consumption, bucketed for the hover panel.
///
/// The popover card already shows the current window — percent used, pace,
/// reset. Hovering it used to open a panel showing the same three numbers in a
/// wider box. This is the dimension the card cannot show: what the last seven
/// days actually looked like.
///
/// Built as a plain value, derived once, for the same reason as
/// ``TokenActivityGrid``: the panel is hosted in a test without a live
/// ``CostTracker``, and `body` re-runs on every hover tick, so the bucketing
/// must not live there.
///
/// Two properties are load-bearing:
///
/// - **Units never mix.** Claude, Codex and Grok are counted in tokens; Cursor
///   in requests; OpenRouter in dollars. The metric rides with the series so a
///   request count can never be printed with a `$` in front of it — the same
///   guard ``ProviderUsageLedger/dailyUSDSeries(for:)`` enforces upstream.
/// - **Unobserved days are not zero days.** The ledger providers have no
///   backfill, so a day before the first poll is unknown. Drawing it as an
///   empty bar would claim MeterBar watched a week it did not.
struct ProviderDailyUsageSeries: Equatable {
    /// What the bars are counted in. Derived from the source, never chosen by
    /// the view.
    enum Metric: Equatable {
        /// Tokens read out of local session logs.
        case tokens
        /// US dollars, as published by the provider.
        case usd
        /// Requests or credits against a plan allowance — deliberately *not*
        /// convertible to money, because no rate is published.
        case requests

        /// Short unit word for the panel's summary line.
        var summaryNoun: String {
            switch self {
            case .tokens: return "tokens"
            case .usd: return "spent"
            case .requests: return "requests"
            }
        }

        /// Formats one day's figure for a tooltip or accessibility value.
        func formatted(_ value: Double) -> String {
            switch self {
            case .tokens: return UsageFormat.tokens(Int(value.rounded()))
            case .usd: return UsageFormat.cost(value)
            case .requests:
                let count = Int(value.rounded())
                return "\(count) request\(count == 1 ? "" : "s")"
            }
        }
    }

    /// One bucket. Always a whole day, always present even when empty — the
    /// panel draws one bar per element and relies on the count being stable.
    struct Day: Identifiable, Equatable {
        let date: Date

        /// The day's figure in the series' `metric`. Zero for a measured-quiet
        /// day and for an unobserved one; `isMeasured` is what tells them apart.
        let value: Double

        /// False when the source cannot speak for this day at all. Only the
        /// poll-and-accumulate providers ever produce these.
        let isMeasured: Bool

        /// Single-letter weekday for the axis, derived here rather than in
        /// `body` so no `DateFormatter` runs per hover tick.
        let weekdayLabel: String

        /// Full weekday + date, for the tooltip and the accessibility value.
        let longLabel: String

        var id: Date { date }
    }

    let service: ServiceType
    let metric: Metric

    /// Exactly `dayCount` buckets, oldest first, ending on today.
    let days: [Day]

    /// The first day the source can speak for, or `nil` when it can speak for
    /// none of them. Days in the window before this are drawn as unknown.
    let coverageStart: Date?

    /// True when the figures cover more accounts than the card that opened the
    /// panel. `DailyTokenUsage` carries no account dimension, but the popover
    /// shows one card per Claude/Codex/Grok account, so a two-account user's
    /// panel would silently show both accounts' week under one account's name.
    let isCombinedAcrossAccounts: Bool

    // MARK: - Sources

    /// Token history, for the providers that write local session logs.
    ///
    /// Every day in the window is measured: a scan re-reads the log files, so a
    /// day with no rows genuinely had no sessions.
    init(
        service: ServiceType,
        dailyUsage: [DailyTokenUsage],
        accountCount: Int = 1,
        dayCount: Int = ProviderDailyUsageSeries.defaultDayCount,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let window = Self.window(dayCount: dayCount, now: now, calendar: calendar)
        var totals: [Date: Double] = [:]
        for row in dailyUsage where row.provider == service {
            let day = calendar.startOfDay(for: row.date)
            guard window.contains(day) else { continue }
            totals[day, default: 0] += Double(max(0, row.totalTokens))
        }

        self.service = service
        self.metric = .tokens
        self.coverageStart = window.first
        self.isCombinedAcrossAccounts = accountCount > 1
        self.days = window.map { date in
            Self.makeDay(
                date: date,
                value: totals[date] ?? 0,
                isMeasured: true,
                metric: .tokens,
                calendar: calendar
            )
        }
    }

    /// Polled history, for the providers that keep no local log.
    ///
    /// Bucketed in the entry's own day boundary rather than the local one:
    /// OpenRouter's stored keys are UTC midnights, and re-bucketing them locally
    /// would shift part of every day's spend into its neighbour.
    init(
        service: ServiceType,
        ledger: ProviderUsageLedger,
        dayCount: Int = ProviderDailyUsageSeries.defaultDayCount,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let entry = ledger.entry(for: service)
        let bucketCalendar = entry?.dayBoundary.calendar(local: calendar) ?? calendar
        let window = Self.window(dayCount: dayCount, now: now, calendar: bucketCalendar)
        // No entry means the provider has never been polled, so nothing in the
        // window is observed. `.requests` is the non-money default on purpose:
        // an unknown unit must never render as dollars.
        let metric: Metric = entry.map { Self.metric(for: $0.unit) } ?? .requests
        let coverageStart = entry.map { bucketCalendar.startOfDay(for: $0.firstObservedOn) }

        var totals: [Date: Double] = [:]
        for point in ledger.dailySeries(for: service) {
            let day = bucketCalendar.startOfDay(for: point.date)
            guard window.contains(day) else { continue }
            totals[day, default: 0] += max(0, point.amount)
        }

        self.service = service
        self.metric = metric
        self.coverageStart = coverageStart
        // The ledger providers are single-account and the ledger is
        // account-blind, so the caption can never apply here.
        self.isCombinedAcrossAccounts = false
        self.days = window.map { date in
            Self.makeDay(
                date: date,
                value: totals[date] ?? 0,
                isMeasured: coverageStart.map { date >= $0 } ?? false,
                metric: metric,
                calendar: bucketCalendar
            )
        }
    }

    /// The front door: picks the source from where the provider actually keeps
    /// its history.
    ///
    /// Getting this wrong is silent rather than loud — Cursor has no token rows
    /// at all, so a token-sourced Cursor series would draw a permanently empty
    /// chart telling the user to run a scan that can never fill it.
    static func make(
        service: ServiceType,
        dailyUsage: [DailyTokenUsage],
        ledger: ProviderUsageLedger,
        accountCount: Int,
        dayCount: Int = ProviderDailyUsageSeries.defaultDayCount,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProviderDailyUsageSeries {
        if service.writesLocalTokenLogs {
            return ProviderDailyUsageSeries(
                service: service,
                dailyUsage: dailyUsage,
                accountCount: accountCount,
                dayCount: dayCount,
                now: now,
                calendar: calendar
            )
        }
        return ProviderDailyUsageSeries(
            service: service,
            ledger: ledger,
            dayCount: dayCount,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Derived

    /// The window the panel draws. Seven days is a week the user can hold in
    /// their head, and it is as many bars as a 340pt panel fits without the
    /// columns turning into hairlines.
    static let defaultDayCount = 7

    var totalValue: Double { days.reduce(0) { $0 + $1.value } }

    /// The tallest day, which every bar is scaled against.
    var peakValue: Double { days.map(\.value).max() ?? 0 }

    /// False when there is nothing worth drawing — either no scan has run or the
    /// provider has never been polled. The panel shows an empty state instead of
    /// seven flat bars, which would read as a genuinely quiet week.
    var hasHistory: Bool { days.contains { $0.isMeasured && $0.value > 0 } }

    /// True when the source could speak for part of the window but not all of
    /// it, which is worth a one-line caption rather than an empty state.
    var hasPartialCoverage: Bool { days.contains { !$0.isMeasured } }

    var formattedTotal: String { metric.formatted(totalValue) }

    /// Trailing total on the hover-panel header.
    ///
    /// `formattedTotal` already includes the unit noun for `.requests`
    /// ("31,258 requests"), so appending `summaryNoun` printed
    /// "requests requests". Dollars and compact token counts still need the
    /// noun because those formatters emit just `$1.20` / `1.2K`.
    var headerTotalText: String {
        switch metric {
        case .requests:
            return formattedTotal
        case .tokens, .usd:
            return "\(formattedTotal) \(metric.summaryNoun)"
        }
    }

    var accessibilityLabel: String {
        "\(service.shortName) usage for the last \(days.count) days"
    }

    var accessibilityValue: String {
        guard hasHistory else { return "No history yet" }
        let measured = days.filter(\.isMeasured)
        return ([formattedTotal + " total"] + measured.map { day in
            "\(day.longLabel): \(metric.formatted(day.value))"
        }).joined(separator: ", ")
    }

    // MARK: - Building

    /// `dayCount` day-starts, oldest first, ending on today.
    private static func window(dayCount: Int, now: Date, calendar: Calendar) -> [Date] {
        let normalized = max(1, dayCount)
        let today = calendar.startOfDay(for: now)
        return (0..<normalized).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
    }

    private static func makeDay(
        date: Date,
        value: Double,
        isMeasured: Bool,
        metric: Metric,
        calendar: Calendar
    ) -> Day {
        Day(
            date: date,
            value: value,
            isMeasured: isMeasured,
            weekdayLabel: ProviderDailyUsageFormat.weekdayInitial(date, calendar: calendar),
            longLabel: ProviderDailyUsageFormat.weekdayAndDate(date, calendar: calendar)
        )
    }

    private static func metric(for unit: ProviderUsageUnit) -> Metric {
        switch unit {
        case .usd: return .usd
        case .requests: return .requests
        }
    }
}

/// Cached formatters for the sparkline axis.
///
/// Same reason the dashboard chart keeps `DashboardDateFormat`: building a
/// `DateFormatter` is expensive, and these run once per bucket per panel
/// presentation.
enum ProviderDailyUsageFormat {
    private static let weekdayInitialFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter
    }()

    private static let weekdayAndDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return formatter
    }()

    /// The formatters date in the *user's* zone by default, which is wrong for a
    /// UTC-bucketed series: a UTC midnight would print as the previous evening's
    /// weekday for anyone west of Greenwich. Both take the bucket calendar's
    /// zone so the label always names the day the bar actually is.
    static func weekdayInitial(_ date: Date, calendar: Calendar) -> String {
        weekdayInitialFormatter.timeZone = calendar.timeZone
        return weekdayInitialFormatter.string(from: date)
    }

    static func weekdayAndDate(_ date: Date, calendar: Calendar) -> String {
        weekdayAndDateFormatter.timeZone = calendar.timeZone
        return weekdayAndDateFormatter.string(from: date)
    }
}
