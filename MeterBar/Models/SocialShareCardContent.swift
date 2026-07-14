import Foundation

// MARK: - SocialShareCardContent

struct SocialShareCardContent: Equatable {
    // MARK: Lifecycle

    init(
        tokenTotal: Int?,
        sessionCount: Int?,
        providerNames: [String],
        topProviderName: String?,
        dailyTokenTotals: [Int],
        generatedAt: Date = Date()
    ) {
        self.tokenTotal = tokenTotal
        self.sessionCount = sessionCount.map { max(0, $0) }
        self.providerNames = Self.uniqueProviderNames(providerNames)
        self.topProviderName = topProviderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dailyTokenTotals = Array(dailyTokenTotals.suffix(30))
        self.generatedAt = generatedAt
    }

    // MARK: Internal

    static let appName = "MeterBar"
    static let websiteURL = "https://meterbar.dev"
    static let websiteDisplay = "meterbar.dev"

    let tokenTotal: Int?
    let sessionCount: Int?
    let providerNames: [String]
    let topProviderName: String?
    let dailyTokenTotals: [Int]
    let generatedAt: Date

    var hasTokenData: Bool {
        tokenTotal != nil
    }

    /// Whether the 30-day chart has any real usage to draw. When this is false
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
        return "\(activeDays)/30"
    }

    var topProviderLabel: String {
        if let topProviderName, !topProviderName.isEmpty {
            return topProviderName
        }
        return providerNames.first ?? "Scan pending"
    }

    var shareCaption: String {
        guard hasTokenData else {
            return [
                "My 30-day token receipts are still hiding.",
                usageTier.joke,
                Self.websiteURL,
            ].joined(separator: "\n")
        }

        return [
            "I burned \(tokenHeroValue) tokens across \(sessionLabel) in the last 30 days.",
            "\(usageTier.title): \(usageTier.joke)",
            Self.websiteURL,
        ].joined(separator: "\n")
    }

    var defaultFilename: String {
        "meterbar-token-card-\(SocialShareCardDateFormat.filename(generatedAt)).png"
    }

    static func dailyTokenTotals(
        from dailyUsage: [DailyTokenUsage],
        days: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Int] {
        let dayCount = max(1, days)
        let today = calendar.startOfDay(for: now)
        let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
        let grouped = Dictionary(grouping: dailyUsage) { usage in
            calendar.startOfDay(for: usage.date)
        }

        return (0 ..< dayCount).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return 0
            }
            return grouped[day]?.reduce(0) { $0 + $1.totalTokens } ?? 0
        }
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

private enum SocialShareCardDateFormat {
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
