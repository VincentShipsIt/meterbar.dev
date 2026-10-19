import MeterBarShared
import XCTest
@testable import MeterBar

/// The popover card shows Session and Weekly as donuts. The pure
/// `QuotaDonutContent` carries which limits qualify, how full the ring is, and
/// which tone it takes, so every rule is asserted without hosting a view.
final class QuotaDonutTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func limit(
        _ kind: SnapshotLimit.Kind = .session,
        used: Double,
        total: Double = 100,
        reading: UsageLimit.Reading = .measured,
        isEstimated: Bool = false,
        valueStyle: SnapshotLimit.ValueStyle = .quota
    ) -> SnapshotLimit {
        SnapshotLimit(
            id: "\(kind)",
            kind: kind,
            title: "\(kind)",
            usageLimit: UsageLimit(
                used: used,
                total: total,
                resetTime: nil,
                isEstimated: isEstimated,
                reading: reading
            ),
            valueStyle: valueStyle
        )
    }

    // MARK: - Which limits get a donut

    func testSessionAndWeeklyMeasuredWindowsGetADonut() {
        XCTAssertNotNil(QuotaDonutContent(limit: limit(.session, used: 14)))
        XCTAssertNotNil(QuotaDonutContent(limit: limit(.weekly, used: 55)))
    }

    func testModelAndPoolWindowsStayBars() {
        XCTAssertNil(QuotaDonutContent(limit: limit(.codeReview, used: 14)))
        XCTAssertNil(QuotaDonutContent(limit: limit(.additional, used: 14)))
    }

    func testCreditsEstimatesAndCurrencyStayBars() {
        XCTAssertNil(QuotaDonutContent(limit: limit(.weekly, used: 5, reading: .remainder)))
        XCTAssertNil(QuotaDonutContent(limit: limit(.weekly, used: 5, reading: .unlimited)))
        XCTAssertNil(QuotaDonutContent(limit: limit(.weekly, used: 5, isEstimated: true)))
        XCTAssertNil(QuotaDonutContent(limit: limit(.weekly, used: 5, valueStyle: .currency)))
    }

    // MARK: - Ring

    func testRingShowsWhatIsLeft() throws {
        let content = try XCTUnwrap(QuotaDonutContent(limit: limit(.session, used: 14)))

        XCTAssertEqual(content.fractionLeft, 0.86, accuracy: 0.0001)
        XCTAssertEqual(content.percentLeft, 86)
        XCTAssertEqual(content.centerText(locale: en), "86%")
    }

    func testRingClampsOverUse() throws {
        let content = try XCTUnwrap(QuotaDonutContent(limit: limit(.weekly, used: 130)))

        XCTAssertEqual(content.fractionLeft, 0)
    }

    func testToneFollowsTheSharedQuotaBands() throws {
        func tone(_ used: Double) throws -> QuotaDonutContent.Tone {
            try XCTUnwrap(QuotaDonutContent(limit: limit(.session, used: used))).tone
        }

        XCTAssertEqual(try tone(14), .healthy)
        XCTAssertEqual(try tone(75), .tight)
        XCTAssertEqual(try tone(90), .critical)
        XCTAssertEqual(try tone(100), .critical)
    }

    // MARK: - Card split

    private func snapshot(_ limits: [SnapshotLimit]) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "test",
            title: "Claude",
            service: .claudeCode,
            updatedAt: Date(),
            limits: limits,
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
    }

    func testCardSplitsDonutsFromBarsInTheirOwnOrder() {
        let card = snapshot([
            limit(.session, used: 14),
            limit(.weekly, used: 55),
            limit(.codeReview, used: 20),
            limit(.additional, used: 10)
        ])

        XCTAssertEqual(ProviderCardPresentation.donutLimits(for: card).map(\.id), ["session", "weekly"])
        XCTAssertEqual(ProviderCardPresentation.barLimits(for: card).map(\.id), ["codeReview", "additional"])
    }

    func testProviderWithOnlyPoolsKeepsAllBars() {
        let card = snapshot([limit(.additional, used: 10)])

        XCTAssertTrue(ProviderCardPresentation.donutLimits(for: card).isEmpty)
        XCTAssertEqual(ProviderCardPresentation.barLimits(for: card).count, 1)
    }

    // MARK: - Setup checklist owns an unconfigured provider

    private func offline(_ service: ServiceType, title: String) -> ProviderSnapshot {
        ProviderSnapshotBuilder.snapshot(
            title: title,
            service: service,
            metrics: nil,
            emptyDetail: "Waiting for refresh"
        )
    }

    func testOfflineCardIsHiddenWhileTheSetupChecklistNamesItsProvider() {
        let muse = offline(.museCode, title: "Muse")
        let claude = snapshot([limit(.session, used: 14)])

        let visible = PopoverOverviewPanel.visibleSnapshots([claude, muse], setupProviders: [.museCode])

        XCTAssertEqual(visible.map(\.id), [claude.id])
    }

    func testOfflineCardStaysWhenNothingElseNamesIt() {
        let muse = offline(.museCode, title: "Muse")

        XCTAssertEqual(PopoverOverviewPanel.visibleSnapshots([muse], setupProviders: []).map(\.id), [muse.id])
        XCTAssertEqual(PopoverOverviewPanel.visibleSnapshots([muse], setupProviders: [.cursor]).map(\.id), [muse.id])
    }

    func testCardsWithDataAreNeverHiddenBySetup() {
        let claude = snapshot([limit(.session, used: 14)])

        XCTAssertEqual(
            PopoverOverviewPanel.visibleSnapshots([claude], setupProviders: [.claudeCode]).map(\.id),
            [claude.id]
        )
    }

    /// With several accounts on one provider the checklist is per provider, so
    /// hiding by provider would hide an account the checklist does not name.
    func testOfflineAccountCardStaysWhenTheProviderHasSeveralCards() {
        let signedOut = offline(.codexCli, title: "Work")
        let signedIn = ProviderSnapshot(
            id: "codex-personal",
            title: "Personal",
            service: .codexCli,
            updatedAt: Date(),
            limits: [limit(.weekly, used: 15)],
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )

        let visible = PopoverOverviewPanel.visibleSnapshots([signedIn, signedOut], setupProviders: [.codexCli])

        XCTAssertEqual(visible.count, 2)
    }
}
