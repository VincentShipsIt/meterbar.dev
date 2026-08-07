import Foundation
import XCTest
@testable import MeterBar

final class CostScanFileCacheSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanFileCacheSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    func testAtomicReplacementWithSameSizeAndMtimeChangesFileIdentity() throws {
        let file = directory.appendingPathComponent("session.jsonl")
        let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)
        try Data("aaaa".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        let before = try XCTUnwrap(CostScanFileStamp.read(at: file))

        try Data("bbbb".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        let after = try XCTUnwrap(CostScanFileStamp.read(at: file))

        guard let beforeID = before.fileID, let afterID = after.fileID else {
            throw XCTSkip("volume does not expose file identifiers")
        }
        guard beforeID != afterID else {
            throw XCTSkip("atomic write retained the file identifier on this volume")
        }
        XCTAssertEqual(before.size, after.size)
        XCTAssertEqual(before.modified, after.modified)
        XCTAssertFalse(before.matches(after))
        XCTAssertFalse(before.isSameFile(as: after))
    }

    func testCacheRejectsParserAndTimeZoneMismatches() throws {
        let url = directory.appendingPathComponent(CostScanCacheStore.claudeFileName)
        try CostScanCacheStore.saveClaude(makeCache(), to: url)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["parserVersion"] = CostScanValues.costCacheParserVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertTrue(CostScanCacheStore.loadClaude(from: url).records.isEmpty)

        try CostScanCacheStore.saveClaude(makeCache(), to: url)
        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["timeZoneIdentifier"] = "Etc/Definitely-Not-Current"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertTrue(CostScanCacheStore.loadClaude(from: url).records.isEmpty)
    }

    func testArtifactBudgetIsCheckedBeforeDecodeAndBeforeWrite() throws {
        let url = directory.appendingPathComponent(CostScanCacheStore.claudeFileName)
        try CostScanCacheStore.saveClaude(makeCache(), to: url)
        let original = try Data(contentsOf: url)

        XCTAssertEqual(
            CostScanCacheStore.loadClaude(from: url, maximumBytes: original.count).records.count,
            1
        )
        XCTAssertTrue(
            CostScanCacheStore.loadClaude(from: url, maximumBytes: original.count - 1).records.isEmpty
        )
        XCTAssertThrowsError(
            try CostScanCacheStore.saveClaude(makeCache(), to: url, maximumBytes: original.count - 1)
        )
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testVersionedSaveRemovesSupersededSiblings() throws {
        let oldClaude = directory.appendingPathComponent("cost-scan-claude-v1.json")
        let oldCodex = directory.appendingPathComponent("cost-scan-codex-v2.json")
        try Data("old".utf8).write(to: oldClaude)
        try Data("other-provider".utf8).write(to: oldCodex)

        let store = CostScanCacheStore(directory: directory)
        try store.saveClaude(makeCache())

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldClaude.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldCodex.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(CostScanCacheStore.claudeFileName).path
            )
        )
    }

    // MARK: - Persistence failures

    /// A cache that cannot be encoded must say so rather than leave the caller
    /// believing the slice's offsets are on disk. `.infinity` is the cheapest
    /// real trigger: `JSONEncoder` rejects non-conforming floats by default.
    func testEncodingFailureIsReportedAndWritesNothing() throws {
        var cache = makeCache()
        cache.records["/tmp/session.jsonl"]?.payload.period.estimatedCost = .infinity
        let url = directory.appendingPathComponent(CostScanCacheStore.claudeFileName)

        XCTAssertThrowsError(try CostScanCacheStore.saveClaude(cache, to: url)) { error in
            guard let error = error as? CostScanCacheStoreError, case .encodingFailed = error else {
                XCTFail("expected an encoding failure, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDirectorySetupFailureIsReportedAndASuccessfulRetryPersists() throws {
        // A regular file where the cache directory's parent belongs: creating
        // the directory underneath it cannot succeed.
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocker)
        let store = CostScanCacheStore(directory: blocker.appendingPathComponent("MeterBar", isDirectory: true))

        XCTAssertThrowsError(try store.saveClaude(makeCache())) { error in
            guard let error = error as? CostScanCacheStoreError, case .directoryUnavailable = error else {
                XCTFail("expected a directory failure, got \(error)")
                return
            }
        }

        try FileManager.default.removeItem(at: blocker)

        XCTAssertNoThrow(try store.saveClaude(makeCache()))
        XCTAssertEqual(store.loadClaude().records.count, 1)
    }

    func testWriteFailureIsReportedAndASuccessfulRetryPersists() throws {
        // The cache directory's path is taken by a regular file, so staging the
        // atomic write inside it fails.
        let occupied = directory.appendingPathComponent("MeterBar")
        try Data("occupied".utf8).write(to: occupied)
        let store = CostScanCacheStore(directory: occupied)

        XCTAssertThrowsError(try store.saveClaude(makeCache())) { error in
            guard let error = error as? CostScanCacheStoreError, case .writeFailed = error else {
                XCTFail("expected a write failure, got \(error)")
                return
            }
        }

        try FileManager.default.removeItem(at: occupied)

        XCTAssertNoThrow(try store.saveClaude(makeCache()))
        XCTAssertEqual(store.loadClaude().records.count, 1)
    }

    /// These descriptions are logged at `privacy: .public`, and the cache lives
    /// under the user's home directory. The errno is the actionable part; the
    /// path is not, and must not ride along.
    func testFailureDescriptionsCarryNoFileSystemPaths() throws {
        let occupied = directory.appendingPathComponent("MeterBar")
        try Data("occupied".utf8).write(to: occupied)
        let store = CostScanCacheStore(directory: occupied)

        XCTAssertThrowsError(try store.saveClaude(makeCache())) { error in
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(self.directory.path), description)
            XCTAssertFalse(description.contains("/"), description)
        }
    }

    private func makeCache() -> CostScanFileCache<ClaudeFileTotals> {
        var cache = CostScanFileCache<ClaudeFileTotals>()
        cache.records["/tmp/session.jsonl"] = CostScanFileRecord(
            offset: 4,
            stamp: CostScanFileStamp(size: 4, modified: 1_780_000_000, fileID: 42),
            cutoff: Date(timeIntervalSince1970: 1_780_000_000),
            isComplete: true,
            payload: ClaudeFileTotals()
        )
        return cache
    }
}
