import Foundation
import MeterBarShared

// MARK: - SocialShareDayBurn

/// One day of the chart week, split by the provider that burned it.
///
/// The chart used to be a list of plain day totals under a single amber→red
/// ramp, so the tallest bar of the week said "a lot" and nothing else. Carrying
/// the split lets the same bar say which tools the day actually went to, which
/// is the one thing a receipt posted in a feed is read for.
struct SocialShareDayBurn: Equatable {
    /// Providers with usage on this day, largest first. A provider with zero
    /// tokens is dropped rather than drawn as a hairline of a color the day
    /// did not earn.
    let slices: [SocialShareProviderSlice]

    init(slices: [SocialShareProviderSlice]) {
        self.slices = slices
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
    }

    // Saturating (issue #575) — see `TokenCost.totalTokens`.
    var tokens: Int {
        SafeAccumulate.sum(slices.map(\.tokens))
    }

    func tokens(for provider: ServiceType) -> Int {
        slices.first { $0.provider == provider }?.tokens ?? 0
    }
}

// MARK: - SocialShareProviderSlice

/// One provider's tokens inside a day.
struct SocialShareProviderSlice: Equatable, Identifiable {
    let provider: ServiceType
    let tokens: Int

    var id: String { provider.rawValue }
}

// MARK: - SocialShareModelSlice

/// One model's tokens across the receipt window.
struct SocialShareModelSlice: Equatable, Identifiable {
    let provider: ServiceType
    /// The model id exactly as the provider's own logs wrote it. These are
    /// public identifiers — `claude-fable-5`, `gpt-5.6-sol` — unlike the
    /// project and session breakdowns beside them in the same cache, which
    /// carry the owner's paths and never reach a card.
    let name: String
    let tokens: Int
    /// Rank among this provider's own models, 0 for its biggest. Models take
    /// their provider's color, so rank is what separates two Claude rows —
    /// see `SocialCardPalette.model(_:providerRank:)`.
    let providerRank: Int

    var id: String { "\(provider.rawValue)-\(name)" }

    var formattedTokens: String {
        UsageFormat.tokens(tokens)
    }
}

// MARK: - SocialShareCardContent

struct SocialShareCardContent: Equatable {
    // MARK: Lifecycle

    init(
        tokenTotal: Int?,
        sessionCount: Int?,
        providerNames: [String],
        topProviderName: String?,
        dailyBurn: [SocialShareDayBurn],
        modelSlices: [SocialShareModelSlice] = [],
        generatedAt: Date = Date()
    ) {
        self.tokenTotal = tokenTotal
        self.sessionCount = sessionCount.map { max(0, $0) }
        self.providerNames = Self.uniqueProviderNames(providerNames)
        self.topProviderName = topProviderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dailyBurn = Array(dailyBurn.suffix(Self.chartDayCount))
        self.modelSlices = Array(modelSlices.prefix(Self.modelRowCount))
        self.generatedAt = generatedAt
    }

    // MARK: Internal

    static let appName = "MeterBar"
    static let websiteURL = "https://meterbar.dev"
    static let websiteDisplay = "meterbar.dev"

    /// The single copy-pasteable install line. Homebrew auto-taps a fully
    /// qualified cask name, so the README's separate `brew tap` step is not
    /// needed here — this one command is enough on a clean Mac, which is the
    /// whole point of printing it on a card someone sees in a feed.
    static let installCommand = "brew install --cask VincentShipsIt/tap/meterbar"

    /// Days the sparkline covers. The hero number stays a 30-day total — it
    /// comes from `CostSummary`, not from these buckets — but a 30-bar chart at
    /// card width is a texture rather than a trend, so the chart reads the last
    /// week instead. Every site that slices, pads, or counts the series derives
    /// from this so the window cannot drift between them.
    static let chartDayCount = 7

    /// Model rows the card has room for under the hero. Three is what the
    /// hero column's slack holds at export size without the rows shrinking
    /// below the point where a model id is readable in a feed thumbnail.
    static let modelRowCount = 3

    let tokenTotal: Int?
    let sessionCount: Int?
    let providerNames: [String]
    let topProviderName: String?
    /// The chart week, each day split by the provider that burned it.
    let dailyBurn: [SocialShareDayBurn]
    /// The window's biggest models, largest first. Empty when the cost cache
    /// predates model attribution, which is a real state the card must render
    /// rather than paper over.
    let modelSlices: [SocialShareModelSlice]
    let generatedAt: Date

    /// Day totals, derived rather than stored: the chart draws the split and
    /// the stats read the sum, and two independently-supplied series would
    /// eventually disagree about the same week.
    var dailyTokenTotals: [Int] {
        dailyBurn.map(\.tokens)
    }

    /// Providers that actually appear in the chart week, the week's biggest
    /// first.
    ///
    /// One order for the whole week, not one per day. Sorting each day by its
    /// own sizes flips the stack whenever the lead changes hands, and a chart
    /// whose bars are assembled in a different order every day cannot be read
    /// across days at all. The legend takes the same order, so the key reads
    /// bottom-to-top against the bars. Derived from the drawn days, so it can
    /// never name a provider with no visible segment.
    var chartProviders: [ServiceType] {
        var totals: [ServiceType: Int] = [:]
        for day in dailyBurn {
            for slice in day.slices {
                SafeAccumulate.accumulate(&totals[slice.provider, default: 0], slice.tokens)
            }
        }

        return totals
            .sorted { ($0.value, $1.key.sortOrder) > ($1.value, $0.key.sortOrder) }
            .map(\.key)
    }

    var hasModelBreakdown: Bool {
        !modelSlices.isEmpty
    }

    /// The biggest model's tokens, which every model bar is drawn relative to.
    /// A share of the window total would be a claim the data cannot back:
    /// attribution can cover less than every token, and a row reading "12%"
    /// out of a set that sums to 60 would simply be wrong.
    var largestModelTokens: Int {
        modelSlices.map(\.tokens).max() ?? 0
    }

    var hasTokenData: Bool {
        tokenTotal != nil
    }

    /// Whether the chart window has any real usage to draw. When this is false
    /// the share card must render an honest empty state — never fabricated bars.
    /// This is the single source of truth the chart view keys its empty state on.
    var hasDailyChartData: Bool {
        dailyTokenTotals.contains { $0 > 0 }
    }

    var tokenHeroValue: String {
        guard let tokenTotal else {
            return "SCAN ME"
        }
        return UsageFormat.groupedTokens(tokenTotal)
    }

    var tokenHeroCaption: String {
        hasTokenData ? "tokens burned across local sessions" : "your 30-day receipts are hiding"
    }

    var usageTier: SocialShareUsageTier {
        SocialShareUsageTier.classify(tokenTotal: tokenTotal)
    }

    var sessionLabel: String {
        guard let sessionCount else {
            return "Scan pending"
        }
        return sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
    }

    var averageTokensPerSession: String {
        guard let tokenTotal, let sessionCount, sessionCount > 0 else {
            return "—"
        }
        return UsageFormat.tokens(tokenTotal / sessionCount)
    }

    var activeDaysLabel: String {
        let activeDays = dailyTokenTotals.filter { $0 > 0 }.count
        // Denominator is the window, not `dailyTokenTotals.count`: an unscanned
        // card carries an empty series and would otherwise read "0/0".
        return "\(activeDays)/\(Self.chartDayCount)"
    }

    var topProviderLabel: String {
        if let topProviderName, !topProviderName.isEmpty {
            return topProviderName
        }
        return providerNames.first ?? "Scan pending"
    }

    /// The model the window went to most, named with its provider because model
    /// ids repeat across vendors and a caption has no color to lean on.
    var topModelLabel: String? {
        modelSlices.first.map { "\($0.name) (\($0.provider.shortName))" }
    }

    var shareCaption: String {
        guard hasTokenData else {
            return [
                "My 30-day token receipts are still hiding.",
                usageTier.joke,
                Self.websiteURL,
            ].joined(separator: "\n")
        }

        var lines = [
            "I burned \(tokenHeroValue) tokens across \(sessionLabel) in the last 30 days.",
        ]
        if let topModelLabel {
            lines.append("Most of it went to \(topModelLabel).")
        }
        lines.append("\(usageTier.title): \(usageTier.joke)")
        lines.append(Self.websiteURL)

        return lines.joined(separator: "\n")
    }

    var defaultFilename: String {
        "meterbar-token-card-\(SocialShareCardDateFormat.filename(generatedAt)).png"
    }

    /// The chart week, oldest day first, each day split by provider.
    static func dailyBurn(
        from dailyUsage: [DailyTokenUsage],
        days: Int = SocialShareCardContent.chartDayCount,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SocialShareDayBurn] {
        let dayCount = max(1, days)
        let today = calendar.startOfDay(for: now)
        let startDate = CalendarDayStep.day(today, offsetBy: -(dayCount - 1), calendar: calendar)
        let grouped = Dictionary(grouping: dailyUsage) { usage in
            calendar.startOfDay(for: usage.date)
        }

        return (0 ..< dayCount).map { offset in
            let day = CalendarDayStep.day(startDate, offsetBy: offset, calendar: calendar)
            let rows = grouped[day] ?? []
            // A provider can contribute several rows to one day (one per
            // account), so the day is folded by provider before it is sliced.
            // Saturating (issue #575): a saturated cache row must not trap the
            // share-card sparkline.
            var byProvider: [ServiceType: Int] = [:]
            for row in rows {
                SafeAccumulate.accumulate(&byProvider[row.provider, default: 0], row.totalTokens)
            }

            return SocialShareDayBurn(
                slices: byProvider.map { SocialShareProviderSlice(provider: $0.key, tokens: $0.value) }
            )
        }
    }

    /// Day totals for the same window, for callers that only need the heights.
    static func dailyTokenTotals(
        from dailyUsage: [DailyTokenUsage],
        days: Int = SocialShareCardContent.chartDayCount,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Int] {
        dailyBurn(from: dailyUsage, days: days, now: now, calendar: calendar).map(\.tokens)
    }

    /// The window's biggest models, largest first, ranked within their own
    /// provider so the card can shade same-provider rows apart.
    ///
    /// Folded by provider *and* name rather than by name alone: two providers
    /// serving an identically-named model are two rows on this card, because
    /// the color beside each row is a claim about where the tokens went.
    static func modelSlices(
        from costs: [TokenCost],
        limit: Int = SocialShareCardContent.modelRowCount
    ) -> [SocialShareModelSlice] {
        var totals: [ServiceType: [String: Int]] = [:]
        for cost in costs {
            for breakdown in cost.modelBreakdowns {
                let name = breakdown.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                SafeAccumulate.accumulate(
                    &totals[breakdown.provider, default: [:]][name, default: 0],
                    breakdown.totalTokens
                )
            }
        }

        var ranks: [ServiceType: [String: Int]] = [:]
        for (provider, models) in totals {
            let ordered = models
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map(\.key)
            ranks[provider] = Dictionary(
                uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) }
            )
        }

        let slices = totals.flatMap { provider, models in
            models.map { name, tokens in
                SocialShareModelSlice(
                    provider: provider,
                    name: name,
                    tokens: tokens,
                    providerRank: ranks[provider]?[name] ?? 0
                )
            }
        }

        let ranked = slices
            .filter { $0.tokens > 0 }
            // Name breaks the tie so a card exported twice from one cache is
            // byte-identical; dictionary order alone is not stable.
            .sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
            .prefix(max(0, limit))
        return Array(ranked)
    }

    // MARK: Private

    private static func uniqueProviderNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for name in names {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !seen.contains(trimmedName) else {
                continue
            }
            seen.insert(trimmedName)
            result.append(trimmedName)
        }

        return result
    }
}

// MARK: - SocialShareUsageTier

struct SocialShareUsageTier: Equatable {
    let title: String
    let joke: String
    let symbolName: String

    static func classify(tokenTotal: Int?) -> Self {
        guard let tokenTotal else {
            return Self(
                title: "NO RECEIPTS YET",
                joke: "Run the scan. Your tokens deserve a paper trail.",
                symbolName: "questionmark.folder.fill"
            )
        }

        switch tokenTotal {
        case ..<100_000:
            return Self(
                title: "NOT BURNING ENOUGH",
                joke: "Open another session. The tokens barely felt that.",
                symbolName: "flame"
            )
        case ..<1_000_000:
            return Self(
                title: "WARMING UP",
                joke: "A promising burn. Your context window remains suspiciously calm.",
                symbolName: "flame.fill"
            )
        case ..<10_000_000:
            return Self(
                title: "POWER USER",
                joke: "Respectable. Several context windows gave their all.",
                symbolName: "bolt.fill"
            )
        case ..<50_000_000:
            return Self(
                title: "TOP USER ENERGY",
                joke: "The context window just filed for overtime.",
                symbolName: "trophy.fill"
            )
        default:
            return Self(
                title: "TOKEN MAXXER",
                joke: "Your token budget has entered witness protection.",
                symbolName: "crown.fill"
            )
        }
    }
}

// MARK: - SocialShareCardDateFormat

/// Internal (not file-private) because the dashboard's JSON export stamps its
/// filename with the same UTC formatter, so both artifacts sort together.
enum SocialShareCardDateFormat {
    // MARK: Internal

    static func filename(_ date: Date) -> String {
        filenameFormatter.string(from: date)
    }

    // MARK: Private

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
