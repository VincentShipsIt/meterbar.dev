import XCTest
import MeterBarShared
@testable import MeterBar

/// Wire-format contract for `cached_usage_metrics.json` — the App Group file the
/// app writes (`SharedDataStore.saveMetrics`) and the widget extension + CLI read.
///
/// All three targets now decode with the same `MeterBarShared` types, so the
/// contract is: (1) the canonical types round-trip losslessly, (2) the JSON key
/// names the readers depend on stay stable, and (3) payloads written by older
/// builds (which lacked `windowSeconds` / `extraUsage` / `resetCreditsAvailable`)
/// still decode.
final class CachedMetricsContractTests: XCTestCase {
    private func makeMetrics() -> UsageMetrics {
        UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(
                used: 42.5,
                total: 100,
                resetTime: Date(timeIntervalSinceReferenceDate: 700_000_000),
                windowSeconds: 5 * 3_600
            ),
            weeklyLimit: UsageLimit(used: 12, total: 100, resetTime: nil),
            extraUsage: ExtraUsageStatus(state: .on, detail: "$0.00 used"),
            resetCreditsAvailable: 2,
            lastUpdated: Date(timeIntervalSinceReferenceDate: 699_999_000)
        )
    }

    // MARK: - Round-trip (app writer ⇄ widget/CLI readers)

    func testCachedPayloadRoundTripsThroughSharedTypes() throws {
        let original = ["Claude Code": makeMetrics()]

        // Same encoder/decoder configuration as SharedDataStore and the readers:
        // default strategies, no customization.
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: UsageMetrics].self, from: data)

        let metrics = try XCTUnwrap(decoded["Claude Code"])
        XCTAssertEqual(metrics.id, original["Claude Code"]?.id)
        XCTAssertEqual(metrics.service, .claudeCode)
        XCTAssertEqual(metrics.sessionLimit, original["Claude Code"]?.sessionLimit)
        XCTAssertEqual(metrics.weeklyLimit, original["Claude Code"]?.weeklyLimit)
        XCTAssertNil(metrics.codeReviewLimit)
        XCTAssertEqual(metrics.extraUsage, ExtraUsageStatus(state: .on, detail: "$0.00 used"))
        XCTAssertEqual(metrics.resetCreditsAvailable, 2)
        XCTAssertEqual(metrics.lastUpdated, original["Claude Code"]?.lastUpdated)
    }

    // MARK: - Key stability (renaming a property is a breaking wire change)

    func testEncodedPayloadKeepsExpectedJSONKeys() throws {
        let data = try JSONEncoder().encode(makeMetrics())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        for key in ["id", "service", "sessionLimit", "weeklyLimit", "extraUsage", "resetCreditsAvailable", "lastUpdated"] {
            XCTAssertNotNil(object[key], "missing top-level key '\(key)'")
        }

        let session = try XCTUnwrap(object["sessionLimit"] as? [String: Any])
        for key in ["used", "total", "resetTime", "windowSeconds"] {
            XCTAssertNotNil(session[key], "missing sessionLimit key '\(key)'")
        }
        XCTAssertEqual(session["used"] as? Double, 42.5)

        let extra = try XCTUnwrap(object["extraUsage"] as? [String: Any])
        XCTAssertEqual(extra["state"] as? String, "on")

        // ServiceType is keyed by its raw value on the wire.
        XCTAssertEqual(object["service"] as? String, "Claude Code")
    }

    // MARK: - Backward compatibility (payloads from older writers)

    func testDecodesLegacyPayloadWithoutNewerOptionalFields() throws {
        // Shape written by pre-MeterBarShared builds: no windowSeconds, no
        // extraUsage, no resetCreditsAvailable.
        let legacyJSON = """
        {
            "Codex CLI": {
                "id": "6F1B3B1E-8C61-4E1F-9E1B-2B3C4D5E6F70",
                "service": "Codex CLI",
                "weeklyLimit": { "used": 30.0, "total": 100.0 },
                "lastUpdated": 700000000.0
            }
        }
        """

        let decoded = try JSONDecoder().decode(
            [String: UsageMetrics].self,
            from: Data(legacyJSON.utf8)
        )

        let metrics = try XCTUnwrap(decoded["Codex CLI"])
        XCTAssertEqual(metrics.service, .codexCli)
        XCTAssertEqual(metrics.weeklyLimit?.used, 30)
        XCTAssertNil(metrics.weeklyLimit?.windowSeconds)
        XCTAssertNil(metrics.extraUsage)
        XCTAssertNil(metrics.resetCreditsAvailable)
    }

    // MARK: - Shared App Group location (issue #13 — a rename must break CI)

    func testSharedMetricsStoreConstantsAreStable() {
        // The widget and CLI read the app-group file through these constants
        // instead of their own forked literals. Renaming either splits the
        // writer from the readers, so pin the wire values here.
        XCTAssertEqual(SharedMetricsStore.appGroupIdentifier, "group.dev.shipshit.meterbar")
        XCTAssertEqual(SharedMetricsStore.metricsKey, "cached_usage_metrics")
    }

    func testAppStorageKeyIsSingleSourcedFromShared() {
        // The app's in-process UserDefaults cache key and the shared app-group
        // file name are one source of truth (StorageKeys re-exports the shared
        // constant); a divergence would split the caches.
        XCTAssertEqual(StorageKeys.cachedUsageMetrics, SharedMetricsStore.metricsKey)
    }

    func testMetricsFileURLResolvesSharedKey() throws {
        // When App Groups are provisioned the reader resolves
        // "<metricsKey>.json" inside the shared container. Skip on hosts without
        // the app-group entitlement (some CI runners).
        guard let fileURL = SharedMetricsStore.metricsFileURL else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        XCTAssertEqual(fileURL.lastPathComponent, "\(SharedMetricsStore.metricsKey).json")
    }

    func testSharedReaderCodecRoundTripsMetrics() throws {
        // The widget and CLI decode exclusively through MetricsCodec (via
        // SharedMetricsStore.loadMetrics); a payload the app writes must survive
        // that exact path, including the newer optional fields.
        let written: [ServiceType: UsageMetrics] = [.claudeCode: makeMetrics()]
        let data = try XCTUnwrap(MetricsCodec.encode(written))

        let decoded = MetricsCodec.decode(data)
        let metrics = try XCTUnwrap(decoded[.claudeCode])
        XCTAssertEqual(metrics.resetCreditsAvailable, 2)
        XCTAssertEqual(metrics.extraUsage, ExtraUsageStatus(state: .on, detail: "$0.00 used"))
        XCTAssertEqual(metrics.sessionLimit, written[.claudeCode]?.sessionLimit)
    }

    // MARK: - Historical regression: used/total are JSON doubles, not ints

    func testUsedAndTotalDecodeAsDoubles() throws {
        // The CLI once declared these as Int and silently decoded nothing,
        // because the app writes `42.0`-style doubles.
        let json = """
        { "used": 42.0, "total": 100.0, "resetTime": null }
        """

        let limit = try JSONDecoder().decode(UsageLimit.self, from: Data(json.utf8))
        XCTAssertEqual(limit.used, 42.0)
        XCTAssertEqual(limit.total, 100.0)
    }
}
