import XCTest
@testable import MeterBar

/// Coverage for the `codex exec resume` invocation builder: exact argv shape,
/// the safe/bypass posture mapping, the bypass acknowledgement gate, and
/// CODEX_HOME injection.
final class CodexWakeCommandTests: XCTestCase {
    private func candidate(sessionID: String = "sess-1", cwd: String? = "/tmp/work") -> WakeSessionCandidate {
        WakeSessionCandidate(
            sessionID: sessionID,
            transcriptPath: "/tmp/rollout.jsonl",
            workingDirectory: cwd,
            gitBranch: nil,
            reason: .sessionLimit,
            blockedAt: Date(timeIntervalSince1970: 1_000),
            resetHint: nil,
            fingerprint: BlockFingerprint(sessionID: sessionID, blockedAt: Date(timeIntervalSince1970: 1_000), reason: .sessionLimit, provider: .codex),
            skipReason: nil,
            provider: .codex
        )
    }

    private func account(home: String? = "/custom/codex") -> CodexAccount {
        CodexAccount(id: UUID(), name: "acct", homeDirectory: home)
    }

    func testResumeArgvShapeAndPrompt() {
        let command = CodexWakeCommandBuilder.build(
            executable: "/bin/codex",
            candidate: candidate(),
            account: account(),
            bounds: .default,
            prompt: "keep going",
            baseEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(command.executable, "/bin/codex")
        // Positional subcommand + session id + prompt come first.
        XCTAssertEqual(Array(command.arguments.prefix(4)), ["exec", "resume", "sess-1", "keep going"])
    }

    func testSafeModeSetsSandboxAndApprovalOverrides() {
        let command = CodexWakeCommandBuilder.build(
            executable: "/bin/codex",
            candidate: candidate(),
            account: account(),
            bounds: .default,
            permissionMode: .safe,
            baseEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertTrue(command.arguments.contains("sandbox_mode=\"workspace-write\""))
        XCTAssertTrue(command.arguments.contains("approval_policy=\"never\""))
        XCTAssertFalse(command.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testBypassRequiresAcknowledgement() {
        let unacked = CodexWakeCommandBuilder.build(
            executable: "/bin/codex", candidate: candidate(), account: account(), bounds: .default,
            permissionMode: .bypass, bypassAcknowledged: false, baseEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertFalse(unacked.arguments.contains("--dangerously-bypass-approvals-and-sandbox"),
                       "unacknowledged bypass must downgrade to safe")
        XCTAssertTrue(unacked.arguments.contains("sandbox_mode=\"workspace-write\""))

        let acked = CodexWakeCommandBuilder.build(
            executable: "/bin/codex", candidate: candidate(), account: account(), bounds: .default,
            permissionMode: .bypass, bypassAcknowledged: true, baseEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertTrue(acked.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertFalse(acked.arguments.contains("sandbox_mode=\"workspace-write\""))
    }

    func testCodexHomeInjectedWhenAccountHasHome() {
        let command = CodexWakeCommandBuilder.build(
            executable: "/bin/codex", candidate: candidate(), account: account(home: "/custom/codex"),
            bounds: .default, baseEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(command.environment["CODEX_HOME"], "/custom/codex")
        XCTAssertEqual(command.environment["NO_COLOR"], "1")
        XCTAssertEqual(command.workingDirectory, "/tmp/work")
    }

    func testDefaultAccountOmitsCodexHome() {
        let command = CodexWakeCommandBuilder.build(
            executable: "/bin/codex", candidate: candidate(), account: account(home: nil),
            bounds: .default, baseEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertNil(command.environment["CODEX_HOME"], "default profile inherits the ambient CODEX_HOME")
    }
}
