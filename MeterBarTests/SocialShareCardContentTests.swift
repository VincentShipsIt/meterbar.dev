import XCTest
@testable import MeterBar

final class SocialShareCardContentTests: XCTestCase {
    func testPreviewSizeUsesStableViewportGeometry() {
        let size = SocialShareCardLayout.previewSize(
            viewportWidth: 700,
            horizontalInsets: 64,
            verticalScrollerWidth: 16
        )

        XCTAssertEqual(size.width, 620)
        XCTAssertEqual(
            size.height,
            size.width / SocialShareCardLayout.aspectRatio,
            accuracy: 0.0001
        )
    }

    func testPreviewSizeCapsWideWindowsAtMaximumWidth() {
        let size = SocialShareCardLayout.previewSize(
            viewportWidth: 1_400,
            horizontalInsets: 64,
            verticalScrollerWidth: 16
        )

        XCTAssertEqual(size.width, SocialShareCardLayout.maximumPreviewWidth)
        XCTAssertEqual(
            size.height,
            SocialShareCardLayout.maximumPreviewWidth / SocialShareCardLayout.aspectRatio,
            accuracy: 0.0001
        )
    }

    func testPreviewSizeNeverBecomesNegative() {
        let size = SocialShareCardLayout.previewSize(
            viewportWidth: 40,
            horizontalInsets: 64,
            verticalScrollerWidth: 16
        )

        XCTAssertEqual(size, .zero)
    }

    func testPublicWebsiteMetadataMatchesReadme() {
        XCTAssertEqual(SocialShareCardContent.websiteURL, "https://meterbar.dev")
        XCTAssertEqual(SocialShareCardContent.websiteDisplay, "meterbar.dev")
        // The card prints one line someone can paste on a clean Mac. A bare
        // cask name would need the tap first; the fully qualified name taps
        // implicitly, so this must stay fully qualified.
        XCTAssertEqual(
            SocialShareCardContent.installCommand,
            "brew install --cask VincentShipsIt/tap/meterbar"
        )
    }

    func testShareCaptionSharesUsageWithoutInstallPitch() {
        let content = SocialShareCardContent(
            tokenTotal: 1_234_567,
            sessionCount: 42,
            providerNames: ["OpenAI Codex", "Claude Code"],
            topProviderName: "Claude Code",
            dailyTokenTotals: [1, 2, 3],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.shareCaption.contains("1,234,567 tokens"))
        XCTAssertTrue(content.shareCaption.contains("42 sessions"))
        XCTAssertTrue(content.shareCaption.contains("POWER USER"))
        XCTAssertTrue(content.shareCaption.contains(SocialShareCardContent.websiteURL))
        XCTAssertFalse(content.shareCaption.contains("brew install"))
    }

    func testShareCardLabelsHandleMissingUsage() {
        let content = SocialShareCardContent(
            tokenTotal: nil,
            sessionCount: nil,
            providerNames: [],
            topProviderName: nil,
            dailyTokenTotals: [],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(content.tokenHeroValue, "SCAN ME")
        XCTAssertEqual(content.tokenHeroCaption, "your 30-day receipts are hiding")
        XCTAssertEqual(content.sessionLabel, "Scan pending")
        XCTAssertEqual(content.averageTokensPerSession, "—")
        XCTAssertEqual(content.activeDaysLabel, "0/7")
        XCTAssertEqual(content.topProviderLabel, "Scan pending")
        XCTAssertEqual(content.usageTier.title, "NO RECEIPTS YET")
    }

    func testSessionStatsUseTrackedTotals() {
        let content = SocialShareCardContent(
            tokenTotal: 2_400_000,
            sessionCount: 24,
            providerNames: ["Codex", "Claude", "Codex", " "],
            topProviderName: " Claude ",
            dailyTokenTotals: [0, 100, 200, 0, 300],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(content.providerNames, ["Codex", "Claude"])
        XCTAssertEqual(content.sessionLabel, "24 sessions")
        XCTAssertEqual(content.averageTokensPerSession, "100.0K")
        XCTAssertEqual(content.activeDaysLabel, "3/7")
        XCTAssertEqual(content.topProviderLabel, "Claude")
    }

    func testUsageTiersCoverLowTopAndMaxxingUsers() {
        XCTAssertEqual(SocialShareUsageTier.classify(tokenTotal: 99_999).title, "NOT BURNING ENOUGH")
        XCTAssertEqual(SocialShareUsageTier.classify(tokenTotal: 999_999).title, "WARMING UP")
        XCTAssertEqual(SocialShareUsageTier.classify(tokenTotal: 9_999_999).title, "POWER USER")
        XCTAssertEqual(SocialShareUsageTier.classify(tokenTotal: 49_999_999).title, "TOP USER ENERGY")
        XCTAssertEqual(SocialShareUsageTier.classify(tokenTotal: 50_000_000).title, "TOKEN MAXXER")
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

    func testDefaultDailyWindowCoversTheChartWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 86400 * 40)
        let usage = [
            DailyTokenUsage(
                date: Date(timeIntervalSince1970: 86400 * 40),
                provider: .codexCli,
                inputTokens: 5,
                outputTokens: 5,
                cacheReadTokens: 0,
                estimatedCostUSD: 0
            ),
            // A day inside the old 30-day window but outside the new one, so the
            // narrowed default is provable rather than merely shorter.
            DailyTokenUsage(
                date: Date(timeIntervalSince1970: 86400 * 20),
                provider: .claudeCode,
                inputTokens: 900,
                outputTokens: 100,
                cacheReadTokens: 0,
                estimatedCostUSD: 1
            ),
        ]

        let totals = SocialShareCardContent.dailyTokenTotals(from: usage, now: now, calendar: calendar)

        XCTAssertEqual(totals.count, SocialShareCardContent.chartDayCount)
        XCTAssertEqual(totals, [0, 0, 0, 0, 0, 0, 10])
    }

    /// `America/Santiago` springs forward *at* local midnight on 2026-09-06,
    /// so `startOfDay(now)` on that day returns 01:00 instead of 00:00 (the
    /// 00:00–01:00 hour does not exist). Building the trailing-week window by
    /// stepping from that instant without re-normalizing every hop preserves
    /// 01:00 on every earlier day, so the share card would post a flat-zero
    /// week even though real usage exists. The UTC fixtures above cannot
    /// exercise this — UTC never observes DST.
    func testDailyTokenTotalsSurviveTheSantiagoMidnightTransition() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago") ?? .current
        let dstNow = ISO8601DateFormatter().date(from: "2026-09-06T13:00:00Z") ?? Date()

        func exactDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            let date = santiago.date(from: components) ?? dstNow
            return santiago.startOfDay(for: date)
        }

        XCTAssertEqual(santiago.component(.hour, from: exactDay(2026, 9, 6)), 1)

        let usage = [
            DailyTokenUsage(
                date: exactDay(2026, 8, 31).addingTimeInterval(3600 * 4),
                provider: .claudeCode,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 0
            ),
            DailyTokenUsage(
                date: exactDay(2026, 9, 6).addingTimeInterval(3600 * 2),
                provider: .claudeCode,
                inputTokens: 700,
                outputTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 0
            ),
        ]

        let totals = SocialShareCardContent.dailyTokenTotals(
            from: usage,
            days: 7,
            now: dstNow,
            calendar: santiago
        )

        XCTAssertEqual(totals, [100, 0, 0, 0, 0, 0, 700])
    }

    func testDefaultFilenameUsesGeneratedTimestampAndKeepsTheChartWeek() {
        let content = SocialShareCardContent(
            tokenTotal: 1,
            sessionCount: 1,
            providerNames: ["Codex"],
            topProviderName: "Codex",
            dailyTokenTotals: Array(0 ..< 40),
            generatedAt: Date(timeIntervalSince1970: 3600)
        )

        XCTAssertEqual(SocialShareCardContent.chartDayCount, 7)
        XCTAssertEqual(content.dailyTokenTotals.count, SocialShareCardContent.chartDayCount)
        // The newest days survive the trim — an oldest-first slice would draw a
        // week-old chart under a fresh timestamp.
        XCTAssertEqual(content.dailyTokenTotals, Array(33 ..< 40))
        XCTAssertEqual(content.defaultFilename, "meterbar-token-card-19700101-010000.png")
    }
}
