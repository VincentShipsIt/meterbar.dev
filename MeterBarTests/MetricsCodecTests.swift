import XCTest
@testable import MeterBar
import MeterBarShared

final class MetricsCodecTests: XCTestCase {
    func testRoundTrip() throws {
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 42, total: 100, resetTime: nil, windowSeconds: 5 * 60 * 60),
                weeklyLimit: UsageLimit(used: 10, total: 100, resetTime: Date(timeIntervalSince1970: 2_000_000_000))
            ),
            .cursor: UsageMetrics(
                service: .cursor,
                weeklyLimit: UsageLimit(used: 250, total: 500, resetTime: nil)
            )
        ]

        let data = try XCTUnwrap(MetricsCodec.encode(metrics))
        let decoded = MetricsCodec.decode(data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[.claudeCode]?.sessionLimit?.used, 42)
        XCTAssertEqual(decoded[.claudeCode]?.weeklyLimit?.resetTime, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(decoded[.cursor]?.weeklyLimit?.total, 500)
    }

    func testWireFormatKeysAreServiceRawValues() throws {
        // The app-group JSON is decoded independently by the widget; the top-level
        // keys MUST stay the ServiceType raw values.
        let metrics: [ServiceType: UsageMetrics] = [
            .codexCli: UsageMetrics(service: .codexCli, weeklyLimit: UsageLimit(used: 1, total: 100, resetTime: nil))
        ]
        let data = try XCTUnwrap(MetricsCodec.encode(metrics))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Array(object.keys), ["Codex CLI"])
    }

    func testUnknownServiceKeyIsDroppedNotFatal() throws {
        // Caches written by older app versions may contain providers that no
        // longer exist (e.g. the removed "Claude"/"OpenAI" admin API entries).
        // Those entries must be skipped without discarding the healthy ones.
        let json = """
        {
          "Claude": {"id": "00000000-0000-0000-0000-000000000009", "service": "Claude",
                     "lastUpdated": 700000000, "sessionLimit": null, "weeklyLimit": null,
                     "codeReviewLimit": null, "extraUsage": null, "resetCreditsAvailable": null},
          "Cursor": {"id": "00000000-0000-0000-0000-000000000001", "service": "Cursor",
                     "lastUpdated": 700000000, "sessionLimit": null,
                     "weeklyLimit": {"used": 5, "total": 500, "resetTime": null, "windowSeconds": null},
                     "codeReviewLimit": null, "extraUsage": null, "resetCreditsAvailable": null}
        }
        """
        let decoded = MetricsCodec.decode(Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[.cursor]?.weeklyLimit?.used, 5)
    }

    func testMalformedEntryIsDroppedNotFatal() throws {
        let json = """
        {
          "Cursor": {"totally": "wrong shape"},
          "Codex CLI": {"id": "00000000-0000-0000-0000-000000000002", "service": "Codex CLI",
                        "lastUpdated": 700000000, "sessionLimit": null,
                        "weeklyLimit": {"used": 12, "total": 100, "resetTime": null, "windowSeconds": null},
                        "codeReviewLimit": null, "extraUsage": null, "resetCreditsAvailable": null}
        }
        """
        let decoded = MetricsCodec.decode(Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[.codexCli]?.weeklyLimit?.used, 12)
    }

    func testGarbageDataDecodesToEmpty() {
        XCTAssertTrue(MetricsCodec.decode(Data("not json".utf8)).isEmpty)
    }
}
