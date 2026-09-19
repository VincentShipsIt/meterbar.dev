import MeterBarShared
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
            dailyBurn: Self.burn([1, 2, 3]),
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
            dailyBurn: [],
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
            dailyBurn: Self.burn([0, 100, 200, 0, 300]),
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
            dailyBurn: Self.burn(Array(0 ..< 40)),
            generatedAt: Date(timeIntervalSince1970: 3600)
        )

        XCTAssertEqual(SocialShareCardContent.chartDayCount, 7)
        XCTAssertEqual(content.dailyTokenTotals.count, SocialShareCardContent.chartDayCount)
        // The newest days survive the trim — an oldest-first slice would draw a
        // week-old chart under a fresh timestamp.
        XCTAssertEqual(content.dailyTokenTotals, Array(33 ..< 40))
        XCTAssertEqual(content.defaultFilename, "meterbar-token-card-19700101-010000.png")
    }

    // MARK: - Provider split

    /// One day can carry several rows for one provider (one per account), and
    /// the chart draws one segment per provider — so the day has to fold before
    /// it slices, or a two-account Claude day draws two Claude bands.
    func testDailyBurnFoldsARepeatedProviderIntoOneSlice() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 86400 * 3)
        let usage = [
            Self.usage(dayOffset: 3, provider: .claudeCode, inputTokens: 100),
            Self.usage(dayOffset: 3, provider: .claudeCode, inputTokens: 60),
            Self.usage(dayOffset: 3, provider: .codexCli, inputTokens: 400),
        ]

        let week = SocialShareCardContent.dailyBurn(from: usage, days: 2, now: now, calendar: calendar)

        XCTAssertEqual(week.count, 2)
        XCTAssertEqual(week[0].slices, [])
        XCTAssertEqual(
            week[1].slices,
            [
                SocialShareProviderSlice(provider: .codexCli, tokens: 400),
                SocialShareProviderSlice(provider: .claudeCode, tokens: 160),
            ]
        )
        XCTAssertEqual(week[1].tokens, 560)
        XCTAssertEqual(week[1].tokens(for: .grok), 0)
    }

    /// A provider with no tokens on a day must not reach the chart at all: a
    /// zero-height segment still claims a color the day did not earn.
    func testDayBurnDropsProvidersWithNoTokens() {
        let day = SocialShareDayBurn(slices: [
            SocialShareProviderSlice(provider: .claudeCode, tokens: 0),
            SocialShareProviderSlice(provider: .grok, tokens: 5),
        ])

        XCTAssertEqual(day.slices, [SocialShareProviderSlice(provider: .grok, tokens: 5)])
    }

    /// The stack order is the *week's*, not each day's. A per-day sort flips
    /// the stack whenever the lead changes hands, which is exactly what this
    /// fixture does: Codex leads the first day, Claude the second.
    func testChartProvidersOrderTheWeekRatherThanEachDay() {
        let content = Self.content(dailyBurn: [
            SocialShareDayBurn(slices: [
                SocialShareProviderSlice(provider: .codexCli, tokens: 900),
                SocialShareProviderSlice(provider: .claudeCode, tokens: 100),
            ]),
            SocialShareDayBurn(slices: [
                SocialShareProviderSlice(provider: .claudeCode, tokens: 700),
                SocialShareProviderSlice(provider: .grok, tokens: 50),
            ]),
        ])

        XCTAssertEqual(content.chartProviders, [.codexCli, .claudeCode, .grok])
        XCTAssertEqual(content.dailyTokenTotals, [1_000, 750])
    }

    // MARK: - Models

    /// Two providers can serve identically named models, and the color beside a
    /// row is a claim about which one burned the tokens — so the fold is by
    /// provider *and* name, never by name alone.
    func testModelSlicesFoldPerProviderAndRankWithinIt() {
        let slices = SocialShareCardContent.modelSlices(
            from: [
                Self.cost(provider: .claudeCode, models: [("claude-fable-5", 400), ("claude-fable-5", 300)]),
                Self.cost(provider: .claudeCode, models: [("claude-haiku-4-5", 120)]),
                Self.cost(provider: .codexCli, models: [("claude-fable-5", 500)]),
            ],
            limit: 10
        )

        XCTAssertEqual(
            slices,
            [
                SocialShareModelSlice(
                    provider: .claudeCode,
                    name: "claude-fable-5",
                    tokens: 700,
                    providerRank: 0
                ),
                SocialShareModelSlice(
                    provider: .codexCli,
                    name: "claude-fable-5",
                    tokens: 500,
                    providerRank: 0
                ),
                SocialShareModelSlice(
                    provider: .claudeCode,
                    name: "claude-haiku-4-5",
                    tokens: 120,
                    providerRank: 1
                ),
            ]
        )
    }

    /// The card has room for a fixed number of rows, and the ones it drops must
    /// be the smallest.
    func testModelSlicesKeepTheBiggestRowsTheCardHasRoomFor() {
        let slices = SocialShareCardContent.modelSlices(
            from: [
                Self.cost(
                    provider: .codexCli,
                    models: [("a", 10), ("b", 90), ("c", 50), ("d", 70), ("e", 0)]
                ),
            ]
        )

        XCTAssertEqual(slices.count, SocialShareCardContent.modelRowCount)
        XCTAssertEqual(slices.map(\.name), ["b", "d", "c"])
        // A zero row is not a model anyone used, and it would draw a full-width
        // minimum bar in its provider's color.
        XCTAssertFalse(slices.contains { $0.tokens == 0 })
    }

    /// A cache from before model attribution carries no model rows at all. The
    /// card has to know that, because it drops the block rather than drawing an
    /// empty plate.
    func testMissingModelAttributionLeavesTheBlockOff() {
        let content = Self.content(dailyBurn: Self.burn([10, 20]))

        XCTAssertFalse(content.hasModelBreakdown)
        XCTAssertEqual(content.largestModelTokens, 0)
        XCTAssertNil(content.topModelLabel)
        XCTAssertFalse(content.shareCaption.contains("Most of it went to"))
    }

    /// Model ids repeat across vendors, and a pasted caption has no color to
    /// lean on, so the provider rides along with the name.
    func testShareCaptionNamesTheTopModelWithItsProvider() {
        let content = Self.content(
            dailyBurn: Self.burn([10]),
            modelSlices: [
                SocialShareModelSlice(
                    provider: .codexCli,
                    name: "gpt-5.6-sol",
                    tokens: 900,
                    providerRank: 0
                ),
            ]
        )

        XCTAssertEqual(content.topModelLabel, "gpt-5.6-sol (Codex)")
        XCTAssertTrue(content.shareCaption.contains("Most of it went to gpt-5.6-sol (Codex)."))
    }

    private static func content(
        dailyBurn: [SocialShareDayBurn],
        modelSlices: [SocialShareModelSlice] = []
    ) -> SocialShareCardContent {
        SocialShareCardContent(
            tokenTotal: 2_000_000,
            sessionCount: 12,
            providerNames: [],
            topProviderName: nil,
            dailyBurn: dailyBurn,
            modelSlices: modelSlices,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func usage(
        dayOffset: Int,
        provider: ServiceType,
        inputTokens: Int
    ) -> DailyTokenUsage {
        DailyTokenUsage(
            date: Date(timeIntervalSince1970: TimeInterval(86400 * dayOffset)),
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0
        )
    }

    private static func cost(provider: ServiceType, models: [(String, Int)]) -> TokenCost {
        TokenCost(
            provider: provider,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0,
            sessionCount: 1,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 1),
            modelBreakdowns: models.map { name, tokens in
                TokenUsageBreakdown(
                    provider: provider,
                    name: name,
                    inputTokens: tokens,
                    outputTokens: 0,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 0,
                    sessionCount: 1
                )
            }
        )
    }

    /// A chart week of plain day totals, all attributed to one provider — the
    /// shape every test here that is not about the provider split wants.
    private static func burn(_ totals: [Int]) -> [SocialShareDayBurn] {
        totals.map { total in
            SocialShareDayBurn(
                slices: [SocialShareProviderSlice(provider: .claudeCode, tokens: total)]
            )
        }
    }
}
