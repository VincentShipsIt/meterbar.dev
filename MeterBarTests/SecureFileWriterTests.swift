import XCTest
@testable import MeterBar

final class SecureFileWriterTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SecureFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Permissions

    func testWriteCreatesFileOwnerOnlyByDefault() throws {
        let url = tempDirectory.appendingPathComponent("payload.json")

        try SecureFileWriter.write(Data("{}".utf8), to: url)

        XCTAssertEqual(try permissions(of: url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
    }

    func testWriteHonoursAnExplicitExecutableMode() throws {
        let url = tempDirectory.appendingPathComponent("script.command")

        try SecureFileWriter.write("#!/bin/zsh\nexit 0\n", to: url, permissions: 0o700)

        XCTAssertEqual(try permissions(of: url), 0o700)
    }

    /// The umask is what makes a post-write `chmod` necessary in the first
    /// place, and a post-write `chmod` is exactly the window this type exists
    /// to close. Requesting a mode the umask would strip proves the mode is
    /// forced onto the descriptor rather than merely requested at `open`.
    func testRequestedModeSurvivesARestrictiveUmask() throws {
        let previous = umask(0o077)
        defer { umask(previous) }
        let url = tempDirectory.appendingPathComponent("group-readable.txt")

        try SecureFileWriter.write(Data("x".utf8), to: url, permissions: 0o640)

        XCTAssertEqual(
            try permissions(of: url),
            0o640,
            "A 0o077 umask would strip the group bit if the mode were left to open(2)"
        )
    }

    /// Regression guard for the audit's S2: an existing world-readable file
    /// must not keep its permissions just because the path already exists.
    func testWriteTightensPermissionsOnAnExistingLooseFile() throws {
        let url = tempDirectory.appendingPathComponent("legacy.json")
        FileManager.default.createFile(atPath: url.path, contents: Data("old".utf8), attributes: [
            .posixPermissions: 0o644
        ])
        XCTAssertEqual(try permissions(of: url), 0o644)

        try SecureFileWriter.write(Data("new".utf8), to: url)

        XCTAssertEqual(try permissions(of: url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
    }

    // MARK: - Atomicity

    func testWriteLeavesNoScratchFileBehind() throws {
        let url = tempDirectory.appendingPathComponent("payload.json")

        try SecureFileWriter.write(Data("{}".utf8), to: url)

        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertEqual(entries, ["payload.json"], "The staging file must be renamed, never left behind")
    }

    func testFailedWriteRemovesTheScratchFileAndPreservesTheTarget() throws {
        // A directory occupying the destination makes rename(2) fail after the
        // scratch file has already been written, exercising the cleanup path.
        let url = tempDirectory.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SecureFileWriter.write(Data("x".utf8), to: url))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "The destination must be untouched when the write fails")
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertEqual(entries, ["occupied"], "The scratch file must be unlinked when the write fails")
    }

    func testWriteFailsWhenTheParentDirectoryIsMissing() {
        let url = tempDirectory
            .appendingPathComponent("absent", isDirectory: true)
            .appendingPathComponent("payload.json")

        XCTAssertThrowsError(try SecureFileWriter.write(Data("x".utf8), to: url))
    }

    func testLargePayloadIsWrittenWhole() throws {
        // Guards the partial-write loop: a single write(2) is not required to
        // consume the whole buffer.
        let url = tempDirectory.appendingPathComponent("large.bin")
        let payload = Data(repeating: 0x41, count: 4 * 1024 * 1024)

        try SecureFileWriter.write(payload, to: url)

        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(try permissions(of: url), 0o600)
    }

    // MARK: - Directories

    func testEnsurePrivateDirectoryCreatesItOwnerOnly() throws {
        let directory = tempDirectory.appendingPathComponent("nested/private", isDirectory: true)

        try SecureFileWriter.ensurePrivateDirectory(directory)

        XCTAssertEqual(try permissions(of: directory), 0o700)
    }

    /// Regression guard for the audit's S1: the reconnect directory already
    /// existed at 0755 for every user who ran an older build, so creating it
    /// privately is not enough — an existing directory must be tightened.
    func testEnsurePrivateDirectoryTightensAnExistingLooseDirectory() throws {
        let directory = tempDirectory.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        try SecureFileWriter.ensurePrivateDirectory(directory)

        XCTAssertEqual(try permissions(of: directory), 0o700)
    }

    // MARK: - Append-only files

    func testEnsurePrivateFileCreatesAnEmptyOwnerOnlyFile() throws {
        let url = tempDirectory.appendingPathComponent("session-wake.log")

        SecureFileWriter.ensurePrivateFile(at: url)

        XCTAssertEqual(try permissions(of: url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    /// Logs are appended to, never replaced, so tightening an existing file must
    /// leave every line already written in place.
    func testEnsurePrivateFileTightensAnExistingFileWithoutTouchingItsContents() throws {
        let url = tempDirectory.appendingPathComponent("session-wake.log")
        let existing = Data("{\"event\":\"start\"}\n".utf8)
        FileManager.default.createFile(atPath: url.path, contents: existing, attributes: [
            .posixPermissions: 0o644
        ])
        XCTAssertEqual(try permissions(of: url), 0o644)

        SecureFileWriter.ensurePrivateFile(at: url)

        XCTAssertEqual(try permissions(of: url), 0o600)
        XCTAssertEqual(try Data(contentsOf: url), existing)
    }

    // MARK: - Helpers

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
