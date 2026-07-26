import XCTest
@testable import MeterBar

final class ServeBindConfigurationTests: XCTestCase {
    func testDefaultResolutionBindsToLoopbackWithoutWarning() {
        let resolution = ServeBindConfiguration.resolve(allowRemote: false)

        XCTAssertEqual(resolution.host, "127.0.0.1")
        XCTAssertFalse(resolution.isRemoteExposed)
        XCTAssertNil(resolution.warning)
    }

    func testAllowRemoteBindsToAllInterfacesAndWarns() {
        let resolution = ServeBindConfiguration.resolve(allowRemote: true)

        XCTAssertEqual(resolution.host, "0.0.0.0")
        XCTAssertTrue(resolution.isRemoteExposed)
        let warning = try? XCTUnwrap(resolution.warning)
        XCTAssertTrue(warning?.localizedCaseInsensitiveContains("network") ?? false)
        XCTAssertTrue(warning?.localizedCaseInsensitiveContains("reachable") ?? false)
    }
}
