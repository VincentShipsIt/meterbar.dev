import XCTest
@testable import MeterBar

final class WakeTranscriptScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WakeTranscriptScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRootExpandsTildePrefixedOverrideForBothProviders() {
        let standardized = ("~/some-dir" as NSString).standardizingPath
        let claude = WakeTranscriptScanner.root(
            override: "~/some-dir",
            defaultHome: ".claude",
            subdirectory: "projects"
        )
        let codex = WakeTranscriptScanner.root(
            override: "~/some-dir",
            defaultHome: ".codex",
            subdirectory: "sessions"
        )

        XCTAssertEqual(claude.path, "\(standardized)/projects")
        XCTAssertEqual(codex.path, "\(standardized)/sessions")
    }

    func testRootCollapsesParentComponentsAndStripsTrailingSlash() {
        let override = "\(tempDir.path)/parent/../target/"
        let root = WakeTranscriptScanner.root(
            override: override,
            defaultHome: ".claude",
            subdirectory: "projects"
        )

        XCTAssertEqual(root.path, "\(tempDir.path)/target/projects")
        XCTAssertFalse(root.path.hasSuffix("/"))
    }

    func testRootFallsBackForNilEmptyAndWhitespaceOnlyOverrides() {
        let realHome = ServiceSupport.realHomeDirectory()
        let overrides: [String?] = [nil, "", " \n\t "]

        for override in overrides {
            XCTAssertEqual(
                WakeTranscriptScanner.root(
                    override: override,
                    defaultHome: ".claude",
                    subdirectory: "projects"
                ).path,
                "\(realHome)/.claude/projects"
            )
            XCTAssertEqual(
                WakeTranscriptScanner.root(
                    override: override,
                    defaultHome: ".codex",
                    subdirectory: "sessions"
                ).path,
                "\(realHome)/.codex/sessions"
            )
        }
    }

    func testTranscriptURLsOptionallyPrunesSubagentSubtree() throws {
        let project = tempDir.appendingPathComponent("project")
        let subagents = project.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let main = project.appendingPathComponent("main.jsonl")
        let child = subagents.appendingPathComponent("child.jsonl")
        try Data("main".utf8).write(to: main)
        try Data("child".utf8).write(to: child)

        let scanner = WakeTranscriptScanner()
        let now = Date()
        let pruned = scanner.transcriptURLs(under: tempDir, now: now, prunesSubagents: true)
        let unpruned = scanner.transcriptURLs(under: tempDir, now: now, prunesSubagents: false)

        XCTAssertEqual(normalized(pruned), normalized([main]))
        XCTAssertEqual(Set(normalized(unpruned)), Set(normalized([main, child])))
    }

    func testTranscriptURLsHonorsAgeCapAndDeterministicOrdering() throws {
        let now = Date()
        let a = try writeTranscript(named: "a", modified: now)
        let b = try writeTranscript(named: "b", modified: now)
        let older = try writeTranscript(named: "older", modified: now.addingTimeInterval(-50))
        let stale = try writeTranscript(named: "stale", modified: now.addingTimeInterval(-101))

        let capped = WakeTranscriptScanner(configuration: .init(maxTranscriptAge: 100, maxTranscripts: 2))
        XCTAssertEqual(
            normalized(capped.transcriptURLs(under: tempDir, now: now, prunesSubagents: false)),
            normalized([a, b])
        )

        let uncapped = WakeTranscriptScanner(configuration: .init(maxTranscriptAge: 100, maxTranscripts: 10))
        let ageBounded = normalized(
            uncapped.transcriptURLs(under: tempDir, now: now, prunesSubagents: false)
        )
        XCTAssertEqual(ageBounded, normalized([a, b, older]))
        XCTAssertFalse(ageBounded.contains(normalized(stale)))
    }

    func testReadTailRespectsByteLimitAndLossilyDecodesSplitMultibyteCharacter() throws {
        let url = tempDir.appendingPathComponent("tail.jsonl")
        try Data("prefix🙂\nlast\n".utf8).write(to: url)
        let scanner = WakeTranscriptScanner(configuration: .init(maxTailBytes: 8))

        let lines = try XCTUnwrap(scanner.readTail(of: url))

        XCTAssertEqual(lines.last, "last")
        XCTAssertFalse(lines.joined().contains("prefix"))
        XCTAssertTrue(lines.first?.contains("\u{FFFD}") == true)
    }

    func testResolveWorkingDirectoryReportsMissingAndResolvesSymlinks() throws {
        let scanner = WakeTranscriptScanner()

        XCTAssertNil(scanner.resolveWorkingDirectory(nil).0)
        XCTAssertEqual(scanner.resolveWorkingDirectory(nil).1, .unknownWorkingDirectory)
        XCTAssertEqual(scanner.resolveWorkingDirectory("").1, .unknownWorkingDirectory)

        let missing = tempDir.appendingPathComponent("missing")
        XCTAssertEqual(scanner.resolveWorkingDirectory(missing.path).1, .missingWorkingDirectory)

        let file = tempDir.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertEqual(scanner.resolveWorkingDirectory(file.path).1, .missingWorkingDirectory)

        let real = tempDir.appendingPathComponent("real")
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let resolved = scanner.resolveWorkingDirectory(link.path)

        XCTAssertEqual(resolved.0, real.resolvingSymlinksInPath().path)
        XCTAssertNil(resolved.1)
    }

    func testDiscoveryDirectorySeamsAgreeOnTildeHandling() {
        let standardized = ("~/x" as NSString).standardizingPath
        let claude = SessionDiscovery.projectsDirectory(configDirectory: "~/x")
        let codex = CodexSessionDiscovery.sessionsDirectory(codexHome: "~/x")

        XCTAssertEqual(claude.path, "\(standardized)/projects")
        XCTAssertEqual(codex.path, "\(standardized)/sessions")
        XCTAssertEqual(claude.deletingLastPathComponent(), codex.deletingLastPathComponent())
    }

    func testSupersedesAndCandidateSetUseLatestThenLexicographicallyFirstPath() {
        let instant = Date(timeIntervalSince1970: 1_900_000_000)
        let earlier = candidate(sessionID: "latest", path: "/a", blockedAt: instant)
        let later = candidate(sessionID: "latest", path: "/z", blockedAt: instant.addingTimeInterval(1))
        XCTAssertTrue(WakeTranscriptScanner.supersedes(later, earlier))
        XCTAssertFalse(WakeTranscriptScanner.supersedes(earlier, later))

        var latest = WakeTranscriptScanner.CandidateSet()
        latest.insert(later)
        latest.insert(earlier)
        XCTAssertEqual(latest.sorted.map(\.transcriptPath), ["/z"])

        let lexicalFirst = candidate(sessionID: "tie", path: "/a", blockedAt: instant)
        let lexicalLast = candidate(sessionID: "tie", path: "/z", blockedAt: instant)
        XCTAssertTrue(WakeTranscriptScanner.supersedes(lexicalFirst, lexicalLast))

        var tied = WakeTranscriptScanner.CandidateSet()
        tied.insert(lexicalLast)
        tied.insert(lexicalFirst)
        XCTAssertEqual(tied.sorted.map(\.transcriptPath), ["/a"])
    }

    /// `FileManager.enumerator` yields canonical `/private/var/...` URLs while
    /// `temporaryDirectory` yields the `/var/...` symlink form. Both sides go
    /// through the same resolution so these assertions stay about ordering and
    /// pruning rather than about macOS path aliasing.
    private func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private func normalized(_ urls: [URL]) -> [String] {
        urls.map(normalized)
    }

    private func writeTranscript(named name: String, modified: Date) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).jsonl")
        try Data(name.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func candidate(sessionID: String, path: String, blockedAt: Date) -> WakeSessionCandidate {
        let fingerprint = BlockFingerprint(
            sessionID: sessionID,
            blockedAt: blockedAt,
            reason: .sessionLimit
        )
        return WakeSessionCandidate(
            sessionID: sessionID,
            transcriptPath: path,
            workingDirectory: nil,
            gitBranch: nil,
            reason: .sessionLimit,
            blockedAt: blockedAt,
            resetHint: nil,
            fingerprint: fingerprint,
            skipReason: .unknownWorkingDirectory
        )
    }
}
