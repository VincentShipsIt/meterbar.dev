import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Persistence coverage for `ProviderUsageLedgerStore`.
///
/// This artifact is not a cache. The scan caches can be deleted at any time and
/// cost nothing but a re-read of logs that are still on disk; this file is the
/// only copy of Cursor's and OpenRouter's history, because neither provider will
/// re-serve a day once it has passed. Every test here pins a way that history
/// could be silently corrupted or thrown away.
final class ProviderUsageLedgerStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderUsageLedgerStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    /// Round-trip must preserve day boundaries exactly. The payload keys its
    /// daily buckets by `Date`, and an encoder/decoder pair that disagreed on
    /// the date strategy would not throw — it would decode every bucket decades
    /// from where it belongs, silently.
    func testRoundTripPreservesDayKeysAndAmounts() throws {
        let url = directory.appendingPathComponent(ProviderUsageLedgerStore.fileName)
        var ledger = ProviderUsageLedger()
        let first = Date(timeIntervalSince1970: 1_780_000_000)
        ledger.record(observation(.openRouter, unit: .usd, total: 10, at: first))
        ledger.record(
            observation(.openRouter, unit: .usd, total: 12.5, at: first.addingTimeInterval(86_400))
        )

        try ProviderUsageLedgerStore.save(ledger, to: url)
        let loaded = ProviderUsageLedgerStore.load(from: url)

        XCTAssertEqual(loaded, ledger)
        XCTAssertEqual(loaded.dailySeries(for: .openRouter).count, 1)
        XCTAssertEqual(loaded.dailySeries(for: .openRouter).first?.amount ?? 0, 2.5, accuracy: 0.000_001)
    }

    /// A missing file is a first run, not a failure: the ledger starts empty and
    /// the next poll establishes the baseline.
    func testMissingFileLoadsAnEmptyLedgerRatherThanFailing() {
        let url = directory.appendingPathComponent("does-not-exist.json")

        XCTAssertTrue(ProviderUsageLedgerStore.load(from: url).entries.isEmpty)
    }

    /// A ledger written under a different schema version is dropped, never
    /// half-decoded. Losing the baseline costs one poll interval; decoding a
    /// changed shape against the current one would misattribute real spend with
    /// no way to detect it afterwards.
    func testSchemaVersionMismatchDropsTheArtifact() throws {
        let url = directory.appendingPathComponent(ProviderUsageLedgerStore.fileName)
        try ProviderUsageLedgerStore.save(makeLedger(), to: url)

        try rewrite(url) { $0["schemaVersion"] = ProviderUsageLedger.currentSchemaVersion + 1 }

        XCTAssertTrue(ProviderUsageLedgerStore.load(from: url).entries.isEmpty)
    }

    /// A time-zone change re-anchors the ledger; it never discards it.
    ///
    /// Moving zones is routine — travel, a corrected system setting, DST on a
    /// machine configured by offset — and this file is the only copy of these
    /// providers' history. Dropping here would silently destroy up to
    /// `retainedDays` of days neither provider will re-serve. The recorded days
    /// keep the boundary they were recorded against and the zone is updated for
    /// the days still to come, which costs a bounded error on the one day
    /// straddling the move instead of the lot.
    func testTimeZoneMismatchReanchorsInsteadOfDiscardingHistory() throws {
        let url = directory.appendingPathComponent(ProviderUsageLedgerStore.fileName)
        let saved = makeLedger()
        try ProviderUsageLedgerStore.save(saved, to: url)

        try rewrite(url) { $0["timeZoneIdentifier"] = "Antarctica/Troll" }

        let loaded = ProviderUsageLedgerStore.load(from: url)
        XCTAssertFalse(loaded.entries.isEmpty)
        XCTAssertEqual(loaded.entries, saved.entries)
        XCTAssertEqual(loaded.timeZoneIdentifier, TimeZone.current.identifier)
    }

    /// One unreadable entry costs that provider's history, never the file's.
    ///
    /// `ProviderUsageLedgerEntry.provider` is a closed `ServiceType`, so a raw
    /// value this build does not know — a payload written by a newer version, a
    /// provider since removed — fails that entry's decode. Failing the entry
    /// used to fail the array, which failed the ledger, which returned an empty
    /// one and re-baselined from the next poll. Unlike the scan caches there is
    /// nothing to re-read: neither Cursor nor OpenRouter will re-serve a day
    /// once it has passed, so the surviving providers' days must survive.
    func testUnknownProviderDropsOnlyThatEntryNotTheWholeLedger() throws {
        let url = directory.appendingPathComponent(ProviderUsageLedgerStore.fileName)
        let saved = makeLedger()
        try ProviderUsageLedgerStore.save(saved, to: url)

        try rewriteEntries(url) { entry in
            var entry = entry
            if entry["provider"] as? String == ServiceType.cursor.rawValue {
                entry["provider"] = "Fusion"
            }
            return entry
        }

        let loaded = ProviderUsageLedgerStore.load(from: url)

        XCTAssertEqual(loaded.entries.map(\.provider), [.openRouter])
        XCTAssertEqual(loaded.entries.first, saved.entry(for: .openRouter))
        XCTAssertTrue(loaded.dailySeries(for: .cursor).isEmpty)
    }

    /// A structurally broken entry degrades the same way an unknown provider
    /// does — it drops alone.
    func testMalformedEntryDropsOnlyThatEntry() throws {
        let url = directory.appendingPathComponent(ProviderUsageLedgerStore.fileName)
        let saved = makeLedger()
        try ProviderUsageLedgerStore.save(saved, to: url)

        try rewriteEntries(url) { entry in
            entry["provider"] as? String == ServiceType.openRouter.rawValue
                ? ["totally": "wrong shape"]
                : entry
        }

        XCTAssertEqual(ProviderUsageLedgerStore.load(from: url).entries.map(\.provider), [.cursor])
    }

    /// Truncated or hand-edited JSON must not crash the poll that reads it.
    func testCorruptPayloadLoadsAnEmptyLedger() throws {
        let url = directory.appendingPathComponent(ProviderUsageLedgerStore.fileName)
        try Data("{ not json".utf8).write(to: url)

        XCTAssertTrue(ProviderUsageLedgerStore.load(from: url).entries.isEmpty)
    }

    /// The file is rewritten on every successful poll for the life of the
    /// install, so an unbounded payload would eventually trip the size guard on
    /// write — which would freeze the baseline. A file past the cap is corrupt,
    /// and is refused on read rather than parsed.
    func testOversizedArtifactIsRefusedOnLoadAndOnSave() throws {
        let url = directory.appendingPathComponent(ProviderUsageLedgerStore.fileName)
        try ProviderUsageLedgerStore.save(makeLedger(), to: url)
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        XCTAssertTrue(ProviderUsageLedgerStore.load(from: url, maximumBytes: size - 1).entries.isEmpty)
        XCTAssertThrowsError(try ProviderUsageLedgerStore.save(makeLedger(), to: url, maximumBytes: 1)) { error in
            guard case CostScanCacheStoreError.artifactTooLarge = error else {
                return XCTFail("expected artifactTooLarge, got \(error)")
            }
        }
    }

    /// The ledger records what the user spends. It is written through
    /// `SecureFileWriter`, which chmods before the first byte lands, so it can
    /// never be briefly world-readable in the user's home directory.
    func testSavedFileIsOwnerReadableOnly() throws {
        let url = directory.appendingPathComponent(ProviderUsageLedgerStore.fileName)
        try ProviderUsageLedgerStore.save(makeLedger(), to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value & 0o077, 0)
    }

    /// The file name carries the schema version, so a future shape lands beside
    /// the old one rather than being decoded as if it were compatible.
    func testFileNameCarriesTheSchemaVersion() {
        XCTAssertEqual(
            ProviderUsageLedgerStore.fileName,
            "provider-usage-observations-v\(ProviderUsageLedger.currentSchemaVersion).json"
        )
    }

    /// The ledger must never share an artifact with the disposable scan caches:
    /// a parser-version bump there would take this history with it.
    func testLedgerDoesNotShareAFileWithTheScanCaches() {
        let names = [
            CostScanCacheStore.claudeFileName,
            CostScanCacheStore.codexFileName,
            CostScanCacheStore.grokFileName
        ]
        XCTAssertFalse(names.contains(ProviderUsageLedgerStore.fileName))
    }

    // MARK: - Helpers

    private func makeLedger() -> ProviderUsageLedger {
        var ledger = ProviderUsageLedger()
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        ledger.record(observation(.openRouter, unit: .usd, total: 4, at: start))
        ledger.record(observation(.openRouter, unit: .usd, total: 9, at: start.addingTimeInterval(86_400)))
        ledger.record(observation(.cursor, unit: .requests, total: 40, at: start))
        ledger.record(observation(.cursor, unit: .requests, total: 61, at: start.addingTimeInterval(86_400)))
        return ledger
    }

    private func observation(
        _ provider: ServiceType,
        unit: ProviderUsageUnit,
        total: Double,
        at date: Date
    ) -> ProviderUsageObservation {
        ProviderUsageObservation(provider: provider, unit: unit, runningTotal: total, observedAt: date)
    }

    private func rewriteEntries(_ url: URL, _ mutate: ([String: Any]) -> [String: Any]) throws {
        try rewrite(url) { object in
            guard let entries = object["entries"] as? [[String: Any]] else { return }
            object["entries"] = entries.map(mutate)
        }
    }

    private func rewrite(_ url: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        mutate(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
