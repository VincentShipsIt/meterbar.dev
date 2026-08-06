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
