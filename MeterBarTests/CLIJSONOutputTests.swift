import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class CLIJSONOutputTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testUsageResponseMatchesVersionOneFixture() throws {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(
                used: 42.5,
                total: 100,
                resetTime: referenceDate,
                windowSeconds: 18_000
            ),
            weeklyLimit: UsageLimit(
                used: 90,
                total: 100,
                resetTime: nil,
                windowSeconds: 604_800,
                isEstimated: true
            ),
            extraUsage: ExtraUsageStatus(state: .on, detail: "$0.00 used"),
            lastUpdated: referenceDate
        )

        let response = UsageCLIJSONResponse(metrics: [.claudeCode: metrics])

        XCTAssertEqual(try response.jsonString(), usageFixture)
    }

    func testCostResponseMatchesVersionOneFixture() throws {
        let cost = TokenCost(
            provider: .codexCli,
            inputTokens: 1_000,
            outputTokens: 250,
            cacheCreationTokens: 50,
            cacheReadTokens: 500,
            estimatedCostUSD: 1.25,
            sessionCount: 3,
            periodStart: referenceDate.addingTimeInterval(-86_400),
            periodEnd: referenceDate
        )
        let cache = CostSummaryCache(
            summary: CostSummary(
                costs: [cost],
                totalCostUSD: 1.25,
                totalTokens: 1_800,
                periodDays: 30
            ),
            lastScanDate: referenceDate
        )

        let response = CostCLIJSONResponse(cache: cache)

        XCTAssertEqual(try response.jsonString(), costFixture)
    }

    func testWindowedCostResponseReportsCoverageAndOmitsUnavailableTotals() throws {
        let daily = DailyTokenUsage(
            date: referenceDate.addingTimeInterval(-86_400),
            provider: .claudeCode,
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 30,
            estimatedCostUSD: 0.5
        )
        let cache = CostSummaryCache(
            summary: CostSummary(
                costs: [],
                totalCostUSD: 0.5,
                totalTokens: 150,
                periodDays: 30,
                dailyUsage: [daily]
            ),
            lastScanDate: referenceDate
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let response = CostCLIJSONResponse(
            cache: cache,
            days: 7,
            now: referenceDate,
            calendar: calendar
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )
        let period = try XCTUnwrap(object["period"] as? [String: Any])
        XCTAssertEqual(period["requestedDays"] as? Int, 7)
        XCTAssertEqual(period["coveredDays"] as? Int, 2)
        XCTAssertEqual(period["isTruncated"] as? Bool, true)

        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        let provider = try XCTUnwrap(providers.first)
        XCTAssertNil(provider["cacheCreationTokens"])
        XCTAssertNil(provider["sessionCount"])
        XCTAssertEqual(provider["totalTokens"] as? Int, 150)
    }

    func testErrorResponseIsVersionedAndMachineStable() throws {
        let response = CLIJSONErrorResponse(
            code: "usage_cache_missing",
            message: "No cached metrics found. Open MeterBar app to fetch data."
        )

        XCTAssertEqual(try response.jsonString(), errorFixture)
    }

    func testFableSessionsResponseIsVersionedDeduplicatedAndMetadataOnly() throws {
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let earlier = ClaudeFableSession(
            sourceSessionID: "session-1",
            accountID: accountID,
            accountName: "Ship",
            model: "claude-fable-5",
            firstObservedAt: referenceDate.addingTimeInterval(-120),
            lastObservedAt: referenceDate.addingTimeInterval(-60),
            state: .active
        )
        let later = ClaudeFableSession(
            sourceSessionID: "session-1",
            accountID: accountID,
            accountName: "Ship",
            model: "claude-fable-5",
            firstObservedAt: referenceDate.addingTimeInterval(-120),
            lastObservedAt: referenceDate,
            state: .completed
        )
        let unknown = ClaudeFableSession(
            sourceSessionID: "session-2",
            accountID: accountID,
            accountName: "Ship",
            model: "claude-fable-5",
            firstObservedAt: referenceDate.addingTimeInterval(-240),
            lastObservedAt: referenceDate.addingTimeInterval(-180),
            state: .unknown
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: FableSessionsCLIJSONResponse(sessions: [unknown, earlier, later]).jsonData()
            ) as? [String: Any]
        )

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(
            Set(session.keys),
            ["id", "profile", "model", "state", "firstObservedAt", "lastObservedAt"]
        )
        XCTAssertEqual(session["state"] as? String, "completed")
        XCTAssertEqual(session["model"] as? String, "claude-fable-5")
        XCTAssertNil(session["sourceSessionID"])
        XCTAssertNil(session["content"])
        XCTAssertNil(session["cwd"])
        XCTAssertNil(session["git"])

        let profile = try XCTUnwrap(session["profile"] as? [String: Any])
        XCTAssertEqual(Set(profile.keys), ["id", "name"])
        XCTAssertEqual(profile["name"] as? String, "Ship")
        XCTAssertEqual(sessions.last?["state"] as? String, "unknown")
    }

    func testFableSessionsResponseEncodesHonestEmptySnapshot() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: FableSessionsCLIJSONResponse(sessions: []).jsonData()
            ) as? [String: Any]
        )

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["sessions"] as? [Any])?.count, 0)
    }

    private var usageFixture: String {
        """
        {
          "providers" : [
            {
              "displayName" : "Claude Code",
              "extraUsage" : {
                "detail" : "$0.00 used",
                "state" : "on"
              },
              "lastUpdated" : "2023-11-14T22:13:20Z",
              "provider" : "claude",
              "windows" : [
                {
                  "estimated" : false,
                  "kind" : "session",
                  "percentLeft" : 58,
                  "percentUsed" : 42.5,
                  "quotaBand" : "healthy",
                  "resetAt" : "2023-11-14T22:13:20Z",
                  "total" : 100,
                  "used" : 42.5,
                  "windowSeconds" : 18000
                },
                {
                  "estimated" : true,
                  "kind" : "weekly",
                  "percentLeft" : 10,
                  "percentUsed" : 90,
                  "quotaBand" : "critical",
                  "total" : 100,
                  "used" : 90,
                  "windowSeconds" : 604800
                }
              ]
            }
          ],
          "schemaVersion" : 1
        }
        """
    }

    private var costFixture: String {
        """
        {
          "lastScannedAt" : "2023-11-14T22:13:20Z",
          "period" : {
            "coveredDays" : 30,
            "isTruncated" : false,
            "requestedDays" : 30
          },
          "providers" : [
            {
              "cacheCreationTokens" : 50,
              "cacheReadTokens" : 500,
              "displayName" : "OpenAI Codex",
              "estimatedCostUSD" : 1.25,
              "inputTokens" : 1000,
              "outputTokens" : 250,
              "provider" : "codex",
              "sessionCount" : 3,
              "totalTokens" : 1800
            }
          ],
          "schemaVersion" : 1,
          "totalCostUSD" : 1.25,
          "totalTokens" : 1800
        }
        """
    }

    private var errorFixture: String {
        """
        {
          "error" : {
            "code" : "usage_cache_missing",
            "message" : "No cached metrics found. Open MeterBar app to fetch data."
          },
          "schemaVersion" : 1
        }
        """
    }
}
