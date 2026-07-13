import MeterBarShared
import XCTest
@testable import MeterBar

final class ProviderVisibilityStoreTests: XCTestCase {
    func testOpenRouterRequiresExplicitOptInAndPersistsEnablement() {
        let suiteName = "ProviderVisibilityStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = ProviderVisibilityStore(userDefaults: defaults)
        XCTAssertFalse(initial.isEnabled(.openRouter))
        XCTAssertTrue(initial.isEnabled(.claudeCode))

        initial.set(.openRouter, isEnabled: true)
        let reloaded = ProviderVisibilityStore(userDefaults: defaults)

        XCTAssertTrue(reloaded.isEnabled(.openRouter))
    }
}
