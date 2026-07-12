import XCTest
@testable import MeterBar

final class ClaudeCodeCLIUsageServiceTests: XCTestCase {
    /// The spawned `claude` must get an augmented PATH: under launchd's bare
    /// GUI PATH the CLI itself launches but cannot find `node`, prints a cost
    /// summary instead of the usage screen, and parsing fails with
    /// "No Claude usage windows found".
    func testProcessEnvironmentAugmentsPATH() {
        let environment = ClaudeCodeCLIUsageService.shared.processEnvironment(
            account: .defaultAccount,
            base: ["PATH": "/usr/bin:/bin"]
        )

        let path = environment["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix("/usr/bin:/bin"), "Inherited PATH entries must keep priority")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "Homebrew bin dir must be reachable for node")
    }

    func testProcessEnvironmentSetsPlainTerminalAndConfigDirectory() {
        let account = ClaudeCodeAccount(id: UUID(), name: "alt", configDirectory: "/tmp/claude-alt")
        let environment = ClaudeCodeCLIUsageService.shared.processEnvironment(
            account: account,
            base: [:]
        )

        XCTAssertEqual(environment["NO_COLOR"], "1")
        XCTAssertEqual(environment["TERM"], "dumb")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/claude-alt")
    }
}
