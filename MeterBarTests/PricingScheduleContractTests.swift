import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Cross-target contract for the dated pricing table (issues #130 and #339).
///
/// The app, the widget extension, and the CLI must price a given (model,
/// timestamp) pair identically, because all three resolve it through
/// `MeterBarShared.ModelPricing` — nobody keeps a forked copy. The scan
/// provenance rides the cost cache the CLI reads, so it has to survive that
/// exact encode/decode path and stay absent-tolerant for caches written before
/// this field existed.
final class PricingScheduleContractTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Single source of truth (a forked table must break CI)

    func testScannersResolvePricingThroughTheSharedTable() {
        let timestamps = [
            DatedTokenPricing.utcDay(2019, 1, 1),
            DatedTokenPricing.utcDay(2026, 7, 2),
            Date()
        ]
        let claudeModels: [String?] = [nil, "claude-fable-9", "claude-opus-4-7", "claude-haiku-4-5", "unknown"]
        let codexModels: [String?] = [nil, "gpt-5.6-sol", "gpt-5.6-terra", "  GPT-5.6-Luna  ", "gpt-9-unreleased"]

        for timestamp in timestamps {
            for model in claudeModels {
                XCTAssertEqual(
                    ClaudeCostScanner.pricing(for: model, at: timestamp),
                    ModelPricing.claude(for: model, at: timestamp)
                )
            }
            for model in codexModels {
                XCTAssertEqual(
                    CodexCostScanner.pricing(for: model, at: timestamp),
                    ModelPricing.codex(for: model, at: timestamp)
                )
            }
        }
    }

    func testEverySeededScheduleResolvesAtAnyTimestampWithoutZeroRates() {
        // A schedule that resolves to nothing (or to zero rates) would silently
        // report $0.00 for a whole provider.
        for key in ModelPricing.tableKeys {
            let schedule = ModelPricing.schedule(forKey: key)
            XCTAssertNotNil(schedule, "no schedule for '\(key)'")
            XCTAssertFalse(schedule?.entries.isEmpty ?? true, "'\(key)' has no entries")
            XCTAssertEqual(
                schedule?.entries.map(\.effectiveFrom).sorted(),
                schedule?.entries.map(\.effectiveFrom),
                "'\(key)' entries are not sorted ascending"
            )

            for timestamp in [Date.distantPast, referenceDate, Date(), Date.distantFuture] {
                let resolved = schedule?.resolve(at: timestamp)
                XCTAssertNotNil(resolved, "'\(key)' resolved to nothing at \(timestamp)")
                XCTAssertGreaterThan(resolved?.pricing.input ?? 0, 0, "'\(key)' priced input at zero")
                XCTAssertGreaterThan(resolved?.pricing.output ?? 0, 0, "'\(key)' priced output at zero")
                XCTAssertFalse(resolved?.verifiedOn.isEmpty ?? true, "'\(key)' carries no verification date")
            }
        }
    }

    func testEveryVerificationDateIsAnISO8601Day() {
        for key in ModelPricing.tableKeys {
            for entry in ModelPricing.schedule(forKey: key)?.entries ?? [] {
                XCTAssertNotNil(
                    entry.verifiedOn.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression),
                    "'\(key)' has a malformed verification date '\(entry.verifiedOn)'"
                )
            }
        }
    }

    // MARK: - The scanner records what it actually priced with

    func testClaudeScanRecordsTheProvenanceOfTheEntriesItUsed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PricingContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        let line = """
        {"timestamp": "2026-07-01T10:00:00.000Z", "requestId": "req_1", "message": {"id": "msg_1", \
        "model": "claude-sonnet-4-5", "usage": {"input_tokens": 1000000, "output_tokens": 0, \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
        try line.write(to: url, atomically: true, encoding: .utf8)

        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let totals = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        let eventDate = try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-01T10:00:00.000Z"))
        let expected = ModelPricing.resolveClaude(for: "claude-sonnet-4-5", at: eventDate)
        XCTAssertEqual(totals.pricing.verificationDates, [expected.verifiedOn])
        XCTAssertEqual(totals.pricing.eventsBeforeFirstEntry, 0)
        XCTAssertEqual(totals.estimatedCost, expected.pricing.input, accuracy: 0.000_001)
    }

    // MARK: - Provenance rides the cost cache (app writer ⇄ widget/CLI readers)

    func testProvenanceRoundTripsThroughTheCostCache() throws {
        let provenance = PricingProvenance(
            verificationDates: ["2026-07-02", "2026-01-05"],
            eventsBeforeFirstEntry: 4
        )
        let cache = CostSummaryCache(
            summary: CostSummary(
                costs: [],
                totalCostUSD: 0,
                totalTokens: 0,
                periodDays: 30,
                pricing: provenance
            ),
            lastScanDate: referenceDate
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CostSummaryCache.self, from: try encoder.encode(cache))

        let restored = try XCTUnwrap(decoded.summary.pricing)
        XCTAssertEqual(restored.verificationDates, ["2026-01-05", "2026-07-02"])
        XCTAssertEqual(restored.eventsBeforeFirstEntry, 4)
        XCTAssertEqual(restored.label, "Rates verified 2026-01-05–2026-07-02")
    }

    func testCachesWrittenBeforeDatedPricingStillDecode() throws {
        // Shape written by builds that had no pricing provenance at all.
        let legacyJSON = """
        {
            "schemaVersion": 2,
            "lastScanDate": "2023-11-14T22:13:20Z",
            "summary": {
                "costs": [],
                "totalCostUSD": 0,
                "totalTokens": 0,
                "periodDays": 30,
                "dailyUsage": []
            }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cache = try decoder.decode(CostSummaryCache.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(cache.summary.pricing)
        // Readers fall back to the shipped table's own verification dates.
        XCTAssertEqual(
            (cache.summary.pricing?.isEmpty == false ? cache.summary.pricing : ModelPricing.tableProvenance)?.label,
            ModelPricing.tableProvenance.label
        )
    }

    // MARK: - CLI JSON stays schema-compatible (docs/cli-json-schema.md, version 1)

    func testCostJSONOmitsPricingWhenTheCacheHasNone() throws {
        let cache = CostSummaryCache(
            summary: CostSummary(costs: [], totalCostUSD: 0, totalTokens: 0, periodDays: 30),
            lastScanDate: referenceDate
        )

        let object = try Self.jsonObject(CostCLIJSONResponse(cache: cache))
        XCTAssertEqual(object["schemaVersion"] as? Int, CostCLIJSONResponse.currentSchemaVersion)
        XCTAssertNil(object["pricing"], "pricing must be omitted, not emitted as null")
    }

    func testCostJSONPublishesTheProvenanceTheScanRecorded() throws {
        let cache = CostSummaryCache(
            summary: CostSummary(
                costs: [],
                totalCostUSD: 0,
                totalTokens: 0,
                periodDays: 30,
                pricing: PricingProvenance(
                    verificationDates: ["2026-07-02", "2026-01-05"],
                    eventsBeforeFirstEntry: 2
                )
            ),
            lastScanDate: referenceDate
        )

        let object = try Self.jsonObject(CostCLIJSONResponse(cache: cache))
        let pricing = try XCTUnwrap(object["pricing"] as? [String: Any])
        XCTAssertEqual(pricing["verifiedFrom"] as? String, "2026-01-05")
        XCTAssertEqual(pricing["verifiedThrough"] as? String, "2026-07-02")
        XCTAssertEqual(pricing["eventsBeforeFirstEntry"] as? Int, 2)
        // Version 1 permits additive fields; it must not bump the version.
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    private static func jsonObject(_ document: some CLIJSONDocument) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try document.jsonData()) as? [String: Any])
    }
}
