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

    func testAccountRoundTripPreservesLabelsAndUsage() throws {
        let snapshots = [
            AccountUsageSnapshot(
                id: UUID(),
                name: "Personal",
                metrics: UsageMetrics(
                    service: .codexCli,
                    sessionLimit: UsageLimit(used: 30, total: 100, resetTime: nil)
                )
            )
        ]

        let data = try XCTUnwrap(MetricsCodec.encodeAccounts(snapshots))
        let decoded = MetricsCodec.decodeAccounts(data)

        XCTAssertEqual(decoded.map(\.name), ["Personal"])
        XCTAssertEqual(decoded.first?.metrics.sessionLimit?.used, 30)
    }

    /// The account cache is decoded by the widget and the CLI as well as the
    /// app, so one snapshot naming a provider this build does not know must cost
    /// that snapshot only — never every account's widget row.
    func testUnknownAccountServiceIsDroppedNotFatal() throws {
        let json = """
        [
          {"id": "00000000-0000-0000-0000-000000000003", "name": "Future",
           "metrics": {"id": "00000000-0000-0000-0000-000000000004", "service": "Fusion",
                       "lastUpdated": 700000000}},
          {"id": "00000000-0000-0000-0000-000000000005", "name": "Personal",
           "metrics": {"id": "00000000-0000-0000-0000-000000000006", "service": "Codex CLI",
                       "lastUpdated": 700000000,
                       "weeklyLimit": {"used": 7, "total": 100, "resetTime": null, "windowSeconds": null}}}
        ]
        """
        let decoded = MetricsCodec.decodeAccounts(Data(json.utf8))

        XCTAssertEqual(decoded.map(\.name), ["Personal"])
        XCTAssertEqual(decoded.first?.metrics.weeklyLimit?.used, 7)
    }

    func testMalformedAccountSnapshotIsDroppedNotFatal() {
        let json = """
        [
          {"totally": "wrong shape"},
          {"id": "00000000-0000-0000-0000-000000000007", "name": "Work",
           "metrics": {"id": "00000000-0000-0000-0000-000000000008", "service": "Cursor",
                       "lastUpdated": 700000000}}
        ]
        """
        XCTAssertEqual(MetricsCodec.decodeAccounts(Data(json.utf8)).map(\.name), ["Work"])
    }

    func testGarbageAccountDataDecodesToEmpty() {
        XCTAssertTrue(MetricsCodec.decodeAccounts(Data("not json".utf8)).isEmpty)
    }
}
