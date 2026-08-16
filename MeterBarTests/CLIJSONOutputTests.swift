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

    /// Additive `accounts` must not change the version-1 `providers` document
    /// when the account cache is empty — existing consumers only decode
    /// `schemaVersion` + `providers`.
    func testUsageResponseOmitsAccountsWhenTheAccountCacheIsEmpty() throws {
        let response = UsageCLIJSONResponse(
            metrics: [.claudeCode: claudeUsageMetrics],
            accounts: []
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNil(object["accounts"])
        XCTAssertEqual(try response.jsonString(), usageFixture)
    }

    func testUsageResponseAccountsMatchTheSharedCacheAndNeverExposePaths() throws {
        let accountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12))
        let snapshot = AccountUsageSnapshot(
            id: accountID,
            name: "Work",
            metrics: claudeUsageMetrics
        )
        let response = UsageCLIJSONResponse(
            metrics: [.claudeCode: claudeUsageMetrics],
            accounts: [snapshot]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )
        let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        let account = try XCTUnwrap(accounts.first)
        let windows = try XCTUnwrap(account["windows"] as? [[String: Any]])

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(account["provider"] as? String, "claude")
        XCTAssertEqual(account["accountId"] as? String, accountID.uuidString)
        XCTAssertEqual(account["accountName"] as? String, "Work")
        XCTAssertEqual(account["lastUpdated"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(account["resetCreditsAvailable"] as? Int, nil)
        XCTAssertEqual((account["extraUsage"] as? [String: Any])?["state"] as? String, "on")
        XCTAssertEqual(windows.map { $0["kind"] as? String }, ["session", "weekly"])
        XCTAssertEqual(windows.first?["used"] as? Double, 42.5)
        XCTAssertEqual(windows.first?["total"] as? Double, 100)
        XCTAssertEqual(Set(account.keys), [
            "provider", "accountId", "accountName", "lastUpdated",
            "windows", "extraUsage",
        ])

        let json = try response.jsonString()
        XCTAssertFalse(json.contains("/"), json)
        XCTAssertFalse(json.contains("GROK_HOME"), json)
        XCTAssertFalse(json.contains("configDirectory"), json)
        XCTAssertFalse(json.contains("homeDirectory"), json)
    }

    func testSchemaVersionOneConsumersStillDecodeProvidersWithoutReadingAccounts() throws {
        let snapshot = AccountUsageSnapshot(
            id: UUID(),
            name: "Work",
            metrics: claudeUsageMetrics
        )
        let data = try UsageCLIJSONResponse(
            metrics: [.claudeCode: claudeUsageMetrics],
            accounts: [snapshot]
        ).jsonData()

        let decoded = try JSONDecoder().decode(LegacyUsageDocument.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.providers.map(\.provider), ["claude"])
        XCTAssertEqual(decoded.providers.first?.windows.map(\.kind), ["session", "weekly"])
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

    // MARK: - Month-to-date window and project grouping (issue #270)

    func testMonthToDateCostResponseLabelsThePeriodKindAndUsesElapsedDaysInMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        // referenceDate is 2023-11-14T22:13:20Z, the 14th of the month, so
        // month-to-date should span 14 days (the 1st through today, inclusive)
        // regardless of the `--days` value that would otherwise apply.
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

        let response = CostCLIJSONResponse(
            cache: cache,
            monthToDate: true,
            now: referenceDate,
            calendar: calendar
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )
        let period = try XCTUnwrap(object["period"] as? [String: Any])
        XCTAssertEqual(period["requestedDays"] as? Int, 14)
        XCTAssertEqual(period["kind"] as? String, "monthToDate")
    }

    func testMonthToDateCostResponseIncludesModelAndProjectBreakdowns() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let model = TokenUsageBreakdown(
            provider: .claudeCode,
            name: "claude-opus-5",
            inputTokens: 100,
            outputTokens: 20,
            cacheCreationTokens: 5,
            cacheReadTokens: 30,
            estimatedCostUSD: 0.5,
            sessionCount: 1
        )
        let project = TokenUsageBreakdown(
            provider: .claudeCode,
            name: "www/meterbardev",
            inputTokens: 100,
            outputTokens: 20,
            cacheCreationTokens: 5,
            cacheReadTokens: 30,
            estimatedCostUSD: 0.5,
            sessionCount: 1,
            modelBreakdowns: [model]
        )
        let cache = CostSummaryCache(
            summary: CostSummary(
                costs: [],
                totalCostUSD: 0.5,
                totalTokens: 150,
                periodDays: 30,
                dailyUsage: [
                    DailyTokenUsage(
                        date: referenceDate.addingTimeInterval(-86_400),
                        provider: .claudeCode,
                        inputTokens: 100,
                        outputTokens: 20,
                        cacheReadTokens: 30,
                        estimatedCostUSD: 0.5,
                        modelBreakdowns: [model],
                        projectBreakdowns: [project]
                    )
                ]
            ),
            lastScanDate: referenceDate
        )

        let response = CostCLIJSONResponse(
            cache: cache,
            monthToDate: true,
            now: referenceDate,
            calendar: calendar
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let provider = try XCTUnwrap((object["providers"] as? [[String: Any]])?.first)
        let models = try XCTUnwrap(provider["modelBreakdowns"] as? [[String: Any]])
        let projects = try XCTUnwrap(provider["projectBreakdowns"] as? [[String: Any]])
        let nestedModels = try XCTUnwrap(projects.first?["modelBreakdowns"] as? [[String: Any]])

        XCTAssertEqual(models.first?["name"] as? String, "claude-opus-5")
        XCTAssertEqual(projects.first?["name"] as? String, "www/meterbardev")
        XCTAssertEqual(nestedModels.first?["name"] as? String, "claude-opus-5")
    }

    func testCostResponseIncludesSessionBreakdownsWhenPresent() throws {
        let session = TokenUsageBreakdown(
            provider: .codexCli,
            name: "conv-a",
            inputTokens: 1_000,
            outputTokens: 250,
            cacheCreationTokens: 50,
            cacheReadTokens: 500,
            estimatedCostUSD: 1.25,
            sessionCount: 3,
            modelBreakdowns: [
                TokenUsageBreakdown(
                    provider: .codexCli,
                    name: "gpt-5.6-sol",
                    inputTokens: 1_000,
                    outputTokens: 250,
                    cacheCreationTokens: 50,
                    cacheReadTokens: 500,
                    estimatedCostUSD: 1.25,
                    sessionCount: 3
                )
            ]
        )
        let cost = TokenCost(
            provider: .codexCli,
            inputTokens: 1_000,
            outputTokens: 250,
            cacheCreationTokens: 50,
            cacheReadTokens: 500,
            estimatedCostUSD: 1.25,
            sessionCount: 1,
            periodStart: referenceDate,
            periodEnd: referenceDate,
            projectBreakdowns: [
                TokenUsageBreakdown(
                    provider: .codexCli,
                    name: "www/meterbardev",
                    inputTokens: 1_000,
                    outputTokens: 250,
                    cacheCreationTokens: 50,
                    cacheReadTokens: 500,
                    estimatedCostUSD: 1.25,
                    sessionCount: 3,
                    sessionBreakdowns: [session]
                )
            ],
            sessionBreakdowns: [session]
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
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CostCLIJSONResponse(cache: cache).jsonData()) as? [String: Any]
        )
        let provider = try XCTUnwrap((object["providers"] as? [[String: Any]])?.first)
        let sessions = try XCTUnwrap(provider["sessionBreakdowns"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["name"] as? String, "conv-a")
        let projects = try XCTUnwrap(provider["projectBreakdowns"] as? [[String: Any]])
        let nested = try XCTUnwrap(projects.first?["sessionBreakdowns"] as? [[String: Any]])
        XCTAssertEqual(nested.first?["name"] as? String, "conv-a")
        XCTAssertFalse((sessions.first?["name"] as? String ?? "").contains("/"))
    }

    func testCostResponseOmitsProjectBreakdownsWhenNoneAreScannedButIncludesThemWhenPresent() throws {
        let costWithoutProjects = TokenCost(
            provider: .claudeCode,
            inputTokens: 10,
            outputTokens: 2,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0.1,
            sessionCount: 1,
            periodStart: referenceDate,
            periodEnd: referenceDate
        )
        let costWithProjects = TokenCost(
            provider: .codexCli,
            inputTokens: 1_000,
            outputTokens: 250,
            cacheCreationTokens: 50,
            cacheReadTokens: 500,
            estimatedCostUSD: 1.25,
            sessionCount: 3,
            periodStart: referenceDate,
            periodEnd: referenceDate,
            projectBreakdowns: [
                TokenUsageBreakdown(
                    provider: .codexCli,
                    name: "www/example/app",
                    inputTokens: 1_000,
                    outputTokens: 250,
                    cacheCreationTokens: 50,
                    cacheReadTokens: 500,
                    estimatedCostUSD: 1.25,
                    sessionCount: 3,
                    modelBreakdowns: [
                        TokenUsageBreakdown(
                            provider: .codexCli,
                            name: "gpt-5.6",
                            inputTokens: 1_000,
                            outputTokens: 250,
                            cacheCreationTokens: 50,
                            cacheReadTokens: 500,
                            estimatedCostUSD: 1.25,
                            sessionCount: 3
                        )
                    ]
                )
            ]
        )
        let cache = CostSummaryCache(
            summary: CostSummary(
                costs: [costWithoutProjects, costWithProjects],
                totalCostUSD: 1.35,
                totalTokens: 1_812,
                periodDays: 30
            ),
            lastScanDate: referenceDate
        )

        let response = CostCLIJSONResponse(cache: cache)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])

        let claude = try XCTUnwrap(providers.first { $0["provider"] as? String == "claude" })
        XCTAssertNil(claude["projectBreakdowns"])

        let codex = try XCTUnwrap(providers.first { $0["provider"] as? String == "codex" })
        let projects = try XCTUnwrap(codex["projectBreakdowns"] as? [[String: Any]])
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project["name"] as? String, "www/example/app")
        XCTAssertEqual(project["estimatedCostUSD"] as? Double, 1.25)
        let models = try XCTUnwrap(project["modelBreakdowns"] as? [[String: Any]])
        XCTAssertEqual(models.first?["name"] as? String, "gpt-5.6")
    }

    func testCostResponseOmitsDisplayCurrencyByDefaultButIncludesItWhenSupplied() throws {
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
            summary: CostSummary(costs: [cost], totalCostUSD: 1.25, totalTokens: 1_800, periodDays: 30),
            lastScanDate: referenceDate
        )

        let withoutCurrency = CostCLIJSONResponse(cache: cache)
        let plainObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: withoutCurrency.jsonData()) as? [String: Any]
        )
        XCTAssertNil(plainObject["displayCurrency"])

        let currency = DisplayCurrency(code: "EUR", unitsPerUSD: 0.92, enteredAt: referenceDate)
        let withCurrency = CostCLIJSONResponse(cache: cache, displayCurrency: currency)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: withCurrency.jsonData()) as? [String: Any]
        )
        let displayCurrency = try XCTUnwrap(object["displayCurrency"] as? [String: Any])
        XCTAssertEqual(displayCurrency["code"] as? String, "EUR")
        XCTAssertEqual(displayCurrency["unitsPerUSD"] as? Double, 0.92)
        XCTAssertEqual(displayCurrency["totalCostConverted"] as? Double, currency.convert(usd: 1.25))
        XCTAssertNotNil(displayCurrency["enteredAt"])
        XCTAssertEqual(displayCurrency["source"] as? String, "manual")
    }

    func testPeriodKindIsEmittedAdditivelyAndAdditionalWindowsUseCadenceKind() throws {
        let metrics = UsageMetrics(
            service: .grok,
            sessionLimit: UsageLimit(
                used: 10,
                total: 100,
                resetTime: referenceDate,
                windowSeconds: 18_000,
                periodKind: .session
            ),
            weeklyLimit: UsageLimit(
                used: 41,
                total: 100,
                resetTime: nil,
                windowSeconds: 2_678_400,
                periodKind: .monthly
            ),
            additionalLimits: [
                UsageLimit(used: 12, total: 100, resetTime: nil, periodKind: .daily),
                UsageLimit(used: 8, total: 100, resetTime: nil, periodKind: .unknown)
            ],
            lastUpdated: referenceDate
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: UsageCLIJSONResponse(metrics: [.grok: metrics]).jsonData()
            ) as? [String: Any]
        )
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        let windows = try XCTUnwrap(providers.first?["windows"] as? [[String: Any]])

        XCTAssertEqual(windows.map { $0["kind"] as? String }, ["session", "weekly", "daily", "unknown"])
        XCTAssertEqual(windows.map { $0["periodKind"] as? String }, ["session", "monthly", "daily", "unknown"])
        XCTAssertEqual(windows[1]["used"] as? Double, 41)
    }

    func testErrorResponseIsVersionedAndMachineStable() throws {
        let response = CLIJSONErrorResponse(
            code: "usage_cache_missing",
            message: "No cached metrics found. Open MeterBar app to fetch data."
        )

        XCTAssertEqual(try response.jsonString(), errorFixture)
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

    private var claudeUsageMetrics: UsageMetrics {
        UsageMetrics(
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
    }

    /// The schema-v1 surface: `providers` only. A consumer that never heard of
    /// `accounts` must still decode a document that includes the new key.
    private struct LegacyUsageDocument: Decodable {
        let schemaVersion: Int
        let providers: [Provider]

        struct Provider: Decodable {
            let provider: String
            let windows: [Window]
        }

        struct Window: Decodable {
            let kind: String
        }
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
