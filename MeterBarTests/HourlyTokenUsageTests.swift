import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class HourlyTokenUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    func testHourBucketStartsAtTheLocalHourAcrossHourAndDayBoundaries() throws {
        let beforeHour = try date("2025-06-14T23:59:59Z")
        let nextDay = try date("2025-06-15T00:00:00Z")
        let laterHour = try date("2025-06-15T01:42:17Z")

        XCTAssertEqual(
            CostScanHourBucket.start(for: beforeHour, calendar: calendar),
            try date("2025-06-14T23:00:00Z")
        )
        XCTAssertEqual(
            CostScanHourBucket.start(for: nextDay, calendar: calendar),
            try date("2025-06-15T00:00:00Z")
        )
        XCTAssertEqual(
            CostScanHourBucket.start(for: laterHour, calendar: calendar),
            try date("2025-06-15T01:00:00Z")
        )
    }

    func testHourlyAggregatorPreservesBucketMathAndProviderSeparation() throws {
        let firstHour = try date("2025-06-15T10:00:00Z")
        let secondHour = try date("2025-06-15T11:00:00Z")
        var firstTokens = TokenAccumulator()
        firstTokens.add(input: 100, output: 20, cacheCreation: 0, cacheRead: 5, estimatedCostUSD: 1.25)
        firstTokens.add(input: 40, output: 8, cacheCreation: 0, cacheRead: 2, estimatedCostUSD: 0.50)
        var secondTokens = TokenAccumulator()
        secondTokens.add(input: 70, output: 14, cacheCreation: 0, cacheRead: 3, estimatedCostUSD: 0.75)

        let claude = TokenUsageAggregator.makeHourlyUsage(
            from: [firstHour: firstTokens, secondHour: secondTokens],
            provider: .claudeCode,
            pricing: TokenPricing(input: 0, output: 0, cacheCreation: 0, cacheRead: 0)
        )
        let codex = TokenUsageAggregator.makeHourlyUsage(
            from: [firstHour: firstTokens],
            provider: .codexCli,
            pricing: TokenPricing(input: 0, output: 0, cacheCreation: 0, cacheRead: 0)
        )
        let rows = claude + codex

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter { $0.date == firstHour }.map(\.provider).sorted(by: rawProviderOrder), [
            .claudeCode,
            .codexCli,
        ])
        let claudeFirst = try XCTUnwrap(rows.first { $0.date == firstHour && $0.provider == .claudeCode })
        XCTAssertEqual(claudeFirst.inputTokens, 140)
        XCTAssertEqual(claudeFirst.outputTokens, 28)
        XCTAssertEqual(claudeFirst.cacheReadTokens, 7)
        XCTAssertEqual(claudeFirst.estimatedCostUSD, 1.75, accuracy: 0.000_001)
    }

    func testCostSummaryWithoutHourlyFieldStillDecodes() throws {
        let summary = makeSummary(hourlyUsage: nil)
        let encoded = try JSONEncoder().encode(summary)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNil(object["hourlyUsage"])
        let decoded = try JSONDecoder().decode(CostSummary.self, from: encoded)
        XCTAssertNil(decoded.hourlyUsage)
    }

    func testCostSummaryWithHourlyFieldRoundTrips() throws {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let summary = makeSummary(hourlyUsage: [
            HourlyTokenUsage(
                date: hour,
                provider: .claudeCode,
                inputTokens: 100,
                outputTokens: 20,
                cacheReadTokens: 5,
                estimatedCostUSD: 1.25
            ),
        ])

        let decoded = try JSONDecoder().decode(CostSummary.self, from: JSONEncoder().encode(summary))

        let row = try XCTUnwrap(decoded.hourlyUsage?.first)
        XCTAssertEqual(row.date, hour)
        XCTAssertEqual(row.provider, .claudeCode)
        XCTAssertEqual(row.totalTokens, 125)
        XCTAssertEqual(row.estimatedCostUSD, 1.25, accuracy: 0.000_001)
    }

    func testMissingHourlyUsageRefreshTruthTable() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let populated = [
            HourlyTokenUsage(
                date: calendar.dateInterval(of: .hour, for: now)?.start ?? now,
                provider: .claudeCode,
                inputTokens: 1,
                outputTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 0
            ),
        ]

        XCTAssertFalse(makeSummary(costs: [], hourlyUsage: nil).needsMissingHourlyUsageRefresh(
            lastScanDate: yesterday,
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(makeSummary(periodDays: 1, hourlyUsage: nil).needsMissingHourlyUsageRefresh(
            lastScanDate: yesterday,
            now: now,
            calendar: calendar
        ))
        XCTAssertTrue(makeSummary(hourlyUsage: nil).needsMissingHourlyUsageRefresh(
            lastScanDate: yesterday,
            now: now,
            calendar: calendar
        ))
        XCTAssertTrue(makeSummary(hourlyUsage: []).needsMissingHourlyUsageRefresh(
            lastScanDate: yesterday,
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(makeSummary(hourlyUsage: nil).needsMissingHourlyUsageRefresh(
            lastScanDate: now,
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(makeSummary(hourlyUsage: populated).needsMissingHourlyUsageRefresh(
            lastScanDate: yesterday,
            now: now,
            calendar: calendar
        ))
    }

    func testFilteringSummaryAlsoFiltersHourlyProviders() {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let summary = makeSummary(hourlyUsage: [
            hourlyUsage(at: hour, provider: .claudeCode),
            hourlyUsage(at: hour, provider: .codexCli),
        ])

        let filtered = summary.filtered(to: [.codexCli])

        XCTAssertEqual(filtered.hourlyUsage?.map(\.provider), [.codexCli])
    }

    private func makeSummary(
        costs: [TokenCost]? = nil,
        periodDays: Int = 30,
        hourlyUsage: [HourlyTokenUsage]?
    ) -> CostSummary {
        let defaultCost = TokenCost(
            provider: .claudeCode,
            inputTokens: 100,
            outputTokens: 20,
            cacheCreationTokens: 0,
            cacheReadTokens: 5,
            estimatedCostUSD: 1.25,
            sessionCount: 1,
            periodStart: now,
            periodEnd: now
        )
        let costs = costs ?? [defaultCost]
        return CostSummary(
            costs: costs,
            totalCostUSD: costs.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: costs.reduce(0) { $0 + $1.totalTokens },
            periodDays: periodDays,
            hourlyUsage: hourlyUsage
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(FlexibleISO8601.date(from: value))
    }

    private func hourlyUsage(at date: Date, provider: ServiceType) -> HourlyTokenUsage {
        HourlyTokenUsage(
            date: date,
            provider: provider,
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0
        )
    }

    private func rawProviderOrder(_ lhs: ServiceType, _ rhs: ServiceType) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
