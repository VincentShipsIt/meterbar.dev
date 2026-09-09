import XCTest
import MeterBarShared
@testable import MeterBar

final class SocialLimitsCardContentTests: XCTestCase {
    // MARK: - Rows

    func testRowDerivesEveryLabelFromTheSharedQuotaMath() {
        let now = Date(timeIntervalSince1970: 100_000)
        let limit = snapshotLimit(
            kind: .session,
            title: "Session",
            usageLimit: UsageLimit(
                used: 81,
                total: 100,
                resetTime: now.addingTimeInterval(3_600),
                windowSeconds: 18_000
            )
        )

        let row = SocialLimitsCardContent.row(for: limit, now: now)

        XCTAssertEqual(row.title, "Session")
        XCTAssertEqual(row.percentLeft, 19)
        XCTAssertEqual(row.percentLeftText, "19% left")
        XCTAssertEqual(row.usedPercentText, "81% used")
        XCTAssertEqual(row.usedFraction, 0.81, accuracy: 0.0001)
        XCTAssertEqual(row.resetText, "1h")
        XCTAssertEqual(row.heroValueText, "19%")
        XCTAssertNotNil(row.pace)
    }

    /// Mirrors `LimitRow.RowContent.pace`: a derived total must never drive the
    /// pace overlay, on the card any more than in the popover.
    func testEstimatedRowsSuppressPaceAndMarkTheApproximation() {
        let now = Date(timeIntervalSince1970: 100_000)
        let limit = snapshotLimit(
            kind: .weekly,
            title: "Weekly",
            usageLimit: UsageLimit(
                used: 50,
                total: 100,
                resetTime: now.addingTimeInterval(7_200),
                windowSeconds: 18_000,
                isEstimated: true
            )
        )

        let row = SocialLimitsCardContent.row(for: limit, now: now)

        XCTAssertTrue(row.isEstimated)
        XCTAssertNil(row.pace)
        XCTAssertEqual(row.percentLeftText, "~50% left")
        XCTAssertEqual(row.heroValueText, "~50%")
    }

    // MARK: - Row detail text

    /// `detailText` drives the card's exported row copy — it must start from
    /// the value-style-specific `usedText` (a "$… spent" label for currency
    /// rows, not a bare percentage) and fold in the pace overlay before the
    /// reset text, the same two facts `LimitRow`'s footer prints.
    /// A quota row drops its used-percent when it has a pace label. The card
    /// draws a filled bar under every row, so "81% used" is the bar restated in
    /// words, and it was crowding out the two facts the bar cannot show: pace,
    /// and when the window resets.
    func testQuotaRowDropsTheUsedPercentTheBarAlreadyShows() {
        let now = Date(timeIntervalSince1970: 100_000)
        let limit = snapshotLimit(
            kind: .session,
            title: "Session",
            usageLimit: UsageLimit(
                used: 81,
                total: 100,
                resetTime: now.addingTimeInterval(3_600),
                windowSeconds: 18_000
            )
        )

        let row = SocialLimitsCardContent.row(for: limit, now: now)

        XCTAssertNotNil(row.pace)
        guard let pace = row.pace else { return }
        XCTAssertEqual(row.detailText, "\(pace.leftLabel) · resets in \(row.resetText ?? "")")
        XCTAssertFalse(row.detailText.contains(row.usedText), "the bar already says how much is used")
    }

    /// An estimated row has no pace, so dropping the used-percent would leave
    /// it with nothing but a countdown. It keeps the number.
    func testEstimatedQuotaRowKeepsItsUsedPercentBecauseItHasNoPace() {
        let now = Date(timeIntervalSince1970: 100_000)
        let limit = snapshotLimit(
            kind: .weekly,
            title: "Weekly",
            usageLimit: UsageLimit(
                used: 62,
                total: 100,
                resetTime: now.addingTimeInterval(3_600),
                windowSeconds: 18_000,
                isEstimated: true
            )
        )

        let row = SocialLimitsCardContent.row(for: limit, now: now)

        XCTAssertNil(row.pace)
        XCTAssertTrue(row.detailText.hasPrefix(row.usedText))
    }

    func testDetailTextForCurrencyRowShowsSpentLabelNotPercent() {
        let now = Date(timeIntervalSince1970: 100_000)
        let limit = snapshotLimit(
            kind: .additional,
            title: "Credits",
            usageLimit: UsageLimit(used: 4.5, total: 20, resetTime: nil),
            valueStyle: .currency
        )

        let row = SocialLimitsCardContent.row(for: limit, now: now)

        // A currency row keeps its amount even though it has a bar: the bar
        // shows the proportion, but "$4.50" is a fact no bar encodes.
        XCTAssertEqual(row.usedText, "$4.50 spent")
        XCTAssertTrue(row.detailText.hasPrefix("$4.50 spent"))
        XCTAssertFalse(row.detailText.contains("%"))
    }

    func testDetailTextMarksEstimatedRowsBeforePace() {
        let now = Date(timeIntervalSince1970: 100_000)
        let limit = snapshotLimit(
            kind: .weekly,
            title: "Weekly",
            usageLimit: UsageLimit(
                used: 50,
                total: 100,
                resetTime: now.addingTimeInterval(7_200),
                windowSeconds: 18_000,
                isEstimated: true
            )
        )

        let row = SocialLimitsCardContent.row(for: limit, now: now)

        XCTAssertNil(row.pace)
        XCTAssertEqual(row.detailText, "\(row.usedText) · estimated · resets in \(row.resetText ?? "")")
    }

    // MARK: - Snapshot derivation

    func testHeadlineFollowsTheSnapshotPrimaryLimit() {
        let now = Date(timeIntervalSince1970: 100_000)
        let snapshot = providerSnapshot(
            title: "Claude Code",
            updatedAt: now.addingTimeInterval(-240),
            limits: [
                snapshotLimit(
                    kind: .session,
                    title: "Session",
                    usageLimit: UsageLimit(
                        used: 81,
                        total: 100,
                        resetTime: now.addingTimeInterval(10_440),
                        windowSeconds: 18_000
                    )
                ),
                snapshotLimit(
                    kind: .weekly,
                    title: "Weekly",
                    usageLimit: UsageLimit(
                        used: 47,
                        total: 100,
                        resetTime: now.addingTimeInterval(198_000),
                        windowSeconds: 604_800
                    )
                ),
            ]
        )

        let content = SocialLimitsCardContent(
            snapshot: snapshot,
            now: now,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.hasQuotaData)
        XCTAssertEqual(content.providerName, "Claude Code")
        XCTAssertEqual(content.headline?.title, "Session")
        XCTAssertEqual(content.quotaHeroValue, "19%")
        XCTAssertEqual(content.quotaHeroCaption, "left on Session")
        XCTAssertEqual(content.band, .tight)
        XCTAssertEqual(content.statusLabel, "Tight")
        XCTAssertEqual(content.rows.map(\.title), ["Session", "Weekly"])
    }

    /// The card has room for a fixed number of rows; a provider with more
    /// windows keeps the tightest ones rather than overflowing the panel.
    func testRowsKeepTheTightestWindowsWhenTheProviderHasMany() {
        let now = Date(timeIntervalSince1970: 100_000)
        let usedPercents: [Double] = [10, 90, 30, 70, 50, 95]
        let snapshot = providerSnapshot(
            title: "Cursor",
            updatedAt: now,
            limits: usedPercents.enumerated().map { index, used in
                snapshotLimit(
                    kind: .additional,
                    title: "Pool \(index)",
                    usageLimit: UsageLimit(used: used, total: 100, resetTime: nil)
                )
            }
        )

        let content = SocialLimitsCardContent(
            snapshot: snapshot,
            now: now,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(content.rows.count, SocialLimitsCardContent.maxRowCount)
        XCTAssertEqual(content.rows.map(\.title), ["Pool 1", "Pool 3", "Pool 4", "Pool 5"])
    }

    /// The headline always reads `snapshot.primaryLimit`, so that window must
    /// survive the trim even when four secondary limits are individually
    /// tighter — otherwise the hero/status describe a window the card never
    /// renders.
    func testRowsRetainThePrimaryLimitEvenWhenSecondariesAreTighter() {
        let now = Date(timeIntervalSince1970: 100_000)
        let session = snapshotLimit(
            kind: .session,
            title: "Session",
            usageLimit: UsageLimit(used: 20, total: 100, resetTime: nil)
        )
        let pools = [5, 10, 15, 20].enumerated().map { index, percentLeft in
            snapshotLimit(
                kind: .additional,
                title: "Pool \(index)",
                usageLimit: UsageLimit(used: Double(100 - percentLeft), total: 100, resetTime: nil)
            )
        }
        let snapshot = providerSnapshot(
            title: "Cursor",
            updatedAt: now,
            limits: [session] + pools
        )

        let content = SocialLimitsCardContent(
            snapshot: snapshot,
            now: now,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(content.headline?.title, "Session")
        XCTAssertEqual(content.rows.count, SocialLimitsCardContent.maxRowCount)
        // Original provider order, primary kept, tightest three secondaries kept.
        XCTAssertEqual(content.rows.map(\.title), ["Session", "Pool 0", "Pool 1", "Pool 2"])
    }

    func testSnapshotWithoutLimitsRendersTheHonestEmptyState() {
        let content = SocialLimitsCardContent(
            snapshot: providerSnapshot(title: "Codex", updatedAt: nil, limits: []),
            now: Date(timeIntervalSince1970: 100_000),
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertFalse(content.hasQuotaData)
        XCTAssertNil(content.band)
        XCTAssertEqual(content.quotaHeroValue, "NO QUOTA")
        XCTAssertEqual(content.quotaHeroCaption, "connect an account to see limits")
        XCTAssertEqual(content.statusLabel, "No data")
        XCTAssertEqual(content.updatedText, "No data")
        XCTAssertEqual(content.tier.title, "NO LIMITS TRACKED")
    }

    // MARK: - Tiers

    func testTiersCoverEveryQuotaBand() {
        XCTAssertEqual(SocialLimitsTier.classify(band: nil).title, "NO LIMITS TRACKED")
        XCTAssertEqual(SocialLimitsTier.classify(band: .healthy).title, "CRUISING")
        XCTAssertEqual(SocialLimitsTier.classify(band: .tight).title, "RATIONING MODE")
        XCTAssertEqual(SocialLimitsTier.classify(band: .critical).title, "LIVING ON FUMES")
        XCTAssertEqual(SocialLimitsTier.classify(band: .exhausted).title, "RATE LIMITED")
    }

    // MARK: - Caption and filename

    func testShareCaptionSharesQuotaWithoutInstallPitch() {
        let now = Date(timeIntervalSince1970: 100_000)
        let content = SocialLimitsCardContent(
            snapshot: providerSnapshot(
                title: "Claude Code",
                updatedAt: now,
                limits: [
                    snapshotLimit(
                        kind: .session,
                        title: "Session",
                        usageLimit: UsageLimit(
                            used: 81,
                            total: 100,
                            resetTime: now.addingTimeInterval(10_440),
                            windowSeconds: 18_000
                        )
                    )
                ]
            ),
            now: now,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.shareCaption.contains("19% left"))
        XCTAssertTrue(content.shareCaption.contains("Session"))
        XCTAssertTrue(content.shareCaption.contains("Claude Code"))
        XCTAssertTrue(content.shareCaption.contains("RATIONING MODE"))
        XCTAssertTrue(content.shareCaption.contains(SocialShareCardContent.websiteURL))
        XCTAssertFalse(content.shareCaption.contains("brew install"))
    }

    func testEmptyShareCaptionStillLinksTheSite() {
        let content = SocialLimitsCardContent(
            snapshot: providerSnapshot(title: "Codex", updatedAt: nil, limits: []),
            now: Date(timeIntervalSince1970: 0),
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(content.shareCaption.contains(SocialShareCardContent.websiteURL))
        XCTAssertFalse(content.shareCaption.contains("% left"))
    }

    func testDefaultFilenameUsesGeneratedTimestamp() {
        let content = SocialLimitsCardContent(
            snapshot: providerSnapshot(title: "Codex", updatedAt: nil, limits: []),
            now: Date(timeIntervalSince1970: 0),
            generatedAt: Date(timeIntervalSince1970: 3_600)
        )

        XCTAssertEqual(content.defaultFilename, "meterbar-limits-card-19700101-010000.png")
    }

    // MARK: - Helpers

    private func snapshotLimit(
        kind: SnapshotLimit.Kind,
        title: String,
        usageLimit: UsageLimit,
        valueStyle: SnapshotLimit.ValueStyle = .quota
    ) -> SnapshotLimit {
        SnapshotLimit(id: "\(title)-id", kind: kind, title: title, usageLimit: usageLimit, valueStyle: valueStyle)
    }

    private func providerSnapshot(
        title: String,
        updatedAt: Date?,
        limits: [SnapshotLimit]
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "snapshot-\(title)",
            title: title,
            service: .claudeCode,
            updatedAt: updatedAt,
            limits: limits,
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
    }
}
