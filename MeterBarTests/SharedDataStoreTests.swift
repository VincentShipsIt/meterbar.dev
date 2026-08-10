import Foundation
import XCTest
@testable import MeterBar
@testable import MeterBarShared

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

    /// One snapshot this build cannot read must not erase every account's widget
    /// data.
    ///
    /// `AccountUsageSnapshot.metrics.service` is a closed `ServiceType`. A raw
    /// value written by a newer app version — or left behind by a provider since
    /// removed — fails that snapshot's decode, and a single non-tolerant decode
    /// of the array turned that into an empty widget for every account. The
    /// provider-keyed cache next door has tolerated this since `MetricsCodec`;
    /// the account cache must too.
    func testUnknownAccountServiceDropsOnlySnapshotNotEveryAccount() throws {
        let store = SharedDataStore(directoryOverride: tempDirectory) {}
        let healthy = AccountUsageSnapshot(
            id: CodexAccount.defaultID,
            name: "Personal",
            metrics: MetricsFixtures.codexCli()
        )
        store.saveAccountMetrics([healthy])
        store.flushPendingWrites()

        try prependSnapshotWithUnknownService()

        let loaded = store.loadAccountMetrics()

        XCTAssertEqual(loaded.map(\.name), ["Personal"])
        XCTAssertEqual(loaded.first?.metrics.sessionLimit?.used, healthy.metrics.sessionLimit?.used)
    }

    /// A structurally broken snapshot degrades the same way an unknown provider
    /// does: it drops, the rest survive.
    func testMalformedAccountSnapshotDropsOnlyThatEntry() throws {
        let store = SharedDataStore(directoryOverride: tempDirectory) {}
        store.saveAccountMetrics([
            AccountUsageSnapshot(id: UUID(), name: "Work", metrics: MetricsFixtures.codexCli())
        ])
        store.flushPendingWrites()

        try rewriteAccountMetrics { snapshots in
            [["totally": "wrong shape"]] + snapshots
        }

        XCTAssertEqual(store.loadAccountMetrics().map(\.name), ["Work"])
    }

    func testSharedMetricsLocationPrefersEntitledContainer() {
        let entitled = URL(fileURLWithPath: "/entitled/group", isDirectory: true)
        let resolved = SharedMetricsStore.resolvedContainerURL(
            entitledContainerURL: entitled,
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            fileExists: { _ in false }
        )

        XCTAssertEqual(resolved, entitled)
    }

    func testSharedMetricsLocationFallsBackToExistingCanonicalGroupContainer() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let expected = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(SharedMetricsStore.appGroupIdentifier, isDirectory: true)
        let resolved = SharedMetricsStore.resolvedContainerURL(
            entitledContainerURL: nil,
            homeDirectory: home,
            fileExists: { $0 == expected.path }
        )

        XCTAssertEqual(resolved, expected)
    }

    func testSharedMetricsLocationDoesNotInventMissingGroupContainer() {
        let resolved = SharedMetricsStore.resolvedContainerURL(
            entitledContainerURL: nil,
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            fileExists: { _ in false }
        )

        XCTAssertNil(resolved)
    }

    // MARK: - Helpers

    /// Copies the stored snapshot and stamps the copy with a `ServiceType` raw
    /// value this build does not know, reproducing a cache written by a newer
    /// app version.
    private func prependSnapshotWithUnknownService() throws {
        try rewriteAccountMetrics { snapshots in
            guard var future = snapshots.first,
                  var metrics = future["metrics"] as? [String: Any] else { return snapshots }
            metrics["service"] = "Fusion"
            future["metrics"] = metrics
            future["name"] = "Future"
            return [future] + snapshots
        }
    }

    private func rewriteAccountMetrics(_ mutate: ([[String: Any]]) -> [[String: Any]]) throws {
        let url = tempDirectory
            .appendingPathComponent("\(SharedMetricsStore.accountMetricsKey).json")
        let snapshots = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        )
        try JSONSerialization.data(withJSONObject: mutate(snapshots)).write(to: url)
    }
}
