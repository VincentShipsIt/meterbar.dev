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

    /// Claude Code, Codex CLI, and Cursor have no dedicated opt-in/opt-out key
    /// (`set` deliberately does nothing extra for them — see the `switch` in
    /// `ProviderVisibilityStore.set`); they persist solely through the generic
    /// `hiddenProviderServices` list. Unlike OpenRouter and Grok, that path had
    /// no relaunch coverage of its own.
    func testCoreProviderVisibilityTogglesPersistAcrossRelaunch() {
        withIsolatedDefaults { defaults in
            let store = ProviderVisibilityStore(userDefaults: defaults)
            XCTAssertTrue(store.isEnabled(.claudeCode))
            XCTAssertTrue(store.isEnabled(.codexCli))
            XCTAssertTrue(store.isEnabled(.cursor))

            store.set(.claudeCode, isEnabled: false)
            store.set(.cursor, isEnabled: false)

            let reloaded = ProviderVisibilityStore(userDefaults: defaults)
            XCTAssertFalse(reloaded.isEnabled(.claudeCode))
            XCTAssertTrue(reloaded.isEnabled(.codexCli))
            XCTAssertFalse(reloaded.isEnabled(.cursor))

            reloaded.set(.claudeCode, isEnabled: true)
            let relaunchedAgain = ProviderVisibilityStore(userDefaults: defaults)
            XCTAssertTrue(relaunchedAgain.isEnabled(.claudeCode))
            // Re-showing Claude Code must not resurrect the still-hidden Cursor.
            XCTAssertFalse(relaunchedAgain.isEnabled(.cursor))
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
