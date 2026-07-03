import Foundation

// MARK: - SocialShareCardContent

struct SocialShareCardContent: Equatable {
    // MARK: Lifecycle

    init(
        tokenTotal: Int?,
        estimatedCostUSD: Double?,
        sourceCount: Int,
        providerNames: [String],
        tightestLimitTitle: String?,
        tightestPercentLeft: Int?,
        dailyTokenTotals: [Int],
        generatedAt: Date = Date()
    ) {
        self.tokenTotal = tokenTotal
        self.estimatedCostUSD = estimatedCostUSD
        self.sourceCount = max(0, sourceCount)
        self.providerNames = Self.uniqueProviderNames(providerNames)
        self.tightestLimitTitle = tightestLimitTitle
        self.tightestPercentLeft = tightestPercentLeft
        self.dailyTokenTotals = Array(dailyTokenTotals.suffix(30))
        self.generatedAt = generatedAt
    }

    // MARK: Internal

    static let appName = "MeterBar"
    static let repositoryURL = "https://github.com/VincentShipsIt/meterbar.app"
    static let repositoryDisplay = "github.com/VincentShipsIt/meterbar.app"
    static let installCommand = "brew tap VincentShipsIt/tap && brew install --cask VincentShipsIt/tap/meterbar"

    let tokenTotal: Int?
    let estimatedCostUSD: Double?
    let sourceCount: Int
    let providerNames: [String]
    let tightestLimitTitle: String?
    let tightestPercentLeft: Int?
    let dailyTokenTotals: [Int]
    let generatedAt: Date

    var hasTokenData: Bool {
        tokenTotal != nil
    }

    var tokenHeroValue: String {
        guard let tokenTotal else {
            return "Scan needed"
        }
        return UsageFormat.groupedTokens(tokenTotal)
    }

    var compactTokenHeroValue: String {
        guard let tokenTotal else {
            return "0"
        }
        return UsageFormat.tokens(tokenTotal)
    }

    var tokenHeroCaption: String {
        hasTokenData ? "tokens tracked in 30 days" : "30-day token history pending"
    }

    var costLabel: String {
        guard let estimatedCostUSD else {
            return "API-rate estimate pending"
        }
        return "\(UsageFormat.cost(estimatedCostUSD)) API-rate estimate"
    }

    var sourceLabel: String {
        let count = max(sourceCount, providerNames.count)
        return count == 1 ? "1 source" : "\(count) sources"
    }

    var providerLine: String {
        let providers = providerNames.prefix(3)
        guard !providers.isEmpty else {
            return "Claude Code / Codex / Cursor"
        }
        return providers.joined(separator: " / ")
    }

    var quotaLine: String {
        guard let tightestLimitTitle, let tightestPercentLeft else {
            return "Quota window waiting for refresh"
        }
        if tightestPercentLeft <= 0 {
            return "\(tightestLimitTitle) is maxed until reset"
        }
        return "\(tightestLimitTitle) has \(tightestPercentLeft)% quota left"
    }

    var tweetText: String {
        [
            "\(Self.appName) token maxing receipts: \(compactTokenHeroValue) tokens tracked locally.",
            "Repo: \(Self.repositoryURL)",
            "Install: \(Self.installCommand)",
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
