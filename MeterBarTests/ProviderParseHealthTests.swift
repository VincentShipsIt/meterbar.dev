import MeterBarShared
@testable import MeterBar
import XCTest

final class ProviderParseHealthTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "ProviderParseHealthTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderParseHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testParseMismatchNeedsAttentionOnlyAfterConsecutiveMismatchesAndPersists() {
        let now = Date(timeIntervalSince1970: 10_000)
        let store = ProviderParseHealthStore(userDefaults: defaults)

        // One decode failure can be a truncated body from a flaky connection;
        // it must not one-shot the provider into "needs attention".
        store.recordFailure(.claudeCode, error: ServiceError.parsingError(nil), at: now)
        var record = store.records[.claudeCode]
        XCTAssertEqual(record?.consecutiveFailures, 1)
        XCTAssertTrue(record?.lastFailureWasShapeMismatch ?? false)
        XCTAssertFalse(record?.needsAttention(now: now) ?? true)

        // Genuine schema drift fails every refresh; the second consecutive
        // mismatch is the earliest reliable drift signal.
        store.recordFailure(.claudeCode, error: ServiceError.parsingError(nil), at: now + 1)
        record = store.records[.claudeCode]
        XCTAssertTrue(record?.needsAttention(now: now + 1) ?? false)
        XCTAssertEqual(ProviderParseHealthStore.persistedRecords(from: defaults)[.claudeCode], record)
    }

    func testTransientDecodeFailureThenSuccessStaysHealthy() {
        let now = Date(timeIntervalSince1970: 15_000)
        let store = ProviderParseHealthStore(userDefaults: defaults)
        let decodeError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "truncated body")
        )

        store.recordFailure(.claudeCode, error: decodeError, at: now)
        XCTAssertFalse(store.records[.claudeCode]?.needsAttention(now: now) ?? true)

        store.recordSuccess(.claudeCode, at: now + 1)
        XCTAssertFalse(store.records[.claudeCode]?.needsAttention(now: now + 1) ?? true)

        // A later isolated mismatch after recovery must start counting from zero.
        store.recordFailure(.claudeCode, error: decodeError, at: now + 2)
        XCTAssertFalse(store.records[.claudeCode]?.needsAttention(now: now + 2) ?? true)
    }

    func testMixedFailureKindsDoNotAccumulateMismatchCount() {
        let now = Date(timeIntervalSince1970: 17_000)
        let store = ProviderParseHealthStore(userDefaults: defaults)

        store.recordFailure(.cursor, error: ServiceError.parsingError(nil), at: now)
        store.recordFailure(.cursor, error: ServiceError.apiError("Request timed out"), at: now + 1)
        store.recordFailure(.cursor, error: ServiceError.parsingError(nil), at: now + 2)

        // parse, api, parse: never two consecutive mismatches, and only
        // three total failures reach the ordinary sustained threshold.
        XCTAssertTrue(store.records[.cursor]?.needsAttention(now: now + 2) ?? false)
        XCTAssertEqual(store.records[.cursor]?.consecutiveFailures, 3)
    }

    func testOrdinaryFailureNeedsThreeAttemptsAndSuccessResetsCounter() {
        let now = Date(timeIntervalSince1970: 20_000)
        let store = ProviderParseHealthStore(userDefaults: defaults)
        for offset in 0..<2 {
            store.recordFailure(.cursor, error: ServiceError.apiError("Request timed out"), at: now + Double(offset))
        }
        XCTAssertFalse(store.records[.cursor]?.needsAttention(now: now + 2) ?? true)

        store.recordFailure(.cursor, error: ServiceError.apiError("Request timed out"), at: now + 2)
        XCTAssertTrue(store.records[.cursor]?.needsAttention(now: now + 2) ?? false)

        store.recordSuccess(.cursor, at: now + 3)
        XCTAssertEqual(store.records[.cursor]?.consecutiveFailures, 0)
        XCTAssertFalse(store.records[.cursor]?.needsAttention(now: now + 3) ?? true)
    }

    func testSuccessfulDataBecomesStaleAfterPublishedThreshold() {
        let now = Date(timeIntervalSince1970: 30_000)
        let record = ProviderParseHealthRecord.success(at: now)

        XCTAssertFalse(record.needsAttention(now: now + ProviderParseHealthRecord.staleAfter - 1))
        XCTAssertTrue(record.needsAttention(now: now + ProviderParseHealthRecord.staleAfter + 1))
        XCTAssertEqual(ProviderParseHealthRecord.staleAfter, 2 * 60 * 60)
    }

    func testSharedFileWinsOverDivergentCLIPreferenceDomain() throws {
        let now = Date(timeIntervalSince1970: 40_000)
        let staleSuite = "ProviderParseHealthTests-stale-\(UUID().uuidString)"
        let staleDefaults = try XCTUnwrap(UserDefaults(suiteName: staleSuite))
        defer { staleDefaults.removePersistentDomain(forName: staleSuite) }

        let staleStore = ProviderParseHealthStore(userDefaults: staleDefaults)
        staleStore.recordSuccess(.codexCli, at: now.addingTimeInterval(-10_000))

        let appStore = ProviderParseHealthStore(
            userDefaults: defaults,
            sharedDirectoryOverride: tempDirectory
        )
        appStore.recordSuccess(.codexCli, at: now)
        appStore.flushPendingWrites()

        let sharedFileURL = tempDirectory
            .appendingPathComponent("\(SharedMetricsStore.parseHealthKey).json")
        let records = ProviderParseHealthStore.sharedRecords(
            fileURL: sharedFileURL,
            fallbackUserDefaults: staleDefaults
        )

        XCTAssertEqual(records[.codexCli]?.lastSuccess, now)
    }
}
