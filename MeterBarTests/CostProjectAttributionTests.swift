import XCTest
@testable import MeterBar

/// Unit tests for `CostProjectAttribution` — the pure, path-only project/worktree
/// identifier derivation behind issue #270. Every case must resolve to exactly
/// one bucket, including the explicit `unknown` fallback; nothing is ever dropped.
final class CostProjectAttributionTests: XCTestCase {
    private let home = ServiceSupport.realHomeDirectory()

    // MARK: - Claude (encoded directory name)

    func testClaudeProjectIDDecodesEncodedWorkingDirectoryUnderHome() {
        let root = URL(fileURLWithPath: "\(home)/.claude/projects")
        let encodedHome = "-" + home.split(separator: "/").joined(separator: "-")
        let encodedDir = "\(encodedHome)-www-vincentshipsit-public-meterbardev"
        let transcript = root.appendingPathComponent(encodedDir).appendingPathComponent("session-1.jsonl")

        let projectID = CostProjectAttribution.claudeProjectID(forTranscriptURL: transcript, root: root)

        XCTAssertEqual(projectID, "www/vincentshipsit/public/meterbardev")
    }

    func testClaudeProjectIDFallsBackToUnknownWhenHomePrefixDoesNotMatch() {
        let root = URL(fileURLWithPath: "\(home)/.claude/projects")
        // No encoded-home prefix at all — can't be a Claude-style project dir.
        let transcript = root.appendingPathComponent("garbage").appendingPathComponent("session-1.jsonl")

        let projectID = CostProjectAttribution.claudeProjectID(forTranscriptURL: transcript, root: root)

        XCTAssertEqual(projectID, CostProjectAttribution.unknownProjectID)
    }

    func testClaudeProjectIDFallsBackToUnknownWhenFileIsOutsideRoot() {
        let root = URL(fileURLWithPath: "\(home)/.claude/projects")
        let outsideFile = URL(fileURLWithPath: "/var/tmp/session-1.jsonl")

        let projectID = CostProjectAttribution.claudeProjectID(forTranscriptURL: outsideFile, root: root)

        XCTAssertEqual(projectID, CostProjectAttribution.unknownProjectID)
    }

    func testClaudeProjectIDFallsBackToUnknownWhenEncodedDirectoryIsExactlyHome() {
        let root = URL(fileURLWithPath: "\(home)/.claude/projects")
        let encodedHome = "-" + home.split(separator: "/").joined(separator: "-")
        // The directory is the home prefix with nothing left over.
        let transcript = root.appendingPathComponent(encodedHome).appendingPathComponent("session-1.jsonl")

        let projectID = CostProjectAttribution.claudeProjectID(forTranscriptURL: transcript, root: root)

        XCTAssertEqual(projectID, CostProjectAttribution.unknownProjectID)
    }

    // MARK: - Codex (real cwd)

    func testCodexProjectIDStripsRealHomePrefix() {
        let cwd = "\(home)/www/genfeed/apps/admin"

        let projectID = CostProjectAttribution.codexProjectID(cwd: cwd)

        XCTAssertEqual(projectID, "www/genfeed/apps/admin")
    }

    func testCodexProjectIDFallsBackToUnknownWhenCwdIsNil() {
        XCTAssertEqual(CostProjectAttribution.codexProjectID(cwd: nil), CostProjectAttribution.unknownProjectID)
    }

    func testCodexProjectIDFallsBackToUnknownWhenCwdIsEmptyOrBlank() {
        XCTAssertEqual(CostProjectAttribution.codexProjectID(cwd: ""), CostProjectAttribution.unknownProjectID)
        XCTAssertEqual(CostProjectAttribution.codexProjectID(cwd: "   "), CostProjectAttribution.unknownProjectID)
    }

    func testCodexProjectIDFallsBackToUnknownWhenCwdIsOutsideHome() {
        XCTAssertEqual(
            CostProjectAttribution.codexProjectID(cwd: "/var/tmp/some-project"),
            CostProjectAttribution.unknownProjectID
        )
    }

    func testCodexProjectIDFallsBackToUnknownWhenCwdIsExactlyHome() {
        XCTAssertEqual(CostProjectAttribution.codexProjectID(cwd: home), CostProjectAttribution.unknownProjectID)
    }
}
