import XCTest
@testable import MeterBar

final class ClaudeCodeReconnectServiceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ClaudeCodeReconnectTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testDefaultProfileReconnectScriptExportsEffectiveConfigDirectory() {
        let script = ClaudeCodeReconnectService.reconnectScript(
            for: .defaultAccount,
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/.claude-genfeedai"],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertTrue(script.contains("export CLAUDE_CONFIG_DIR='/tmp/.claude-genfeedai'"))
        XCTAssertTrue(script.contains("claude auth logout || true"))
        XCTAssertTrue(script.contains("claude auth login"))
    }

    func testUnscopedDefaultProfileReconnectScriptPinsHomeConfigDirectory() {
        let script = ClaudeCodeReconnectService.reconnectScript(
            for: .defaultAccount,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertTrue(script.contains("export CLAUDE_CONFIG_DIR='/Users/tester/.claude'"))
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

    // MARK: - Script file

    /// The script is handed to `open -a Terminal` and executed, so any window
    /// in which it is group- or world-writable is a window in which another
    /// local process can choose what the user's shell runs.
    func testWriteReconnectScriptCreatesAnOwnerOnlyExecutable() throws {
        let url = try ClaudeCodeReconnectService.writeReconnectScript(
            for: .defaultAccount,
            in: tempDirectory
        )

        XCTAssertEqual(try permissions(of: url), 0o700)
        XCTAssertEqual(try permissions(of: tempDirectory), 0o700)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("#!/bin/zsh"))
    }

    func testWriteReconnectScriptTightensAPreExistingWorldReadableDirectory() throws {
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        _ = try ClaudeCodeReconnectService.writeReconnectScript(for: .defaultAccount, in: tempDirectory)

        XCTAssertEqual(try permissions(of: tempDirectory), 0o700)
    }

    func testWriteReconnectScriptReplacesAStaleScriptForTheSameAccount() throws {
        let first = try ClaudeCodeReconnectService.writeReconnectScript(
            for: .defaultAccount,
            in: tempDirectory
        )
        try Data("stale".utf8).write(to: first)

        let second = try ClaudeCodeReconnectService.writeReconnectScript(
            for: .defaultAccount,
            in: tempDirectory
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(try permissions(of: second), 0o700)
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).hasPrefix("#!/bin/zsh"))
    }

    // MARK: - Purge

    func testWriteReconnectScriptPurgesExpiredScripts() throws {
        let stale = try plantScript(named: "reconnect-stale.command", ageInHours: 26)

        _ = try ClaudeCodeReconnectService.writeReconnectScript(for: .defaultAccount, in: tempDirectory)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stale.path),
            "Reconnect scripts must not accumulate in the temporary directory indefinitely"
        )
    }

    func testWriteReconnectScriptKeepsRecentScriptsForOtherAccounts() throws {
        let recent = try plantScript(named: "reconnect-recent.command", ageInHours: 1)

        _ = try ClaudeCodeReconnectService.writeReconnectScript(for: .defaultAccount, in: tempDirectory)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recent.path),
            "A script a Terminal window may still be executing must survive the purge"
        )
    }

    func testPurgeReconnectScriptsLeavesUnrelatedFilesAlone() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let stale = try plantScript(named: "reconnect-stale.command", ageInHours: 26)
        let bystander = try plantScript(named: "notes.txt", ageInHours: 26)

        ClaudeCodeReconnectService.purgeReconnectScripts(in: tempDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path))
    }

    func testPurgeReconnectScriptsToleratesAMissingDirectory() {
        ClaudeCodeReconnectService.purgeReconnectScripts(
            in: tempDirectory.appendingPathComponent("absent", isDirectory: true)
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func plantScript(named name: String, ageInHours: Double) throws -> URL {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let url = tempDirectory.appendingPathComponent(name)
        try Data("planted".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -ageInHours * 3600)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
