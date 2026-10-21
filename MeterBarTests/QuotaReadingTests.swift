import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class QuotaReadingTests: XCTestCase {
    private let account = ProviderAccount(service: .xai, scope: .providerWide)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnavailableReadingHasNoWindowOrNumericPlaceholder() {
        for reason: QuotaUnavailable in [.parseDrift, .unauthenticated, .rateLimited, .unsupported, .stale] {
            XCTAssertNil(QuotaReading.unavailable(reason).window)
        }
    }

    func testInvalidNumbersReturnParseDriftInsteadOfMeasuredZero() {
        for limit in [
            UsageLimit(used: .nan, total: 100, resetTime: nil),
            UsageLimit(used: 0, total: .infinity, resetTime: nil),
            UsageLimit(used: -1, total: 100, resetTime: nil),
            UsageLimit(used: 1, total: 0, resetTime: nil),
            UsageLimit(used: 1, total: 100, resetTime: nil, windowSeconds: .infinity),
        ] {
            XCTAssertEqual(QuotaReading(limit: limit, account: account, id: .weekly), .unavailable(.parseDrift))
            XCTAssertFalse(limit.hasDepletingMeter)
        }
    }

    func testMeasuredZeroAndEstimatedQuotaRemainDistinct() throws {
        let measured = QuotaReading(
            limit: UsageLimit(used: 0, total: 100, resetTime: nil), account: account, id: .weekly
        )
        guard case let .measured(window) = measured else { return XCTFail("Real zero must remain measured") }
        XCTAssertEqual(window.limit.used, 0)
        XCTAssertEqual(window.account, account)
        let estimated = QuotaReading(
            limit: UsageLimit(used: 1, total: 500, resetTime: nil, isEstimated: true),
            account: account, id: .weekly
        )
        guard case .estimated = estimated else { return XCTFail("Estimate must keep its provenance") }
    }

    func testAllProvidersDiscardInvalidWindowsAtTheSharedIngress() {
        for service in ServiceType.allCases {
            let metrics = UsageMetrics(
                service: service,
                sessionLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
                weeklyLimit: UsageLimit(used: .nan, total: 100, resetTime: nil),
                additionalLimits: [UsageLimit(used: 0, total: -1, resetTime: nil)],
                lastUpdated: now
            )
            XCTAssertEqual(metrics.sessionLimit?.used, 20, service.rawValue)
            XCTAssertNil(metrics.weeklyLimit, service.rawValue)
            XCTAssertTrue(metrics.additionalLimits.isEmpty, service.rawValue)
            XCTAssertThrowsError(try JSONEncoder().encode(metrics), service.rawValue)
            XCTAssertTrue(metrics.hasInvalidBlockingQuota, service.rawValue)
        }
    }

    func testCreditRemaindersKeepTheirBalanceSemantics() throws {
        let reading = QuotaReading(
            limit: UsageLimit(used: 0, total: 12, resetTime: nil, reading: .remainder),
            account: account, id: .additional(0)
        )
        let window = try XCTUnwrap(reading.window)
        XCTAssertFalse(window.limit.hasDepletingMeter)
        XCTAssertEqual(window.limit.formattedCreditRemainder, "12")
    }

    func testCursorCounterDriftReturnsUnavailableAndKeepsInjectedClock() throws {
        let data = Data(#"{"individualUsage":{"plan":{"renamed_used":0,"limit":500}}}"#.utf8)
        let metrics = CursorUsageParser.metrics(try CursorUsageParser.summary(from: data), now: now)
        XCTAssertEqual(metrics.lastUpdated, now)
        XCTAssertEqual(metrics.quotaReading(for: .weekly, account: account), .unavailable(.unsupported))
        XCTAssertTrue(ProviderSnapshotBuilder.limits(for: metrics, account: account).isEmpty)
    }

    func testInvalidBlockingStateSurvivesCopiesAndCannotReachOlderCacheReaders() throws {
        let malformed = UsageMetrics(
            service: .xai,
            sessionLimit: UsageLimit(used: 2, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 1, total: 0, resetTime: nil), lastUpdated: now
        ).withExtraUsage(.unknown).withResetCreditsAvailable(2)
        XCTAssertEqual(malformed.quotaReading(for: .weekly, account: account), .unavailable(.parseDrift))
        XCTAssertTrue(malformed.hasInvalidBlockingQuota)
        XCTAssertThrowsError(try JSONEncoder().encode(malformed))
        let healthy = UsageMetrics(service: .codexCli, weeklyLimit: UsageLimit(used: 4, total: 100, resetTime: nil))
        let encoded = try XCTUnwrap(MetricsCodec.encode([.xai: malformed, .codexCli: healthy]))
        let restored = MetricsCodec.decode(encoded)
        XCTAssertNil(restored[.xai])
        XCTAssertEqual(restored[.codexCli]?.weeklyLimit?.used, 4)
    }

    func testLegacyMalformedBlockingEntryDropsAloneOnDecode() throws {
        let healthy = UsageMetrics(service: .codexCli, weeklyLimit: UsageLimit(used: 4, total: 100, resetTime: nil))
        var bad = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(healthy)) as? [String: Any])
        bad["service"] = ServiceType.xai.rawValue
        bad["weeklyLimit"] = ["used": 0, "total": -1]
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(healthy))
        let encoded = try JSONSerialization.data(withJSONObject: ["xAI": bad, ServiceType.codexCli.rawValue: good])
        let restored = MetricsCodec.decode(encoded)
        XCTAssertNil(restored[.xai])
        XCTAssertEqual(restored[.codexCli]?.weeklyLimit?.used, 4)
    }

    func testMalformedAdditionalWindowDoesNotRelabelItsHealthySibling() {
        let metrics = UsageMetrics(service: .xai, additionalLimits: [
            UsageLimit(used: -1, total: 100, resetTime: nil),
            UsageLimit(used: 25, total: 100, resetTime: nil, label: "Reserve"),
        ])
        XCTAssertEqual(metrics.quotaReading(for: .additional(0), account: account), .unavailable(.parseDrift))
        XCTAssertEqual(metrics.quotaReading(for: .additional(1), account: account).window?.limit.label, "Reserve")
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: account)
        XCTAssertEqual(limits.count, 1)
        XCTAssertEqual(limits.first?.usageLimit.used, 25)
    }

    func testProviderMismatchCannotRenderAnotherProvidersWindow() {
        let metrics = UsageMetrics(service: .codexCli, weeklyLimit: UsageLimit(used: 2, total: 100, resetTime: nil))
        XCTAssertEqual(metrics.quotaReading(for: .weekly, account: account), .unavailable(.parseDrift))
        XCTAssertTrue(ProviderSnapshotBuilder.limits(for: metrics, account: account).isEmpty)
    }
}
