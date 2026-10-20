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

    // MARK: - Readiness issues ride on the cards

    private func offline(_ service: ServiceType, title: String) -> ProviderSnapshot {
        ProviderSnapshotBuilder.snapshot(
            title: title,
            service: service,
            metrics: nil,
            emptyDetail: "Waiting for refresh"
        )
    }

    private func check(_ id: String, _ level: ReadinessLevel, detail: String = "Detail") -> ReadinessCheck {
        ReadinessCheck(id: id, title: id, level: level, detail: detail, recovery: nil)
    }

    /// An unconfigured provider keeps its one card; the issues travel with it
    /// instead of filling a "Finish setup" block above the stack.
    func testOfflineCardKeepsItsSetupIssues() {
        let muse = offline(.museCode, title: "Muse")
        let claude = snapshot([limit(.session, used: 14)])
        let report = ProviderReadiness(
            provider: .museCode,
            checks: [check("installed", .pass), check("auth", .fail), check("data", .fail)]
        )

        let cards = PopoverOverviewPanel.attachingIssues(to: [claude, muse], from: [report])

        XCTAssertEqual(cards.map(\.id), [claude.id, muse.id])
        XCTAssertTrue(cards[0].issues.isEmpty)
        XCTAssertEqual(cards[1].issues.map(\.id), ["auth", "data"])
        XCTAssertEqual(cards[1].issueLevel, .fail)
    }

    func testFailingCardSaysActionNeededAndOpensItsHover() {
        var muse = offline(.museCode, title: "Muse")
        XCTAssertFalse(ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: true, snapshot: muse))

        muse.issues = [check("auth", .fail)]

        XCTAssertEqual(ProviderCardPresentation.statusText(for: muse), "Action needed")
        XCTAssertTrue(ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: true, snapshot: muse))
    }

    /// A warning alone (a slow refresh) is listed in the hover but does not put
    /// a status word on a working card.
    func testWarningsStayOutOfThePopoverCard() {
        var claude = snapshot([limit(.session, used: 14)])
        claude.issues = [check("refresh", .warn)]

        XCTAssertNil(ProviderCardPresentation.connectionStatusText(for: claude))
        XCTAssertTrue(ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: true, snapshot: claude))
    }

    /// An account report lands only on that account's card, and the
    /// provider-wide rollup of those accounts is not repeated on top of it.
    func testIssuesFollowTheirAccount() {
        let work = UUID()
        let workCard = account("codex-work", accountID: work)
        let homeCard = account("codex-home", accountID: UUID())
        let reports = [
            ProviderReadiness(identity: .account(.codexCli, id: work, name: "Work"), checks: [check("auth", .fail)]),
            ProviderReadiness(provider: .codexCli, checks: [check("auth", .fail, detail: "1 of 2 signed out")])
        ]

        let cards = PopoverOverviewPanel.attachingIssues(to: [workCard, homeCard], from: reports)

        XCTAssertEqual(cards[0].issues.map(\.detail), ["Detail"])
        XCTAssertTrue(cards[1].issues.isEmpty)
    }

    /// A provider-wide report lands on every card of the provider, and a check
    /// stated twice the same way is listed once.
    func testProviderWideIssuesReachEveryCardOnce() {
        let reports = [
            ProviderReadiness(provider: .codexCli, checks: [check("installed", .warn)]),
            ProviderReadiness(provider: .codexCli, checks: [check("installed", .warn)])
        ]

        let cards = PopoverOverviewPanel.attachingIssues(
            to: [account("codex-a", accountID: nil), account("codex-b", accountID: nil)],
            from: reports
        )

        XCTAssertEqual(cards.map { $0.issues.map(\.id) }, [["installed"], ["installed"]])
    }

    private func account(_ id: String, accountID: UUID?) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: id, service: .codexCli, updatedAt: nil, limits: [],
            emptyDetail: "", extraUsage: nil, resetCreditsAvailable: nil, accountID: accountID
        )
    }
}
