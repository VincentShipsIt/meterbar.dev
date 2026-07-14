import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Covers `SharedDataStore`'s disk I/O path — encode → atomic write → decode —
/// which the wire-format contract tests do not exercise (they round-trip through
/// the codec only). The App Group container is unavailable to `swift test`, so
/// the `directoryOverride` seam points writes at a temp directory.
final class SharedDataStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDataStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testSaveThenLoadRoundTripsAllProviders() throws {
        var didWriteCount = 0
        let store = SharedDataStore(directoryOverride: tempDirectory) { didWriteCount += 1 }

        let metrics = MetricsFixtures.allProviders()
        store.saveMetrics(metrics)
        store.flushPendingWrites()

        // The post-write hook fired exactly once (widget reload in production).
        XCTAssertEqual(didWriteCount, 1)

        let loaded = store.loadMetrics()
        XCTAssertEqual(Set(loaded.keys), Set(metrics.keys))
        XCTAssertEqual(loaded[.claudeCode]?.sessionLimit, metrics[.claudeCode]?.sessionLimit)
        XCTAssertEqual(loaded[.codexCli]?.resetCreditsAvailable, 2)
        XCTAssertEqual(loaded[.cursor]?.weeklyLimit?.total, 500)
    }

    func testFileWrittenAtExpectedPath() throws {
        let store = SharedDataStore(directoryOverride: tempDirectory) {}
        store.saveMetrics([.claudeCode: MetricsFixtures.claudeCode()])
        store.flushPendingWrites()

        let expected = tempDirectory.appendingPathComponent("\(StorageKeys.cachedUsageMetrics).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testLoadReturnsEmptyWhenNoFileWritten() {
        let store = SharedDataStore(directoryOverride: tempDirectory) {}
        XCTAssertTrue(store.loadMetrics().isEmpty)
    }

    func testLatestSaveOverwritesPreviousContents() throws {
        let store = SharedDataStore(directoryOverride: tempDirectory) {}

        store.saveMetrics(MetricsFixtures.allProviders())
        store.flushPendingWrites()

        // A subsequent save with a single provider replaces the file wholesale.
        store.saveMetrics([.cursor: MetricsFixtures.cursor(planUsed: 400)])
        store.flushPendingWrites()

        let loaded = store.loadMetrics()
        XCTAssertEqual(Set(loaded.keys), [.cursor])
        XCTAssertEqual(loaded[.cursor]?.weeklyLimit?.used, 400)
    }

    func testAccountMetricsRoundTripPreservesLabelsAndIndependentUsage() {
        let store = SharedDataStore(directoryOverride: tempDirectory) {}
        let snapshots = [
            AccountUsageSnapshot(id: CodexAccount.defaultID, name: "Personal", metrics: MetricsFixtures.codexCli()),
            AccountUsageSnapshot(
                id: UUID(),
                name: "Work",
                metrics: MetricsFixtures.codexCli(sessionUsedPercent: 90, weeklyUsedPercent: 70)
            )
        ]

        store.saveAccountMetrics(snapshots)
        store.flushPendingWrites()

        let loaded = store.loadAccountMetrics()
        XCTAssertEqual(loaded.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(loaded.map { $0.metrics.sessionLimit?.used }, [30, 90])
    }
}
