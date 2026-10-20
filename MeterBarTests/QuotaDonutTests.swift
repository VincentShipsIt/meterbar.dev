import MeterBarShared
import XCTest
@testable import MeterBar

/// The popover card shows every measured quota window as a donut. The pure
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

    /// A Fable or Sonnet window is a quota like any other, so it is a ring
    /// too. The popover has no progress bars for measured windows.
    func testModelAndPoolWindowsGetADonutToo() {
        XCTAssertNotNil(QuotaDonutContent(limit: limit(.codeReview, used: 14)))
        XCTAssertNotNil(QuotaDonutContent(limit: limit(.additional, used: 14)))
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

    func testCardDrawsEveryMeasuredWindowAsADonutInOrder() {
        let card = snapshot([
            limit(.session, used: 14),
            limit(.weekly, used: 55),
            limit(.codeReview, used: 20),
            limit(.additional, used: 10)
        ])

        XCTAssertEqual(
            ProviderCardPresentation.donutLimits(for: card).map(\.id),
            ["session", "weekly", "codeReview", "additional"]
        )
        XCTAssertTrue(ProviderCardPresentation.barLimits(for: card).isEmpty)
    }

    func testOnlyWindowsARingCannotShowStayBars() {
        let card = snapshot([
            limit(.weekly, used: 55),
            limit(.additional, used: 5, reading: .remainder),
            limit(.additional, used: 5, isEstimated: true)
        ])

        XCTAssertEqual(ProviderCardPresentation.donutLimits(for: card).count, 1)
        XCTAssertEqual(ProviderCardPresentation.barLimits(for: card).count, 2)
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
        XCTAssertEqual(PopoverOverviewPanel.visibleSnapshots([muse], setupProviders: [.xai]).map(\.id), [muse.id])
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

    // MARK: - Checklist freshness and the Cursor source

    private func cursorReport(_ probe: CursorDatabaseProbe) -> ProviderReadiness {
        ProviderReadinessEvaluator.cursor(CursorReadinessInput(isInstalled: true, database: probe))
    }

    private func xaiCard(limits: [SnapshotLimit]) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "xai",
            title: "shipshitdev",
            service: .xai,
            updatedAt: Date(),
            limits: limits,
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
    }

    func testLockedCursorDatabaseDoesNotNameXAIWhileAGrokCardHasUsage() {
        let locked = cursorReport(.unreadable)
        XCTAssertTrue(locked.needsSetup)

        let reports = PopoverOverviewPanel.checklistReports(
            from: [locked],
            snapshots: [xaiCard(limits: [limit(.weekly, used: 100)])]
        )

        XCTAssertTrue(reports.isEmpty)
    }

    func testCursorFailureStaysWhenXAIHasNoUsage() {
        let reports = PopoverOverviewPanel.checklistReports(
            from: [cursorReport(.unreadable)],
            snapshots: [offline(.xai, title: "xAI")]
        )

        XCTAssertEqual(reports.count, 1)
    }

    func testCardStateKeyChangesWhenACardStartsSayingSomethingElse() {
        let before = offline(.museCode, title: "Muse")
        let after = ProviderSnapshotBuilder.snapshot(
            title: "Muse",
            service: .museCode,
            metrics: nil,
            emptyDetail: "Window idle, usage not reported"
        )

        XCTAssertNotEqual(
            PopoverOverviewPanel.cardStateKey([before]),
            PopoverOverviewPanel.cardStateKey([after])
        )
        XCTAssertEqual(
            PopoverOverviewPanel.cardStateKey([before]),
            PopoverOverviewPanel.cardStateKey([before])
        )
    }
}
