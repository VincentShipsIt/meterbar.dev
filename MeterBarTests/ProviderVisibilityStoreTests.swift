import MeterBarShared
import XCTest
@testable import MeterBar

final class ProviderVisibilityStoreTests: XCTestCase {
    func testOptInProvidersRequireExplicitEnablementAndPersistIt() {
        withIsolatedDefaults { defaults in
            let initial = ProviderVisibilityStore(userDefaults: defaults)
            XCTAssertFalse(initial.isEnabled(.openRouter))
            XCTAssertTrue(initial.isEnabled(.claudeCode))

            initial.set(.openRouter, isEnabled: true)
            let reloaded = ProviderVisibilityStore(userDefaults: defaults)

            XCTAssertTrue(reloaded.isEnabled(.openRouter))
        }
    }

    func testGrokIsAFirstClassProviderAndIsOnByDefault() {
        withIsolatedDefaults { defaults in
            let store = ProviderVisibilityStore(userDefaults: defaults)

            XCTAssertTrue(store.isEnabled(.grok))
        }
    }

    func testGrokCanStillBeTurnedOffAndStaysOff() {
        withIsolatedDefaults { defaults in
            let store = ProviderVisibilityStore(userDefaults: defaults)
            store.set(.grok, isEnabled: false)

            let reloaded = ProviderVisibilityStore(userDefaults: defaults)
            XCTAssertFalse(reloaded.isEnabled(.grok))

            reloaded.set(.grok, isEnabled: true)
            XCTAssertTrue(ProviderVisibilityStore(userDefaults: defaults).isEnabled(.grok))
        }
    }

    func testGrokIsUnhiddenForUsersWhoNeverChoseDuringTheOptInEra() {
        // While Grok was opt-in, `load()` inserted it into `hiddenServices` and
        // any later `save()` persisted "Grok" into the hidden list — even for
        // users who never opened the setting. Promotion has to clear that
        // implicit entry, or the whole install base would silently stay opted
        // out of a provider that is now on by default.
        withIsolatedDefaults { defaults in
            defaults.set(["Grok"], forKey: StorageKeys.hiddenProviderServices)

            let store = ProviderVisibilityStore(userDefaults: defaults)

            XCTAssertTrue(store.isEnabled(.grok))
        }
    }

    func testAnExplicitGrokOptOutSurvivesPromotion() {
        // A user who deliberately turned Grok off wrote the preference key too;
        // that decision must outlive the promotion.
        withIsolatedDefaults { defaults in
            defaults.set(["Grok"], forKey: StorageKeys.hiddenProviderServices)
            defaults.set(false, forKey: StorageKeys.grokProviderEnabled)

            let store = ProviderVisibilityStore(userDefaults: defaults)

            XCTAssertFalse(store.isEnabled(.grok))
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "ProviderVisibilityStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
