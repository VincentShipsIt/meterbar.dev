import XCTest
@testable import MeterBar

final class CLIBinaryLocatorTests: XCTestCase {
    override func tearDown() {
        CLIBinaryLocator.resetTrustLogStateForTesting()
        super.tearDown()
    }

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

    // MARK: - trust classification

    func testEveryFallbackDirectoryIsWellKnown() {
        let home = "/Users/tester"

        for directory in CLIBinaryLocator.fallbackDirectories(home: home) {
            XCTAssertEqual(
                CLIBinaryLocator.trust(forResolvedPath: "\(directory)/claude", home: home),
                .wellKnown,
                directory
            )
        }
    }

    func testStandardSystemBinDirectoriesAreWellKnown() {
        for directory in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            XCTAssertEqual(
                CLIBinaryLocator.trust(forResolvedPath: "\(directory)/codex", home: "/Users/tester"),
                .wellKnown,
                directory
            )
        }
    }

    func testTemporaryAndDownloadsDirectoriesAreUnexpected() {
        XCTAssertEqual(
            CLIBinaryLocator.trust(forResolvedPath: "/tmp/evil/claude", home: "/Users/tester"),
            .unexpected
        )
        XCTAssertEqual(
            CLIBinaryLocator.trust(
                forResolvedPath: "/Users/tester/Downloads/codex",
                home: "/Users/tester"
            ),
            .unexpected
        )
    }

    func testDeliberateEnvironmentOverrideIsWellKnownRegardlessOfLocation() {
        let fileManager = StubExecutableFileManager(executablePaths: ["/tmp/custom/grok"])

        let resolved = CLIBinaryLocator.resolve(
            command: "grok",
            overrideEnvVar: "GROK_CLI_PATH",
            environment: ["GROK_CLI_PATH": "/tmp/custom/grok"],
            home: "/Users/tester",
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, "/tmp/custom/grok")
        XCTAssertEqual(
            CLIBinaryLocator.trust(
                forResolvedPath: "/tmp/custom/grok",
                home: "/Users/tester",
                isUserOverride: true
            ),
            .wellKnown
        )
    }

    func testTrustClassificationNormalizesRepeatedAndTrailingSlashes() {
        XCTAssertEqual(
            CLIBinaryLocator.trust(
                forResolvedPath: "//opt//homebrew//bin//claude",
                home: "/Users/tester/"
            ),
            .wellKnown
        )
        XCTAssertEqual(
            CLIBinaryLocator.trust(
                forResolvedPath: "/Users/tester//.local//bin//codex",
                home: "/Users/tester///"
            ),
            .wellKnown
        )
    }

    func testUnexpectedResolutionNoticeIsDeduplicatedByCommandAndPath() {
        let fileManager = StubExecutableFileManager(executablePaths: ["/tmp/evil/claude"])
        let arguments = (
            command: "claude",
            environment: ["PATH": "/tmp/evil"],
            home: "/Users/tester",
            fileManager: fileManager
        )

        _ = CLIBinaryLocator.resolve(
            command: arguments.command,
            environment: arguments.environment,
            home: arguments.home,
            fileManager: arguments.fileManager
        )
        _ = CLIBinaryLocator.resolve(
            command: arguments.command,
            environment: arguments.environment,
            home: arguments.home,
            fileManager: arguments.fileManager
        )

        XCTAssertEqual(CLIBinaryLocator.trustLogCountForTesting, 1)
        CLIBinaryLocator.resetTrustLogStateForTesting()
        XCTAssertEqual(CLIBinaryLocator.trustLogCountForTesting, 0)
    }
}

private final class StubExecutableFileManager: FileManager {
    private let executablePaths: Set<String>

    init(executablePaths: Set<String>) {
        self.executablePaths = executablePaths
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}
