import XCTest
@testable import MeterBar

/// One-flow account setup (#680): name the account, MeterBar creates the
/// profile folder and starts that provider's own CLI login scoped to it.
final class AccountSetupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AccountSetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Provider facts

    func testEachProviderScopesItsLoginWithItsOwnVariable() {
        XCTAssertEqual(AccountLoginProvider.claude.environmentVariable, "CLAUDE_CONFIG_DIR")
        XCTAssertEqual(AccountLoginProvider.codex.environmentVariable, "CODEX_HOME")
        XCTAssertEqual(AccountLoginProvider.grok.environmentVariable, "GROK_HOME")
    }

    // MARK: - Default folder

    func testDefaultDirectoryIsASlugUnderTheHomeFolder() {
        XCTAssertEqual(
            AccountSetup.defaultDirectory(for: .claude, accountName: "Work", realHomeDirectory: "/Users/tester"),
            "/Users/tester/.claude-work"
        )
        XCTAssertEqual(
            AccountSetup.defaultDirectory(for: .codex, accountName: "Side Project!", realHomeDirectory: "/Users/tester"),
            "/Users/tester/.codex-side-project"
        )
        XCTAssertEqual(
            AccountSetup.defaultDirectory(for: .grok, accountName: " Team A ", realHomeDirectory: "/Users/tester"),
            "/Users/tester/.grok-team-a"
        )
    }

    func testDefaultDirectoryFallsBackWhenTheNameHasNoUsableCharacters() {
        XCTAssertEqual(
            AccountSetup.defaultDirectory(for: .claude, accountName: "  ", realHomeDirectory: "/Users/tester"),
            "/Users/tester/.claude-account"
        )
        XCTAssertEqual(
            AccountSetup.defaultDirectory(for: .claude, accountName: "日本", realHomeDirectory: "/Users/tester"),
            "/Users/tester/.claude-account"
        )
    }

    func testDefaultDirectoryNeverPointsAtAnExistingFolder() throws {
        let home = root.path
        try FileManager.default.createDirectory(atPath: "\(home)/.claude-work", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(home)/.claude-work-2", withIntermediateDirectories: true)

        XCTAssertEqual(
            AccountSetup.defaultDirectory(for: .claude, accountName: "Work", realHomeDirectory: home),
            "\(home)/.claude-work-3"
        )
    }

    // MARK: - Folder creation

    func testPrepareDirectoryCreatesAMissingFolderOwnerOnly() throws {
        let target = root.appendingPathComponent(".claude-new").path

        let created = try AccountSetup.prepareDirectory(target)

        XCTAssertTrue(created)
        XCTAssertEqual(try permissions(atPath: target), 0o700)
    }

    func testPrepareDirectoryCreatesMissingParentsOwnerOnly() throws {
        let parent = root.appendingPathComponent("profiles").path
        let target = "\(parent)/work"

        XCTAssertTrue(try AccountSetup.prepareDirectory(target))
        XCTAssertEqual(try permissions(atPath: target), 0o700)
        XCTAssertEqual(try permissions(atPath: parent), 0o700)
    }

    /// The "pick an existing folder" path must not touch a folder the user set
    /// up by hand — their `~/.codex` may be shared with other tooling.
    func testPrepareDirectoryLeavesAnExistingFolderAndItsModeAlone() throws {
        let target = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let marker = target.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: marker)

        let created = try AccountSetup.prepareDirectory(target.path)

        XCTAssertFalse(created)
        XCTAssertEqual(try permissions(atPath: target.path), 0o755)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPrepareDirectoryRefusesAFileInThePlaceOfAFolder() throws {
        let file = root.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(try AccountSetup.prepareDirectory(file.path)) { error in
            guard case AccountSetupError.notADirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Login script (Codex, Grok)

    func testCodexLoginScriptScopesCodexHomeAndRunsCodexLogin() {
        let script = AccountSetup.loginScript(
            for: .codex,
            profileName: "Work",
            directory: "/Users/tester/.codex-work",
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/zsh"))
        XCTAssertTrue(script.contains("export CODEX_HOME='/Users/tester/.codex-work'"))
        XCTAssertTrue(script.contains("command -v codex"))
        XCTAssertTrue(script.contains("\ncodex login\n"))
        XCTAssertFalse(script.contains("grok"))
    }

    func testGrokLoginScriptScopesGrokHomeAndRunsGrokLogin() {
        let script = AccountSetup.loginScript(
            for: .grok,
            profileName: "Work",
            directory: "/Users/tester/.grok-work",
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertTrue(script.contains("export GROK_HOME='/Users/tester/.grok-work'"))
        XCTAssertTrue(script.contains("command -v grok"))
        XCTAssertTrue(script.contains("\ngrok login\n"))
        XCTAssertFalse(script.contains("codex"))
    }

    func testLoginScriptShellQuotesEditableValues() {
        let script = AccountSetup.loginScript(
            for: .codex,
            profileName: "owner's",
            directory: "/tmp/it's here",
            realHomeDirectory: "/Users/tester"
        )

        XCTAssertTrue(script.contains(#"PROFILE_NAME='owner'\''s'"#))
        XCTAssertTrue(script.contains(#"export CODEX_HOME='/tmp/it'\''s here'"#))
    }

    func testWriteLoginScriptCreatesAnOwnerOnlyExecutable() throws {
        let url = try AccountSetup.writeLoginScript(
            for: .grok,
            profileName: "Work",
            directory: "/Users/tester/.grok-work",
            in: root.appendingPathComponent("scripts", isDirectory: true)
        )

        XCTAssertEqual(try permissions(atPath: url.path), 0o700)
        XCTAssertEqual(try permissions(atPath: url.deletingLastPathComponent().path), 0o700)
        XCTAssertEqual(url.pathExtension, "command")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("grok login"))
    }

    // MARK: - Flow

    func testSetupCreatesTheFolderThenAddsTheAccountThenStartsLogin() throws {
        let target = root.appendingPathComponent(".claude-work").path
        var events: [String] = []

        let outcome = try AccountSetup.perform(
            path: target,
            startsLogin: true,
            realHomeDirectory: root.path,
            addAccount: { directory in
                events.append("add:\(directory)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: directory))
            },
            launchLogin: { directory in events.append("login:\(directory)") }
        )

        XCTAssertEqual(events, ["add:\(target)", "login:\(target)"])
        XCTAssertEqual(outcome, AccountSetupOutcome(directory: target, createdDirectory: true, loginFailure: nil))
    }

    func testSetupExpandsATildePathBeforeUsingIt() throws {
        var added: String?

        let outcome = try AccountSetup.perform(
            path: "~/.codex-work",
            startsLogin: false,
            realHomeDirectory: root.path,
            addAccount: { added = $0 },
            launchLogin: { _ in XCTFail("Login must not start") }
        )

        XCTAssertEqual(added, "\(root.path)/.codex-work")
        XCTAssertEqual(outcome.directory, "\(root.path)/.codex-work")
    }

    func testSetupCanSkipTheLoginAndStillKeepsTheAccount() throws {
        var added = false

        _ = try AccountSetup.perform(
            path: root.appendingPathComponent("a").path,
            startsLogin: false,
            realHomeDirectory: root.path,
            addAccount: { _ in added = true },
            launchLogin: { _ in XCTFail("Login must not start") }
        )

        XCTAssertTrue(added)
    }

    /// A launch failure must not undo the add: the account stays and shows as
    /// needing sign-in, so the user can retry from its row instead of re-adding.
    func testFailedLoginLaunchKeepsTheAccountAndReportsTheFailure() throws {
        struct LaunchError: LocalizedError { var errorDescription: String? { "no Terminal" } }
        var added = false

        let outcome = try AccountSetup.perform(
            path: root.appendingPathComponent("a").path,
            startsLogin: true,
            realHomeDirectory: root.path,
            addAccount: { _ in added = true },
            launchLogin: { _ in throw LaunchError() }
        )

        XCTAssertTrue(added)
        XCTAssertEqual(outcome.loginFailure, "no Terminal")
    }

    /// If the folder cannot be created nothing is added: an account pointing at
    /// a folder that does not exist would be indistinguishable from a typo.
    func testFolderFailureAddsNothingAndStartsNoLogin() throws {
        let file = root.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(
            try AccountSetup.perform(
                path: file.path,
                startsLogin: true,
                realHomeDirectory: root.path,
                addAccount: { _ in XCTFail("Account must not be added") },
                launchLogin: { _ in XCTFail("Login must not start") }
            )
        )
    }

    /// The pre-existing flow: a folder the user already set up is used as is.
    func testExistingFolderIsAddedWithoutBeingReportedAsCreated() throws {
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let outcome = try AccountSetup.perform(
            path: existing.path,
            startsLogin: false,
            realHomeDirectory: root.path,
            addAccount: { _ in },
            launchLogin: { _ in }
        )

        XCTAssertFalse(outcome.createdDirectory)
    }

    // MARK: - Helpers

    private func permissions(atPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }
}
