import XCTest
@testable import MeterBar

final class ClaudeCodeReconnectServiceTests: XCTestCase {
    func testDefaultProfileReconnectScriptUnsetsClaudeConfigDirectory() {
        let script = ClaudeCodeReconnectService.reconnectScript(for: .defaultAccount)

        XCTAssertTrue(script.contains("unset CLAUDE_CONFIG_DIR"))
        XCTAssertTrue(script.contains("claude auth logout || true"))
        XCTAssertTrue(script.contains("claude auth login"))
    }

    func testCustomProfileReconnectScriptExportsClaudeConfigDirectory() throws {
        let account = try ClaudeCodeAccount(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            name: "genfeedai",
            configDirectory: "/tmp/.claude-genfeedai"
        )

        let script = ClaudeCodeReconnectService.reconnectScript(for: account)

        XCTAssertTrue(script.contains("PROFILE_NAME='genfeedai'"))
        XCTAssertTrue(script.contains("export CLAUDE_CONFIG_DIR='/tmp/.claude-genfeedai'"))
        XCTAssertTrue(script.contains("claude auth logout || true"))
        XCTAssertTrue(script.contains("claude auth login"))
    }

    func testReconnectScriptShellQuotesEditableValues() throws {
        let account = try ClaudeCodeAccount(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
            name: "owner's profile",
            configDirectory: "/tmp/profile's-dir"
        )

        let script = ClaudeCodeReconnectService.reconnectScript(for: account)

        XCTAssertTrue(script.contains(#"PROFILE_NAME='owner'\''s profile'"#))
        XCTAssertTrue(script.contains(#"export CLAUDE_CONFIG_DIR='/tmp/profile'\''s-dir'"#))
    }
}
