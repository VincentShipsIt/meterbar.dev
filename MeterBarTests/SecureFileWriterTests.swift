import Darwin
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

    /// A directory can already satisfy the policy and still refuse `chmod`.
    /// `$TMPDIR` is the case that bit us: owned by the user and already 0700,
    /// but carrying the `sunlnk` system flag, so the unconditional tighten came
    /// back EPERM and every caller reported failure for a directory that was
    /// private to begin with — `WakeLock.acquire()` returned `.unavailable`
    /// purely because it tried to re-tighten a parent it did not create.
    ///
    /// `uchg` reproduces that refusal deterministically: `chmod(2)` returns
    /// EPERM for an immutable file even to its owner.
    func testEnsurePrivateDirectoryAcceptsAnExistingPrivateDirectoryItCannotChmod() throws {
        let directory = tempDirectory.appendingPathComponent("immutable-private", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setImmutable(true, at: directory)
        defer { try? setImmutable(false, at: directory) }

        XCTAssertThrowsError(
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            ),
            "precondition: chmod must be refused for this directory"
        )

        XCTAssertNoThrow(try SecureFileWriter.ensurePrivateDirectory(directory))
        XCTAssertEqual(try permissions(of: directory), 0o700)
    }

    /// The skip above is narrow on purpose. A directory that is *not* already
    /// private must still fail loudly when it cannot be tightened — silently
    /// accepting a world-readable directory would turn the S1 guard into a
    /// no-op on exactly the systems that refuse the fix.
    func testEnsurePrivateDirectoryStillThrowsWhenALooseDirectoryCannotBeTightened() throws {
        let directory = tempDirectory.appendingPathComponent("immutable-loose", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try setImmutable(true, at: directory)
        defer { try? setImmutable(false, at: directory) }

        XCTAssertThrowsError(try SecureFileWriter.ensurePrivateDirectory(directory))
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

    // MARK: - Log redaction

    /// `errorDescription` names the file, which is right in front of a human
    /// holding the URL. A `privacy: .public` log line is a different audience:
    /// everything this writer touches lives under the user's home directory, so
    /// a path published to the unified log publishes the account name with it.
    func testLogDescriptionOmitsTheHomeDirectoryPath() {
        let path = "/Users/someaccount/Library/Application Support/MeterBar/metrics.json"
        let cases: [(error: SecureFileWriterError, code: Int32)] = [
            (.create(code: EACCES, path: path), EACCES),
            (.write(code: ENOSPC, path: path), ENOSPC),
            (.replace(code: EACCES, path: path), EACCES)
        ]

        for (error, code) in cases {
            XCTAssertTrue(
                error.localizedDescription.contains(path),
                "precondition: the human-facing description is the one that names the file"
            )
            XCTAssertFalse(error.logDescription.contains(path))
            XCTAssertFalse(error.logDescription.contains("someaccount"))
            XCTAssertTrue(
                error.logDescription.contains(String(cString: strerror(code))),
                "the errno is the part an operator acts on and must survive"
            )
        }
    }

    /// The catch blocks that log see an opaque `Error`, so the shared entry
    /// point has to do the narrowing — a call site that reaches for
    /// `localizedDescription` is exactly the mistake this guards.
    func testLogDescriptionForRedactsAThrownWriterError() {
        let url = tempDirectory.appendingPathComponent("occupied")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SecureFileWriter.write(Data("x".utf8), to: url)) { error in
            let logged = SecureFileWriterError.logDescription(for: error)
            XCTAssertFalse(logged.contains(self.tempDirectory.path))
            XCTAssertFalse(logged.contains("/Users/"))
            XCTAssertFalse(logged.contains(NSHomeDirectory()))
            XCTAssertTrue(logged.hasPrefix("replace failed:"))
        }
    }

    /// Non-writer errors reach the same catch blocks — a Cocoa write error names
    /// the file and folder in its own description, and `EncodingError` names the
    /// transcript path a cache is keyed by. Domain and code name nobody.
    func testLogDescriptionForFallsBackToDomainAndCodeForOtherErrors() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "You don’t have permission to save the file in the folder /Users/someaccount/Library."
            ]
        )

        let logged = SecureFileWriterError.logDescription(for: error)

        XCTAssertEqual(logged, "\(NSCocoaErrorDomain) \(NSFileWriteNoPermissionError)")
        XCTAssertFalse(logged.contains("someaccount"))
    }

    // MARK: - Helpers

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    /// Toggles `UF_IMMUTABLE` (`uchg`). A user flag, so the owner can both set
    /// and clear it — unlike the `sunlnk` system flag on `$TMPDIR` that produced
    /// the original failure — while producing the same EPERM from `chmod(2)`.
    private func setImmutable(_ immutable: Bool, at url: URL) throws {
        let flags: UInt32 = immutable ? UInt32(UF_IMMUTABLE) : 0
        guard chflags(url.path, flags) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
            )
        }
    }
}
