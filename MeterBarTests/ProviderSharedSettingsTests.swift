import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class ProviderSharedSettingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderSharedSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testValuesRoundTripAndStayIndependentPerKey() {
        XCTAssertNil(ProviderSharedSettings.value(for: "a", directory: directory))

        ProviderSharedSettings.set("one", for: "a", directory: directory)
        ProviderSharedSettings.set("two", for: "b", directory: directory)

        XCTAssertEqual(ProviderSharedSettings.value(for: "a", directory: directory), "one")
        XCTAssertEqual(ProviderSharedSettings.value(for: "b", directory: directory), "two")

        ProviderSharedSettings.set(nil, for: "a", directory: directory)
        XCTAssertNil(ProviderSharedSettings.value(for: "a", directory: directory))
        XCTAssertEqual(ProviderSharedSettings.value(for: "b", directory: directory), "two")
    }

    func testMissingDirectoryIsInertNotAnError() {
        ProviderSharedSettings.set("x", for: "a", directory: nil)
        XCTAssertNil(ProviderSharedSettings.value(for: "a", directory: nil))
    }

    func testZaiRegionDefaultsToInternationalAndRoundTrips() {
        XCTAssertEqual(ZaiRegionSetting.current(directory: directory), .international)

        ZaiRegionSetting.save(.mainland, directory: directory)
        XCTAssertEqual(ZaiRegionSetting.current(directory: directory), .mainland)
    }

    func testAnUnknownStoredRegionFallsBackToInternationalNeverToAHost() {
        ProviderSharedSettings.set("https://evil.example", for: ZaiRegionSetting.key, directory: directory)

        XCTAssertEqual(ZaiRegionSetting.current(directory: directory), .international)
    }

    func testSettingsFileNeverHoldsACredential() throws {
        ZaiRegionSetting.save(.mainland, directory: directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let body = try files.map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }.joined()

        XCTAssertEqual(body, #"{"zaiCodingPlanRegion":"mainland"}"#)
    }
}
