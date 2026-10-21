import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Exhaustive provider coverage: each mutation starts from a readable payload,
/// so a parser that always returns no data cannot satisfy the contract.
@MainActor
final class ProviderPayloadDriftTests: XCTestCase {
    private struct Fixture {
        let name: String
        let json: String
        let field: String
        let read: (Data) throws -> Bool
    }

    func testEveryProviderHasReadableAndDriftedPayloadWitnesses() throws {
        for service in ServiceType.allCases {
            let fixtures = fixtures(for: service)
            XCTAssertFalse(fixtures.isEmpty, service.rawValue)
            for fixture in fixtures {
                let original = Data(fixture.json.utf8)
                let readable: Bool
                do {
                    readable = try fixture.read(original)
                } catch {
                    XCTFail("Readable control failed: \(fixture.name): \(error)")
                    continue
                }
                XCTAssertTrue(readable, "Readable control: \(fixture.name)")
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
                for replacement: Any? in [nil, "unrecognized-shape"] {
                    var mutated = root
                    mutated[fixture.field] = replacement
                    let data = try JSONSerialization.data(withJSONObject: mutated)
                    do {
                        let hasReading = try fixture.read(data)
                        XCTAssertFalse(hasReading, "Drift must not produce a reading: \(fixture.name)")
                    } catch GrokBillingRPC.Error.invalidResponse {
                        // The Grok mapper has no readable quota window.
                    } catch is DecodingError {
                        // Required DTO fields reject the mutation at decode.
                    } catch let error as ServiceError {
                        guard case .parsingError = error else {
                            return XCTFail("Unexpected failure for \(fixture.name): \(error)")
                        }
                    }
                }
            }
        }
    }

    private func fixtures(for service: ServiceType) -> [Fixture] {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        switch service {
        case .claudeCode:
            return [Fixture(
                name: "Claude OAuth",
                json: #"""
                {
                  "five_hour": {
                    "utilization": 25
                  }
                }
                """#,
                field: "five_hour"
            ) {
                ClaudeCodeLocalService.metrics(from: try ClaudeCodeLocalService.decodeUsageResponse(from: $0)).hasData
            }]
        case .codexCli:
            return [Fixture(
                name: "Codex",
                json: #"""
                {
                  "plan_type": "plus",
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 25,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 3600,
                      "reset_at": 4102444800
                    }
                  }
                }
                """#,
                field: "rate_limit"
            ) {
                try JSONDecoder().decode(CodexCliUsageResponse.self, from: $0).toUsageMetrics().hasData
            }]
        case .xai:
            return [
                Fixture(
                    name: "Cursor",
                    json: #"""
                    {
                      "individualUsage": {
                        "plan": {
                          "used": 25,
                          "limit": 100
                        }
                      }
                    }
                    """#,
                    field: "individualUsage"
                ) {
                    CursorUsageParser.metrics(try CursorUsageParser.summary(from: $0), now: now).hasData
                },
                Fixture(
                    name: "Grok",
                    json: #"""
                    {
                      "config": {
                        "creditUsagePercent": 25,
                        "currentPeriod": {
                          "type": "USAGE_PERIOD_TYPE_WEEKLY",
                          "start": "2026-09-20T00:00:00Z",
                          "end": "2026-09-27T00:00:00Z"
                        }
                      }
                    }
                    """#,
                    field: "config"
                ) {
                    try GrokCLIUsageService.map(JSONDecoder().decode(GrokBillingResult.self, from: $0), now: now).hasData
                },
            ]
        case .openRouter:
            return [Fixture(
                name: "OpenRouter credits",
                json: #"""
                {
                  "data": {
                    "total_credits": 100,
                    "total_usage": 25
                  }
                }
                """#,
                field: "data"
            ) { data in
                let credits = try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: data)
                let key = try JSONDecoder().decode(OpenRouterKeyResponse.self, from: Data(
                    #"{"data":{"usage":25,"is_free_tier":false}}"#.utf8
                ))
                return OpenRouterService.map(credits: credits.data, key: key.data, now: now).hasData
            }]
        case .kimiCode:
            return [Fixture(
                name: "Kimi",
                json: #"""
                {
                  "usages": {
                    "limit_5h": {
                      "used_ratio": 0.25
                    }
                  }
                }
                """#,
                field: "usages"
            ) {
                try KimiCodeUsageParser.metrics(from: $0, now: now).hasData
            }]
        case .zaiCodingPlan:
            return [Fixture(
                name: "Z.ai",
                json: #"""
                {
                  "code": 200,
                  "success": true,
                  "data": {
                    "limits": [
                      {
                        "type": "TOKENS_LIMIT",
                        "percentage": 25
                      }
                    ]
                  }
                }
                """#,
                field: "data"
            ) {
                try ZaiCodingPlanUsageParser.parse($0, now: now).metrics.hasData
            }]
        case .githubCopilot:
            return [Fixture(
                name: "Copilot billing",
                json: #"""
                {
                  "usageItems": [
                    {
                      "unitType": "credits",
                      "grossQuantity": 25
                    }
                  ]
                }
                """#,
                field: "usageItems"
            ) {
                try GitHubCopilotBillingParser.usage(from: $0, unit: .credits).hasUsage
            }]
        case .museCode:
            return [Fixture(
                name: "Muse",
                json: #"""
                {
                  "is_subs_active": true,
                  "subs_usage": {
                    "window": {
                      "used_percent": 25
                    }
                  }
                }
                """#,
                field: "subs_usage"
            ) { data in
                guard case let .quota(_, session, weekly) = try MuseCodeUsageParser.parse(data) else { return false }
                return UsageMetrics(service: .museCode, sessionLimit: session, weeklyLimit: weekly,
                                    lastUpdated: now).hasData
            }]
        case .claudePlatform:
            return [Fixture(
                name: "Claude Platform",
                json: #"""
                {
                  "amount": 10000,
                  "currency": "USD",
                  "balance": {
                    "credits": {
                      "amount_minor": 10000,
                      "exponent": 2
                    }
                  }
                }
                """#,
                field: "amount"
            ) { data in
                let credits = try ClaudePlatformParser.credits(data, now: now)
                return try ClaudePlatformParser.reading(credits: credits, monthToDateSpend: nil,
                                                       organizationName: nil, now: now).metrics.hasData
            }]
        }
    }
}
