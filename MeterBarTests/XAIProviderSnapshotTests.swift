import XCTest
@testable import MeterBar
import MeterBarShared

/// The single xAI card speaks for two data sources (Grok CLI billing and the
/// Cursor dashboard). These pin its empty-state copy and connection health so
/// one healthy source never gets flagged for the other's missing login.
final class XAIProviderSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func metrics(updated: Date? = nil) -> UsageMetrics {
        UsageMetrics(
            service: .xai,
            weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
            lastUpdated: updated ?? now
        )
    }

    private func input(
        withMetrics: Bool = true,
        grokAccounts: [GrokAccount] = [.defaultAccount],
        grokHasAccess: Bool = false,
        cursorHasAccess: Bool? = nil,
        grokProbed: Bool? = nil,
        grokError: ServiceError? = nil,
        cursorError: ServiceError? = nil
    ) -> ProviderSnapshotBuilder.Input {
        var input = ProviderSnapshotBuilder.Input(
            metrics: withMetrics ? [.xai: metrics()] : [:],
            now: now,
            grokAccounts: grokAccounts,
            claudeAccounts: [],
            claudeAccountMetrics: [:],
            enabledServices: [.xai],
            cursorHasAccess: cursorHasAccess,
            grokHasAccess: grokHasAccess
        )
        if let grokProbed {
            for account in grokAccounts { input.grokAccountAccess[account.id] = grokProbed }
        }
        if let grokError {
            for account in grokAccounts { input.lastErrors.grokAccounts[account.id] = grokError }
        }
        input.lastErrors.cursor = cursorError
        return input
    }

    private func onlyCard(_ input: ProviderSnapshotBuilder.Input) throws -> ProviderSnapshot {
        let cards = ProviderSnapshotBuilder.snapshots(input)
        XCTAssertEqual(cards.count, 1)
        return try XCTUnwrap(cards.first)
    }

    // MARK: Empty-state copy

    func testEmptyCardPointsAtGrokLoginWhenNeitherSourceIsConnected() throws {
        let card = try onlyCard(input(withMetrics: false))
        XCTAssertEqual(card.emptyDetail, "Run grok login")
    }

    func testEmptyCardWaitsForRefreshOnceGrokIsConnected() throws {
        let card = try onlyCard(input(withMetrics: false, grokHasAccess: true))
        XCTAssertEqual(card.emptyDetail, "Waiting for refresh")
    }

    func testEmptyCardWaitsForRefreshWhenOnlyCursorIsConnected() throws {
        let card = try onlyCard(input(withMetrics: false, cursorHasAccess: true))
        XCTAssertEqual(card.emptyDetail, "Waiting for refresh")
    }

    func testConfirmedSignedOutCursorDoesNotSuppressTheLoginPrompt() throws {
        let card = try onlyCard(input(withMetrics: false, cursorHasAccess: false))
        XCTAssertEqual(card.emptyDetail, "Run grok login")
    }

    func testCustomGrokProfileNeverInheritsTheDefaultCardsConnection() throws {
        let work = GrokAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/grok-work")
        let cards = ProviderSnapshotBuilder.snapshots(input(
            withMetrics: false,
            grokAccounts: [.defaultAccount, work],
            grokHasAccess: true,
            cursorHasAccess: true
        ))
        XCTAssertEqual(cards.map(\.emptyDetail), ["Waiting for refresh", "Run grok login"])
    }

    // MARK: Connection health

    func testOneHealthySourceKeepsTheCardQuiet() throws {
        // Grok signed in, Cursor never set up and erroring: no notice.
        let card = try onlyCard(input(
            cursorHasAccess: false,
            grokProbed: true,
            cursorError: .notAuthenticated
        ))
        XCTAssertNil(card.authNotice)
    }

    func testCursorAloneIsEnoughToStayQuiet() throws {
        let card = try onlyCard(input(
            cursorHasAccess: true,
            grokProbed: false,
            grokError: .notAuthenticated
        ))
        XCTAssertNil(card.authNotice)
    }

    func testBothSourcesSignedOutAsksForLogin() throws {
        let card = try onlyCard(input(cursorHasAccess: false, grokProbed: false))
        XCTAssertEqual(card.authNotice, .loginRequired)
    }

    func testSignedOutGrokWithUnprobedCursorAsksForLogin() throws {
        let card = try onlyCard(input(grokProbed: false))
        XCTAssertEqual(card.authNotice, .loginRequired)
    }

    func testNotAuthenticatedErrorWithoutAProbeAsksForLogin() throws {
        let card = try onlyCard(input(grokError: .notAuthenticated))
        XCTAssertEqual(card.authNotice, .loginRequired)
    }

    func testCustomProfileFailureIsNotMaskedByTheDefaultCardsHealthySource() throws {
        let work = GrokAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/grok-work")
        var request = input(
            grokAccounts: [.defaultAccount, work],
            cursorHasAccess: true,
            grokProbed: true
        )
        request.grokAccountMetrics[work.id] = metrics()
        request.grokAccountAccess[work.id] = false

        let cards = ProviderSnapshotBuilder.snapshots(request)
        XCTAssertEqual(cards.count, 2)
        XCTAssertNil(cards[0].authNotice)
        XCTAssertEqual(cards[1].authNotice, .loginRequired)
    }

    func testCursorOnlyUserStillGetsACardWithoutAnyGrokProfile() throws {
        var request = input(grokAccounts: [], cursorHasAccess: true)
        request.metrics[.xai] = metrics()
        let card = try onlyCard(request)
        XCTAssertNil(card.accountID)
        XCTAssertEqual(card.title, ServiceType.xai.shortName)
        XCTAssertTrue(card.hasMetrics)
    }
}
