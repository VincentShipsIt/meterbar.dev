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
