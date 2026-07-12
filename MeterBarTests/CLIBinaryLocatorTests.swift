import XCTest
@testable import MeterBar

final class CLIBinaryLocatorTests: XCTestCase {
    // MARK: - augmentedPATH

    /// GUI apps inherit launchd's bare PATH; the spawned CLI must still be able
    /// to find its runtime (e.g. `node` in /opt/homebrew/bin).
    func testAugmentedPATHAppendsFallbackDirectoriesAfterExistingEntries() {
        let path = CLIBinaryLocator.augmentedPATH(
            environment: ["PATH": "/usr/bin:/bin"],
            home: "/Users/tester"
        )

        XCTAssertTrue(path.hasPrefix("/usr/bin:/bin:"), "Existing PATH entries must keep priority")
        let entries = path.split(separator: ":").map(String.init)
        XCTAssertTrue(entries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(entries.contains("/usr/local/bin"))
        XCTAssertTrue(entries.contains("/Users/tester/.local/bin"))
    }

    func testAugmentedPATHDoesNotDuplicateEntriesAlreadyOnPATH() {
        let path = CLIBinaryLocator.augmentedPATH(
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin"],
            home: "/Users/tester"
        )

        let entries = path.split(separator: ":").map(String.init)
        XCTAssertEqual(entries.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertEqual(entries.first, "/opt/homebrew/bin", "User-chosen ordering must be preserved")
    }

    func testAugmentedPATHWithEmptyEnvironmentReturnsFallbackDirectories() {
        let path = CLIBinaryLocator.augmentedPATH(environment: [:], home: "/Users/tester")

        let entries = path.split(separator: ":").map(String.init)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.first, "/opt/homebrew/bin")
        XCTAssertFalse(entries.contains(""), "No empty segments from a missing PATH")
    }
}
