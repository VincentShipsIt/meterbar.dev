import Foundation
import MeterBarShared

/// Graduated intensity bands for the token-activity heatmap.
///
/// Scaling linearly against the busiest day collapses a normal week into the
/// lightest band as soon as one outlier lands in the window, so the bands are
/// cut on the *rank* of the distinct daily totals instead of their magnitude.
/// Every band therefore carries roughly the same share of active days, and a
/// single 10M-token day only ever claims the top band for itself.
struct TokenActivityIntensityScale: Equatable {
    /// Non-zero bands. Level `0` is reserved for confirmed zero-usage days.
    static let bandCount = 4

    /// Ascending inclusive lower bound of each band in use.
    let lowerBounds: [Int]

    init(dailyTotals: [Int]) {
        let distinct = Set(dailyTotals.filter { $0 > 0 }).sorted()
        guard !distinct.isEmpty else {
            lowerBounds = []
            return
        }

        // Fewer distinct totals than bands means the extra bands would be empty;
        // a flat history should read as one quiet tone, not as saturated.
        let bands = min(Self.bandCount, distinct.count)
        lowerBounds = (0..<bands).map { band in
            distinct[min(distinct.count - 1, band * distinct.count / bands)]
        }
    }

    /// Bands this history actually populates (`0` when nothing was used).
    var usedBandCount: Int { lowerBounds.count }

    /// `0` for confirmed-zero days, otherwise `1...usedBandCount`.
    func level(for tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        guard let index = lowerBounds.lastIndex(where: { $0 <= tokens }) else { return 1 }
        return index + 1
    }
}

/// One provider's contribution to a single calendar day.
struct TokenActivityProviderTotal: Identifiable, Equatable {
    var id: ServiceType { provider }
    let provider: ServiceType
    let tokens: Int
    let costUSD: Double
}

/// One cell of the contribution calendar.
///
/// `isCovered == false` means MeterBar has no retained history for the day —
/// deliberately distinct from a covered day that simply saw no usage, so the
/// grid never implies continuous coverage it cannot back up.
struct TokenActivityDay: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let isCovered: Bool
    let totalTokens: Int
    let estimatedCostUSD: Double
    let providers: [TokenActivityProviderTotal]
    let level: Int

    var hasUsage: Bool { totalTokens > 0 }

    var accessibilityLabel: String { DashboardDateFormat.medium(date) }

    var accessibilityValue: String {
        guard isCovered else { return "No retained history" }
        guard hasUsage else { return "No tracked usage" }

        var parts = [
            "\(UsageFormat.tokens(totalTokens)) tokens",
            UsageFormat.cost(estimatedCostUSD),
            "intensity \(level) of \(TokenActivityIntensityScale.bandCount)",
        ]
        parts.append(contentsOf: providers.map {
            "\($0.provider.displayName) \(UsageFormat.tokens($0.tokens)), \(UsageFormat.cost($0.costUSD))"
        })
        return parts.joined(separator: ", ")
    }

    /// Single-line hover/focus detail rendered under the grid, where the
    /// multi-line tooltip shape would push the card's height around.
    var detailLine: String {
        let header = DashboardDateFormat.medium(date)
        guard isCovered else { return "\(header) · No retained history" }
        guard hasUsage else { return "\(header) · No tracked usage" }

        var parts = ["\(UsageFormat.tokens(totalTokens)) tokens", UsageFormat.cost(estimatedCostUSD)]
        parts.append(contentsOf: providers.map {
            "\($0.provider.displayName) \(UsageFormat.tokens($0.tokens))"
        })
        return "\(header) · \(parts.joined(separator: " · "))"
    }

    /// Multi-line hover text, mirroring the stacked daily chart's tooltip shape.
    var tooltip: String {
        let header = DashboardDateFormat.medium(date)
        guard isCovered else { return "\(header)\nNo retained history" }
        guard hasUsage else { return "\(header)\nNo tracked usage" }

        var lines = [header, "\(UsageFormat.tokens(totalTokens)) tokens", UsageFormat.cost(estimatedCostUSD)]
        if !providers.isEmpty {
            lines.append("")
            lines.append(contentsOf: providers.map {
                "\($0.provider.displayName): \(UsageFormat.tokens($0.tokens)) · \(UsageFormat.cost($0.costUSD))"
            })
        }
        return lines.joined(separator: "\n")
    }
}

/// One column of the grid. `days` always holds seven weekday slots starting at
/// the calendar's `firstWeekday`; `nil` marks a future date with no cell.
struct TokenActivityWeek: Identifiable, Equatable {
    var id: Date { startDate }
    let index: Int
    let startDate: Date
    let days: [TokenActivityDay?]
}

/// A month header pinned to the column that opens the month.
struct TokenActivityMonthLabel: Identifiable, Equatable {
    var id: Int { weekIndex }
    let weekIndex: Int
    let title: String
}

/// Pure, deterministic contribution-calendar input derived from one reviewed
/// `CostSummary`.
///
/// Coverage policy (matching `CostChartPresentation`): the earliest `dailyUsage`
/// row on or before today opens the covered span, which runs through today.
/// Days inside that span with no rows are confirmed zero-usage days; days before
/// it are unavailable history, not synthetic zeros.
struct TokenActivityCalendar {
    /// Columns the dashboard draws: the trailing month. Six is the smallest
    /// window that always covers the 30 days every other cost surface reports —
    /// five spans only 29 when today opens its own column — and it leaves the
    /// cells wide enough to read, which a year-wide grid never was.
    static let defaultWeeks = 6
    /// Widest grid the geometry stays honest for. Separate from `defaultWeeks`
    /// so narrowing the visible window cannot silently cap a caller that asks
    /// for more.
    static let maxWeeks = 53
    static let weekdayCount = 7

    let requestedWeeks: Int
    /// First day of the grid — always the calendar's `firstWeekday`.
    let startDate: Date
    /// Last day of the grid — always today; the grid never renders the future.
    let endDate: Date
    /// First day MeterBar has retained history for, or `nil` when it has none.
    let coverageStartDate: Date?
    let weeks: [TokenActivityWeek]
    let monthLabels: [TokenActivityMonthLabel]
    let scale: TokenActivityIntensityScale
    /// Short weekday names ordered from the calendar's `firstWeekday`.
    let weekdaySymbols: [String]
    /// Every rendered cell, oldest first.
    let days: [TokenActivityDay]

    private let daysByDate: [Date: TokenActivityDay]

    init(
        summary: CostSummary?,
        weeks: Int = TokenActivityCalendar.defaultWeeks,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let requestedWeeks = min(max(1, weeks), Self.maxWeeks)
        let today = calendar.startOfDay(for: now)
        let weekdayOffset = (calendar.component(.weekday, from: today) - calendar.firstWeekday + Self.weekdayCount)
            % Self.weekdayCount
        let currentWeekStart = Self.day(today, offsetBy: -weekdayOffset, calendar: calendar)
        let gridStart = Self.day(
            currentWeekStart,
            offsetBy: -(requestedWeeks - 1) * Self.weekdayCount,
            calendar: calendar
        )

        // Future-dated rows never open or extend the covered span.
        let rows = (summary?.dailyUsage ?? []).filter { calendar.startOfDay(for: $0.date) <= today }
        let rowsByDay = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
        let coverageStartDate = rowsByDay.keys.min()

        let slots: [(date: Date, isFuture: Bool)] = (0..<(requestedWeeks * Self.weekdayCount)).map { offset in
            let date = Self.day(gridStart, offsetBy: offset, calendar: calendar)
            return (date, date > today)
        }

        let totals: [(date: Date, isCovered: Bool, tokens: Int, cost: Double, providers: [TokenActivityProviderTotal])]
        totals = slots.filter { !$0.isFuture }.map { slot in
            let providers = Self.providerTotals(for: rowsByDay[slot.date] ?? [])
            return (
                slot.date,
                coverageStartDate.map { slot.date >= $0 } ?? false,
                providers.reduce(0) { $0 + $1.tokens },
                providers.reduce(0) { $0 + $1.costUSD },
                providers
            )
        }

        let scale = TokenActivityIntensityScale(dailyTotals: totals.map(\.tokens))
        let days = totals.map { total in
            TokenActivityDay(
                date: total.date,
                isCovered: total.isCovered,
                totalTokens: total.tokens,
                estimatedCostUSD: total.cost,
                providers: total.providers,
                level: scale.level(for: total.tokens)
            )
        }

        let daysByDate = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        let weeks = (0..<requestedWeeks).map { index in
            let slice = slots[(index * Self.weekdayCount)..<((index + 1) * Self.weekdayCount)]
            return TokenActivityWeek(
                index: index,
                startDate: slice.first?.date ?? gridStart,
                days: slice.map { $0.isFuture ? nil : daysByDate[$0.date] }
            )
        }

        self.requestedWeeks = requestedWeeks
        self.startDate = gridStart
        self.endDate = today
        self.coverageStartDate = coverageStartDate
        self.weeks = weeks
        self.monthLabels = Self.monthLabels(for: weeks, calendar: calendar)
        self.scale = scale
        self.weekdaySymbols = Self.weekdaySymbols(calendar: calendar)
        self.days = days
        self.daysByDate = daysByDate
    }

    /// The rendered cell for `date`, or `nil` when the date falls outside the
    /// grid (before it starts, or in the future).
    func day(on date: Date) -> TokenActivityDay? { daysByDate[date] }

    /// Days MeterBar has retained history for, whether or not they saw usage.
    var trackedDays: [TokenActivityDay] { days.filter(\.isCovered) }

    /// Days that actually consumed tokens.
    var activeDays: [TokenActivityDay] { days.filter(\.hasUsage) }

    var hasHistory: Bool { coverageStartDate != nil }

    var hasActivity: Bool { !activeDays.isEmpty }

    var totalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }

    var totalCostUSD: Double { days.reduce(0) { $0 + $1.estimatedCostUSD } }

    var busiestDay: TokenActivityDay? { activeDays.max { $0.totalTokens < $1.totalTokens } }

    /// Short caption naming how much of the window is backed by real history.
    var coverageSummary: String? {
        guard hasHistory else { return nil }
        let tracked = trackedDays.count
        return "\(tracked) day\(tracked == 1 ? "" : "s") tracked"
    }

    /// Caption shown under the grid while nothing is hovered or focused.
    var overviewLine: String {
        guard hasActivity else { return "No tracked usage in this window." }

        var parts = ["\(UsageFormat.tokens(totalTokens)) tokens", UsageFormat.cost(totalCostUSD)]
        if let busiest = busiestDay {
            parts.append("Busiest \(DashboardDateFormat.medium(busiest.date))"
                + " (\(UsageFormat.tokens(busiest.totalTokens)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Construction helpers

    private static func day(_ date: Date, offsetBy days: Int, calendar: Calendar) -> Date {
        guard let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return date }
        // Zones that shift at midnight can return 01:00; re-normalise every hop.
        return calendar.startOfDay(for: shifted)
    }

    private static func providerTotals(for rows: [DailyTokenUsage]) -> [TokenActivityProviderTotal] {
        Dictionary(grouping: rows, by: \.provider)
            .map { provider, rows in
                TokenActivityProviderTotal(
                    provider: provider,
                    tokens: rows.reduce(0) { $0 + max(0, $1.totalTokens) },
                    costUSD: rows.reduce(0) { $0 + max(0, $1.estimatedCostUSD) }
                )
            }
            .filter { $0.tokens > 0 || $0.costUSD > 0 }
            .sorted {
                if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
                return $0.provider.displayName < $1.provider.displayName
            }
    }

    private static func monthLabels(
        for weeks: [TokenActivityWeek],
        calendar: Calendar
    ) -> [TokenActivityMonthLabel] {
        // The leading column is almost always mid-month and has no room for a
        // header, so labels start at the first column that opens a new month.
        weeks.dropFirst().compactMap { week in
            let previous = weeks[week.index - 1].startDate
            guard calendar.component(.month, from: week.startDate) != calendar.component(.month, from: previous)
            else { return nil }
            return TokenActivityMonthLabel(weekIndex: week.index, title: DashboardDateFormat.month(week.startDate))
        }
    }

    private static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.count == weekdayCount else { return symbols }
        let offset = calendar.firstWeekday - 1
        return (0..<weekdayCount).map { symbols[($0 + offset) % weekdayCount] }
    }
}

// MARK: - Hour × day grid

/// Stable identity for one local day/hour coordinate. The hour component is
/// explicit so daylight-saving transitions still render exactly 24 columns;
/// repeated fallback hours aggregate into their shared local-hour column.
struct TokenActivityHourKey: Hashable {
    let day: Date
    let hour: Int
}

/// One cell in the trailing-seven-day hourly activity grid.
struct TokenActivityHour: Identifiable, Equatable {
    var id: TokenActivityHourKey { TokenActivityHourKey(day: day, hour: hour) }

    let day: Date
    let hour: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
    let providers: [TokenActivityProviderTotal]
    let level: Int

    var hasUsage: Bool { totalTokens > 0 }

    var accessibilityLabel: String { header }

    var accessibilityValue: String {
        guard hasUsage else { return "No tracked usage" }

        var parts = [
            "\(UsageFormat.tokens(totalTokens)) tokens",
            UsageFormat.cost(estimatedCostUSD),
            "intensity \(level) of \(TokenActivityIntensityScale.bandCount)",
        ]
        parts.append(contentsOf: providers.map {
            "\($0.provider.displayName) \(UsageFormat.tokens($0.tokens)), \(UsageFormat.cost($0.costUSD))"
        })
        return parts.joined(separator: ", ")
    }

    var detailLine: String {
        guard hasUsage else { return "\(header) · No tracked usage" }

        var parts = ["\(UsageFormat.tokens(totalTokens)) tokens", UsageFormat.cost(estimatedCostUSD)]
        parts.append(contentsOf: providers.map {
            "\($0.provider.displayName) \(UsageFormat.tokens($0.tokens))"
        })
        return "\(header) · \(parts.joined(separator: " · "))"
    }

    var tooltip: String {
        guard hasUsage else { return "\(header)\nNo tracked usage" }

        var lines = [header, "\(UsageFormat.tokens(totalTokens)) tokens", UsageFormat.cost(estimatedCostUSD)]
        if !providers.isEmpty {
            lines.append("")
            lines.append(contentsOf: providers.map {
                "\($0.provider.displayName): \(UsageFormat.tokens($0.tokens)) · \(UsageFormat.cost($0.costUSD))"
            })
        }
        return lines.joined(separator: "\n")
    }

    private var header: String {
        "\(DashboardDateFormat.medium(day)) at \(String(format: "%02d:00", hour))"
    }
}

/// One day row, oldest to newest, with a stable cell for each local hour 0–23.
struct TokenActivityHourDay: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let hours: [TokenActivityHour]
}

/// Pure 7 × 24 model derived once before SwiftUI hover/focus updates begin.
struct TokenActivityHourlyCalendar {
    static let dayCount = 7
    static let hourCount = 24

    let startDate: Date
    let endDate: Date
    let days: [TokenActivityHourDay]
    let hours: [TokenActivityHour]
    let scale: TokenActivityIntensityScale

    private let hoursByKey: [TokenActivityHourKey: TokenActivityHour]
    private let calendar: Calendar

    init(
        hourlyUsage: [HourlyTokenUsage],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let today = calendar.startOfDay(for: now)
        let startDate = Self.day(today, offsetBy: -(Self.dayCount - 1), calendar: calendar)
        let rows = hourlyUsage.filter { row in
            let day = calendar.startOfDay(for: row.date)
            return day >= startDate && day <= today
        }
        let rowsByKey = Dictionary(grouping: rows) { row in
            TokenActivityHourKey(
                day: calendar.startOfDay(for: row.date),
                hour: calendar.component(.hour, from: row.date)
            )
        }
        let coordinates = (0..<Self.dayCount).flatMap { dayOffset in
            let day = Self.day(startDate, offsetBy: dayOffset, calendar: calendar)
            return (0..<Self.hourCount).map { TokenActivityHourKey(day: day, hour: $0) }
        }
        let totals = coordinates.map { key in
            let providers = Self.providerTotals(for: rowsByKey[key] ?? [])
            return (
                key: key,
                tokens: providers.reduce(0) { $0 + $1.tokens },
                cost: providers.reduce(0) { $0 + $1.costUSD },
                providers: providers
            )
        }
        let scale = TokenActivityIntensityScale(dailyTotals: totals.map(\.tokens))
        let hours = totals.map { total in
            TokenActivityHour(
                day: total.key.day,
                hour: total.key.hour,
                totalTokens: total.tokens,
                estimatedCostUSD: total.cost,
                providers: total.providers,
                level: scale.level(for: total.tokens)
            )
        }
        let hoursByKey = Dictionary(uniqueKeysWithValues: hours.map { ($0.id, $0) })
        let days = (0..<Self.dayCount).map { dayOffset in
            let day = Self.day(startDate, offsetBy: dayOffset, calendar: calendar)
            return TokenActivityHourDay(
                date: day,
                hours: (0..<Self.hourCount).compactMap {
                    hoursByKey[TokenActivityHourKey(day: day, hour: $0)]
                }
            )
        }

        self.startDate = startDate
        self.endDate = today
        self.days = days
        self.hours = hours
        self.scale = scale
        self.hoursByKey = hoursByKey
        self.calendar = calendar
    }

    func hour(at date: Date) -> TokenActivityHour? {
        hoursByKey[TokenActivityHourKey(
            day: calendar.startOfDay(for: date),
            hour: calendar.component(.hour, from: date)
        )]
    }

    func hour(for key: TokenActivityHourKey) -> TokenActivityHour? { hoursByKey[key] }

    var activeHours: [TokenActivityHour] { hours.filter(\.hasUsage) }

    var totalTokens: Int { hours.reduce(0) { $0 + $1.totalTokens } }

    var totalCostUSD: Double { hours.reduce(0) { $0 + $1.estimatedCostUSD } }

    var busiestHour: TokenActivityHour? { activeHours.max { $0.totalTokens < $1.totalTokens } }

    var coverageSummary: String { "7 days tracked" }

    var overviewLine: String {
        guard let busiestHour else { return "No tracked usage in this window." }

        return [
            "\(UsageFormat.tokens(totalTokens)) tokens",
            UsageFormat.cost(totalCostUSD),
            "Busiest \(DashboardDateFormat.medium(busiestHour.day)) at "
                + String(format: "%02d:00", busiestHour.hour)
                + " (\(UsageFormat.tokens(busiestHour.totalTokens)))",
        ].joined(separator: " · ")
    }

    private static func day(_ date: Date, offsetBy days: Int, calendar: Calendar) -> Date {
        guard let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return date }
        return calendar.startOfDay(for: shifted)
    }

    private static func providerTotals(for rows: [HourlyTokenUsage]) -> [TokenActivityProviderTotal] {
        Dictionary(grouping: rows, by: \.provider)
            .map { provider, rows in
                TokenActivityProviderTotal(
                    provider: provider,
                    tokens: rows.reduce(0) { $0 + max(0, $1.totalTokens) },
                    costUSD: rows.reduce(0) { $0 + max(0, $1.estimatedCostUSD) }
                )
            }
            .filter { $0.tokens > 0 || $0.costUSD > 0 }
            .sorted {
                if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
                return $0.provider.displayName < $1.provider.displayName
            }
    }
}

/// Selects the hourly seven-day grid when the new cache field is populated,
/// otherwise preserving the existing calendar (including the two-week legacy
/// fallback). Both derived models are built here, never in a hover-driven body.
struct TokenActivityGrid {
    let daily: TokenActivityCalendar?
    let hourly: TokenActivityHourlyCalendar?

    init(
        summary: CostSummary?,
        windowSelection: CostWindowSelection,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        if windowSelection == .week,
           let hourlyUsage = summary?.hourlyUsage,
           !hourlyUsage.isEmpty {
            daily = nil
            hourly = TokenActivityHourlyCalendar(
                hourlyUsage: hourlyUsage,
                now: now,
                calendar: calendar
            )
        } else {
            daily = TokenActivityCalendar(
                summary: summary,
                weeks: windowSelection.fallbackActivityWeeks,
                now: now,
                calendar: calendar
            )
            hourly = nil
        }
    }

    var hasHistory: Bool { hourly != nil || daily?.hasHistory == true }

    var coverageSummary: String? { hourly?.coverageSummary ?? daily?.coverageSummary }
}
