import XCTest
@testable import MeterBar

final class AccountActivityInspectorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountActivityInspectorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func createEntry(named name: String, modifiedAt date: Date, isDirectory: Bool = false) throws {
        let url = tempDir.appendingPathComponent(name)
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("x".utf8).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Directory probe

    func testMissingDirectoryReturnsNil() {
        let missing = tempDir.appendingPathComponent("does-not-exist").path
        XCTAssertNil(AccountActivityInspector.lastActivity(inDirectory: missing))
    }

    func testReturnsNewestTopLevelEntryDate() throws {
        let older = Date(timeIntervalSinceNow: -3_600)
        let newest = Date(timeIntervalSinceNow: -60)
        try createEntry(named: "history.jsonl", modifiedAt: older)
        try createEntry(named: "sessions", modifiedAt: newest, isDirectory: true)
        // Pin the directory itself older than its children so the entry scan,
        // not the container mtime, must supply the answer.
        try FileManager.default.setAttributes(
            [.modificationDate: older],
            ofItemAtPath: tempDir.path
        )

        let activity = try XCTUnwrap(AccountActivityInspector.lastActivity(inDirectory: tempDir.path))
        XCTAssertEqual(activity.timeIntervalSince1970, newest.timeIntervalSince1970, accuracy: 2)
    }

    func testEmptyDirectoryFallsBackToItsOwnDate() throws {
        let pinned = Date(timeIntervalSinceNow: -7_200)
        try FileManager.default.setAttributes(
            [.modificationDate: pinned],
            ofItemAtPath: tempDir.path
        )

        let activity = try XCTUnwrap(AccountActivityInspector.lastActivity(inDirectory: tempDir.path))
        XCTAssertEqual(activity.timeIntervalSince1970, pinned.timeIntervalSince1970, accuracy: 2)
    }

    // MARK: - Path-list probe

    func testPathListReturnsNewestExistingFile() throws {
        let older = Date(timeIntervalSinceNow: -3_600)
        let newest = Date(timeIntervalSinceNow: -120)
        try createEntry(named: "state.vscdb", modifiedAt: older)
        try createEntry(named: "state.vscdb-wal", modifiedAt: newest)

        let activity = AccountActivityInspector.lastActivity(atPaths: [
            tempDir.appendingPathComponent("state.vscdb").path,
            tempDir.appendingPathComponent("state.vscdb-wal").path,
            tempDir.appendingPathComponent("missing.db").path
        ])

        let unwrapped = try XCTUnwrap(activity)
        XCTAssertEqual(unwrapped.timeIntervalSince1970, newest.timeIntervalSince1970, accuracy: 2)
    }

    func testPathListWithNoExistingFilesReturnsNil() {
        XCTAssertNil(AccountActivityInspector.lastActivity(atPaths: [
            tempDir.appendingPathComponent("nope.db").path
        ]))
    }

    // MARK: - Provider probes

    func testCodexCliActivityHonorsCodexHomeOverride() throws {
        let codexHome = tempDir.appendingPathComponent("custom-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let newest = Date(timeIntervalSinceNow: -90)
        let history = codexHome.appendingPathComponent("history.jsonl")
        try Data("{}".utf8).write(to: history)
        try FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: history.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: codexHome.path
        )

        let activity = try XCTUnwrap(AccountActivityInspector.codexCliActivity(
            environment: ["CODEX_HOME": codexHome.path],
            realHomeDirectory: tempDir.path
        ))
        XCTAssertEqual(activity.timeIntervalSince1970, newest.timeIntervalSince1970, accuracy: 2)
    }

    func testCodexHomeResolverDefaultsBlankValuesAndBuildsAuthPath() {
        let home = tempDir.path

        XCTAssertEqual(CodexHomeDirectory.path(environment: [:], realHomeDirectory: home), "\(home)/.codex")
        XCTAssertEqual(
            CodexHomeDirectory.path(environment: ["CODEX_HOME": "   "], realHomeDirectory: home),
            "\(home)/.codex"
        )
        XCTAssertEqual(
            CodexHomeDirectory.path(environment: ["CODEX_HOME": "~"], realHomeDirectory: home),
            home
        )
        XCTAssertEqual(
            CodexHomeDirectory.authFilePath(environment: ["CODEX_HOME": "~"], realHomeDirectory: home),
            "\(home)/auth.json"
        )
        XCTAssertEqual(
            CodexHomeDirectory.path(environment: ["CODEX_HOME": "/custom/codex"], realHomeDirectory: home),
            "/custom/codex"
        )
        XCTAssertEqual(
            CodexHomeDirectory.authFilePath(
                environment: ["CODEX_HOME": "/custom/codex"],
                realHomeDirectory: home
            ),
            "/custom/codex/auth.json"
        )
        XCTAssertEqual(
            CodexHomeDirectory.authFilePath(
                environment: ["CODEX_HOME": "~/custom-codex"],
                realHomeDirectory: home
            ),
            "\(home)/custom-codex/auth.json"
        )
    }

    func testCodexAuthFileDisplayPathReflectsResolvedCodexHome() {
        let home = tempDir.path

        XCTAssertEqual(
            CodexHomeDirectory.authFileDisplayPath(environment: [:], realHomeDirectory: home),
            "~/.codex/auth.json"
        )
        XCTAssertEqual(
            CodexHomeDirectory.authFileDisplayPath(
                environment: ["CODEX_HOME": "~/custom-codex"],
                realHomeDirectory: home
            ),
            "~/custom-codex/auth.json"
        )
        XCTAssertEqual(
            CodexHomeDirectory.authFileDisplayPath(
                environment: ["CODEX_HOME": "~"],
                realHomeDirectory: home
            ),
            "~/auth.json"
        )
        XCTAssertEqual(
            CodexHomeDirectory.authFileDisplayPath(
                environment: ["CODEX_HOME": "/custom/codex"],
                realHomeDirectory: home
            ),
            "/custom/codex/auth.json"
        )
    }
}
