import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class CostSummaryStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostSummaryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testLoadMigratesVersionOneCacheToVersionTwoWithoutInventingAttribution() throws {
        let currentURL = tempDirectory.appendingPathComponent("cost-summary-v2.json")
        let legacyURL = tempDirectory.appendingPathComponent("cost-summary-v1.json")
        try legacyPayload().write(to: legacyURL)

        let migrated = try XCTUnwrap(
            CostSummaryStore.load(currentURL: currentURL, legacyURL: legacyURL)
        )

        XCTAssertEqual(CostSummaryCache.currentSchemaVersion, 2)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.summary.dailyUsage.count, 1)
        XCTAssertNil(migrated.summary.dailyUsage[0].modelBreakdowns)
        XCTAssertNil(migrated.summary.dailyUsage[0].projectBreakdowns)
        XCTAssertTrue(
            migrated.summary.needsMissingDailyUsageRefresh(
                days: 30,
                lastScanDate: migrated.lastScanDate,
                now: migrated.lastScanDate
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))

        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: currentURL)
        ) as? [String: Any]
        XCTAssertEqual(persisted?["schemaVersion"] as? Int, 2)
    }

    func testLoadPrefersCurrentVersionOverStaleLegacyCache() throws {
        let currentURL = tempDirectory.appendingPathComponent("cost-summary-v2.json")
        let legacyURL = tempDirectory.appendingPathComponent("cost-summary-v1.json")
        try legacyPayload(inputTokens: 999).write(to: legacyURL)

        let current = CostSummaryCache(
            summary: CostSummary(
                costs: [],
                totalCostUSD: 1,
                totalTokens: 10,
                periodDays: 30,
                dailyUsage: [
                    DailyTokenUsage(
                        date: Date(timeIntervalSince1970: 1_750_000_000),
                        provider: .claudeCode,
                        inputTokens: 10,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        estimatedCostUSD: 1,
                        modelBreakdowns: [],
                        projectBreakdowns: []
                    )
                ]
            ),
            lastScanDate: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try CostSummaryStore.save(current, to: currentURL)

        let loaded = try XCTUnwrap(
            CostSummaryStore.load(currentURL: currentURL, legacyURL: legacyURL)
        )

        XCTAssertEqual(loaded.summary.dailyUsage.first?.inputTokens, 10)
        XCTAssertEqual(loaded.summary.dailyUsage.first?.modelBreakdowns?.count, 0)
    }

    private func legacyPayload(inputTokens: Int = 10) throws -> Data {
        let payload = LegacyCache(
            summary: LegacySummary(
                costs: [
                    LegacyTokenCost(
                        provider: .claudeCode,
                        inputTokens: inputTokens,
                        outputTokens: 0,
                        cacheCreationTokens: 0,
                        cacheReadTokens: 0,
                        estimatedCostUSD: 1,
                        sessionCount: 1,
                        periodStart: Date(timeIntervalSince1970: 1_750_000_000),
                        periodEnd: Date(timeIntervalSince1970: 1_750_000_000),
                        modelBreakdowns: [
                            LegacyBreakdown(
                                provider: .claudeCode,
                                name: "claude-opus-5",
                                inputTokens: inputTokens,
                                outputTokens: 0,
                                cacheCreationTokens: 0,
                                cacheReadTokens: 0,
                                estimatedCostUSD: 1,
                                sessionCount: 1
                            )
                        ],
                        originBreakdowns: []
                    )
                ],
                totalCostUSD: 1,
                totalTokens: inputTokens,
                periodDays: 30,
                dailyUsage: [
                    LegacyDailyUsage(
                        date: Date(timeIntervalSince1970: 1_750_000_000),
                        provider: .claudeCode,
                        inputTokens: inputTokens,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        estimatedCostUSD: 1
                    )
                ]
            ),
            lastScanDate: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }
}

private struct LegacyCache: Encodable {
    let summary: LegacySummary
    let lastScanDate: Date
}

private struct LegacySummary: Encodable {
    let costs: [LegacyTokenCost]
    let totalCostUSD: Double
    let totalTokens: Int
    let periodDays: Int
    let dailyUsage: [LegacyDailyUsage]
}

private struct LegacyTokenCost: Encodable {
    let provider: ServiceType
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
    let sessionCount: Int
    let periodStart: Date
    let periodEnd: Date
    let modelBreakdowns: [LegacyBreakdown]
    let originBreakdowns: [LegacyBreakdown]
}

private struct LegacyBreakdown: Encodable {
    let provider: ServiceType
    let name: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
    let sessionCount: Int
}

private struct LegacyDailyUsage: Encodable {
    let date: Date
    let provider: ServiceType
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
}
