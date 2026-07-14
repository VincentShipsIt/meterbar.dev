@testable import MeterBar
import XCTest

final class FirstRunOnboardingTests: XCTestCase {
    private final class FakeLaunchController: LaunchAtLoginControlling {
        var status: LaunchAtLoginStatus = .notRegistered
        private(set) var registerCallCount = 0

        func currentStatus() -> LaunchAtLoginStatus { status }
        func register() throws {
            registerCallCount += 1
            status = .enabled
        }
        func unregister() throws { status = .notRegistered }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "FirstRunOnboardingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUpgradingExistingInstallDoesNotPresentOnboarding() {
        // An install that predates the onboarding flag has other MeterBar
        // state in defaults; it must be treated as already onboarded.
        defaults.set(true, forKey: StorageKeys.notificationsEnabled)

        let store = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )

        XCTAssertFalse(store.shouldPresent)
        XCTAssertTrue(defaults.bool(forKey: StorageKeys.hasCompletedFirstRun))
    }

    func testUpgradeMigrationRecognizesCachedMetricsSentinel() {
        defaults.set(Data("{}".utf8), forKey: StorageKeys.cachedUsageMetrics)

        let store = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )

        XCTAssertFalse(store.shouldPresent)
    }

    func testFreshInstallPresents() {
        let store = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )

        XCTAssertTrue(store.shouldPresent)
    }

    /// The core of this bug: an incidental popover close (click-away / Escape)
    /// must NOT complete onboarding. The callout keeps reappearing on the next
    /// launch until the user acts on Enable / Not Now.
    func testIncidentalDismissDoesNotCompleteOnboarding() {
        let store = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )
        XCTAssertTrue(store.shouldPresent)

        // Simulate the popover closing without the user touching the callout:
        // nothing is invoked on the onboarding store. Persistence must be
        // untouched, so a freshly reloaded store still presents the callout.
        let reloaded = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )

        XCTAssertTrue(reloaded.shouldPresent)
        XCTAssertFalse(defaults.bool(forKey: StorageKeys.hasCompletedFirstRun))
    }

    func testEnableLaunchAtLoginRegistersAndCompletesOnboarding() {
        let controller = FakeLaunchController()
        let launchAtLogin = LaunchAtLoginStore(controller: controller)
        let store = FirstRunOnboardingStore(userDefaults: defaults, launchAtLogin: launchAtLogin)

        store.chooseLaunchAtLogin(true)

        XCTAssertEqual(controller.registerCallCount, 1)
        XCTAssertTrue(launchAtLogin.isEnabled)
        XCTAssertFalse(store.shouldPresent)

        // The choice persists: a later launch does not re-present onboarding.
        XCTAssertTrue(defaults.bool(forKey: StorageKeys.hasCompletedFirstRun))
        let reloaded = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )
        XCTAssertFalse(reloaded.shouldPresent)
    }

    func testNotNowCompletesWithoutRegistering() {
        let controller = FakeLaunchController()
        let store = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: controller)
        )

        store.chooseLaunchAtLogin(false)

        XCTAssertEqual(controller.registerCallCount, 0)
        XCTAssertFalse(store.shouldPresent)

        // "Not Now" is still an explicit choice and persists across launches.
        XCTAssertTrue(defaults.bool(forKey: StorageKeys.hasCompletedFirstRun))
        let reloaded = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )
        XCTAssertFalse(reloaded.shouldPresent)
    }
}
