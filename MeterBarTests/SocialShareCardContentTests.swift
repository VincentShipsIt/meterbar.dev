import XCTest
@testable import MeterBar

final class SocialShareCardContentTests: XCTestCase {
    func testPublicInstallMetadataMatchesReadme() {
        XCTAssertEqual(SocialShareCardContent.repositoryURL, "https://github.com/VincentShipsIt/meterbar.app")
        XCTAssertEqual(SocialShareCardContent.repositoryDisplay, "github.com/VincentShipsIt/meterbar.app")
        XCTAssertEqual(
            SocialShareCardContent.installCommand,
            "brew tap VincentShipsIt/tap && brew install --cask VincentShipsIt/tap/meterbar"
        )
    }

    func testTweetTextIncludesRepositoryAndInstallCommand() {
        let content = SocialShareCardContent(
            tokenTotal: 1_234_567,
            estimatedCostUSD: 12.34,
            sourceCount: 2,
            providerNames: ["OpenAI Codex", "Claude Code"],
            tightestLimitTitle: "Weekly",
            tightestPercentLeft: 7,
            dailyTokenTotals: [1, 2, 3],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.tweetText.contains("1.2M tokens"))
        XCTAssertTrue(content.tweetText.contains(SocialShareCardContent.repositoryURL))
        XCTAssertTrue(content.tweetText.contains(SocialShareCardContent.installCommand))
    }

    func testShareCardLabelsHandleMissingUsage() {
        let content = SocialShareCardContent(
            tokenTotal: nil,
            estimatedCostUSD: nil,
            sourceCount: 0,
            providerNames: [],
            tightestLimitTitle: nil,
            tightestPercentLeft: nil,
            dailyTokenTotals: [],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(content.tokenHeroValue, "Scan needed")
        XCTAssertEqual(content.tokenHeroCaption, "30-day token history pending")
        XCTAssertEqual(content.costLabel, "API-rate estimate pending")
        XCTAssertEqual(content.sourceLabel, "0 sources")
        XCTAssertEqual(content.providerLine, "Claude Code / Codex / Cursor")
        XCTAssertEqual(content.quotaLine, "Quota window waiting for refresh")
    }

    func testQuotaLineCallsOutMaxedLimit() {
        let content = SocialShareCardContent(
            tokenTotal: 42,
            estimatedCostUSD: 0.01,
            sourceCount: 1,
            providerNames: ["Claude Code"],
            tightestLimitTitle: "Session",
            tightestPercentLeft: 0,
            dailyTokenTotals: [],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(content.quotaLine, "Session is maxed until reset")
    }

    func testDailyTokenTotalsBuildsStableWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 86400 * 4)
        let usage = [
            DailyTokenUsage(
                date: Date(timeIntervalSince1970: 86400 * 2),
                provider: .codexCli,
                inputTokens: 100,
                outputTokens: 40,
                cacheReadTokens: 10,
                estimatedCostUSD: 0.1
            ),
            DailyTokenUsage(
                date: Date(timeIntervalSince1970: 86400 * 2 + 3600),
                provider: .claudeCode,
                inputTokens: 200,
                outputTokens: 30,
                cacheReadTokens: 20,
                estimatedCostUSD: 0.2
            ),
            DailyTokenUsage(
                date: Date(timeIntervalSince1970: 86400 * 4),
                provider: .cursor,
                inputTokens: 12,
                outputTokens: 8,
                cacheReadTokens: 0,
                estimatedCostUSD: 0
            ),
        ]

        XCTAssertEqual(
            SocialShareCardContent.dailyTokenTotals(from: usage, days: 5, now: now, calendar: calendar),
            [0, 0, 400, 0, 20]
        )
    }

    func testDefaultFilenameUsesGeneratedTimestamp() {
        let content = SocialShareCardContent(
            tokenTotal: 1,
            estimatedCostUSD: nil,
            sourceCount: 1,
            providerNames: ["Codex", "Codex", " "],
            tightestLimitTitle: nil,
            tightestPercentLeft: nil,
            dailyTokenTotals: Array(0 ..< 40),
            generatedAt: Date(timeIntervalSince1970: 3600)
        )

        XCTAssertEqual(content.providerNames, ["Codex"])
        XCTAssertEqual(content.dailyTokenTotals.count, 30)
        XCTAssertEqual(content.defaultFilename, "meterbar-token-card-19700101-010000.png")
    }
}
