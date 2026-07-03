import XCTest
@testable import MeterBar

final class LaunchAtLoginStoreTests: XCTestCase {
    private enum FakeError: LocalizedError {
        case boom
        var errorDescription: String? { "operation not permitted" }
    }

    /// Test double for `SMAppService.mainApp`: records calls, mutates its own
    /// status on success, and can be told to throw.
    private final class FakeController: LaunchAtLoginControlling {
        var status: LaunchAtLoginStatus
        var registerError: Error?
        var unregisterError: Error?
        private(set) var registerCallCount = 0
        private(set) var unregisterCallCount = 0

        init(status: LaunchAtLoginStatus = .notRegistered) {
            self.status = status
        }

        func currentStatus() -> LaunchAtLoginStatus { status }

        func register() throws {
            registerCallCount += 1
            if let registerError { throw registerError }
            status = .enabled
        }

        func unregister() throws {
            unregisterCallCount += 1
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    func testInitialStatusReflectsController() {
        let store = LaunchAtLoginStore(controller: FakeController(status: .enabled))
        XCTAssertTrue(store.isEnabled)
        XCTAssertNil(store.lastError)
    }

    func testEnablingRegistersAndReflectsStatus() {
        let controller = FakeController(status: .notRegistered)
        let store = LaunchAtLoginStore(controller: controller)

        store.setEnabled(true)

        XCTAssertEqual(controller.registerCallCount, 1)
        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.status, .enabled)
        XCTAssertNil(store.lastError)
    }

    func testDisablingUnregisters() {
        let controller = FakeController(status: .enabled)
        let store = LaunchAtLoginStore(controller: controller)

        store.setEnabled(false)

        XCTAssertEqual(controller.unregisterCallCount, 1)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.status, .notRegistered)
    }

    func testRegisterErrorIsSurfacedAndStatusUnchanged() {
        let controller = FakeController(status: .notRegistered)
        controller.registerError = FakeError.boom
        let store = LaunchAtLoginStore(controller: controller)

        store.setEnabled(true)

        XCTAssertFalse(store.isEnabled, "A failed register must not report enabled.")
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.lastError?.contains("enable") ?? false)
        XCTAssertTrue(store.lastError?.contains("operation not permitted") ?? false)
    }

    func testUnregisterErrorIsSurfaced() {
        let controller = FakeController(status: .enabled)
        controller.unregisterError = FakeError.boom
        let store = LaunchAtLoginStore(controller: controller)

        store.setEnabled(false)

        XCTAssertTrue(store.isEnabled, "A failed unregister leaves the item enabled.")
        XCTAssertTrue(store.lastError?.contains("disable") ?? false)
    }

    func testRefreshStatusReflectsExternalChange() {
        let controller = FakeController(status: .enabled)
        let store = LaunchAtLoginStore(controller: controller)
        XCTAssertTrue(store.isEnabled)

        // User removes the login item in System Settings behind the app's back.
        controller.status = .notRegistered
        store.refreshStatus()

        XCTAssertFalse(store.isEnabled)
    }

    func testRequiresApprovalIsNotEnabledAndExplains() {
        let store = LaunchAtLoginStore(controller: FakeController(status: .requiresApproval))
        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(store.detailText.contains("System Settings"))
    }

    func testErrorClearsOnSuccessfulRetry() {
        let controller = FakeController(status: .notRegistered)
        controller.registerError = FakeError.boom
        let store = LaunchAtLoginStore(controller: controller)
        store.setEnabled(true)
        XCTAssertNotNil(store.lastError)

        controller.registerError = nil
        store.setEnabled(true)

        XCTAssertNil(store.lastError, "A successful retry should clear the prior error.")
        XCTAssertTrue(store.isEnabled)
    }
}
