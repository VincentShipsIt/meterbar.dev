import Foundation
import MeterBarShared
import XCTest

@testable import MeterBar

/// The "Live" chip means "automatic failover is routing the CLI to this
/// account". It must not appear while failover is switched off, even though
/// the coordinator keeps recording which credential the CLI is signed in as.
final class ProviderCardLiveAccountTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "ProviderCardLiveAccountTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    private func snapshot(
        service: ServiceType = .codexCli,
        accountID: UUID?,
        cardRole: ProviderSnapshot.CardRole = .account
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "codex",
            title: "Codex",
            service: service,
            updatedAt: nil,
            limits: [],
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: accountID,
            cardRole: cardRole
        )
    }

    func testLiveChipHiddenWhileFailoverIsOffEvenIfAccountIsTheActiveCredential() {
        let store = AccountFailoverSettingsStore(userDefaults: defaults)
        let accountID = UUID()
        store.setActiveAccountID(accountID, for: .codexCli)

        XCTAssertFalse(ProviderCardPresentation.showsLiveAccount(
            for: snapshot(accountID: accountID),
            failoverSettings: store
        ))
    }

    func testLiveChipShownForActiveAccountWhileFailoverIsOn() {
        let store = AccountFailoverSettingsStore(userDefaults: defaults)
        let active = UUID()
        let other = UUID()
        store.setEnabled(true, for: .codexCli)
        store.setActiveAccountID(active, for: .codexCli)

        XCTAssertTrue(ProviderCardPresentation.showsLiveAccount(
            for: snapshot(accountID: active),
            failoverSettings: store
        ))
        XCTAssertFalse(ProviderCardPresentation.showsLiveAccount(
            for: snapshot(accountID: other),
            failoverSettings: store
        ))
    }

    func testLiveChipNeverShownForSubPoolOrUnsupportedProviders() {
        let store = AccountFailoverSettingsStore(userDefaults: defaults)
        let accountID = UUID()
        store.setEnabled(true, for: .codexCli)
        store.setActiveAccountID(accountID, for: .codexCli)

        XCTAssertFalse(ProviderCardPresentation.showsLiveAccount(
            for: snapshot(accountID: accountID, cardRole: .subPool),
            failoverSettings: store
        ))
        XCTAssertFalse(ProviderCardPresentation.showsLiveAccount(
            for: snapshot(service: .cursor, accountID: accountID),
            failoverSettings: store
        ))
    }
}
