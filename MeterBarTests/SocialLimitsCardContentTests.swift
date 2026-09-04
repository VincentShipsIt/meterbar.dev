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
        usageLimit: UsageLimit
    ) -> SnapshotLimit {
        SnapshotLimit(id: "\(title)-id", kind: kind, title: title, usageLimit: usageLimit)
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
