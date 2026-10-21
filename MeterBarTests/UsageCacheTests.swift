import Foundation
import MeterBarShared
import XCTest

final class UsageCacheTests: XCTestCase {
    private let firstID = UUID()
    private let secondID = UUID()

    private func key(_ service: ServiceType, _ id: UUID) -> ProviderAccount {
        ProviderAccount(service: service, scope: .account(AccountID(id)))
    }

    private func metrics(_ service: ServiceType, used: Double, timestamp: TimeInterval = 1) -> UsageMetrics {
        UsageMetrics(service: service, weeklyLimit: UsageLimit(used: used, total: 100, resetTime: nil),
                     lastUpdated: Date(timeIntervalSince1970: timestamp))
    }

    func testProviderSummaryCannotSatisfyAnAccountOrAnotherProvider() {
        var cache = UsageCache()
        cache[ProviderAccount(service: .codexCli, scope: .providerWide)] = metrics(.codexCli, used: 30)
        cache[key(.codexCli, firstID)] = metrics(.codexCli, used: 20)
        XCTAssertNil(cache[key(.codexCli, secondID)])
        XCTAssertNil(cache[key(.claudeCode, firstID)])
        XCTAssertEqual(cache[key(.codexCli, firstID)]?.weeklyLimit?.used, 20)
        XCTAssertEqual(cache.providerMetrics[.codexCli]?.weeklyLimit?.used, 30)
        cache[key(.codexCli, firstID)] = metrics(.claudeCode, used: 80)
        XCTAssertEqual(cache[key(.codexCli, firstID)]?.weeklyLimit?.used, 20)
    }

    func testReplacingOneProvidersAccountsKeepsOtherScopes() {
        var cache = UsageCache()
        cache[key(.codexCli, firstID)] = metrics(.codexCli, used: 20)
        cache[key(.claudeCode, firstID)] = metrics(.claudeCode, used: 10)
        cache.replaceProviderMetrics([.codexCli: metrics(.codexCli, used: 30)])
        cache.replaceAccounts([secondID: metrics(.codexCli, used: 60)], for: .codexCli)
        XCTAssertNil(cache[key(.codexCli, firstID)])
        XCTAssertEqual(cache[key(.codexCli, secondID)]?.weeklyLimit?.used, 60)
        XCTAssertEqual(cache[key(.claudeCode, firstID)]?.weeklyLimit?.used, 10)
        XCTAssertEqual(cache.providerMetrics[.codexCli]?.weeklyLimit?.used, 30)
    }

    func testAccountIDCannotBeAnUnvalidatedLabel() {
        XCTAssertNil(AccountID("Work"))
        XCTAssertNil(AccountID("../account"))
        XCTAssertEqual(AccountID(firstID.uuidString)?.value, firstID)
    }

    func testMalformedAccountPairDropsAloneAndCannotCrossProvider() throws {
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics(.codexCli, used: 20)))
        let other = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics(.claudeCode, used: 80)))
        let encoded = try JSONSerialization.data(withJSONObject: [
            firstID.uuidString, good, "not-a-uuid", good,
            secondID.uuidString, ["bad": "entry"], UUID().uuidString, other,
        ])
        let restored = try XCTUnwrap(MetricsCodec.decodeAccountMap(encoded, service: .codexCli))
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[firstID]?.weeklyLimit?.used, 20)
    }

    func testAccountMapEncodingRemainsReadableByShippedDictionaryDecoder() throws {
        let encoded = try XCTUnwrap(MetricsCodec.encodeAccountMap(
            [firstID: metrics(.codexCli, used: 20)], service: .codexCli
        ))
        let legacy = try JSONDecoder().decode([UUID: UsageMetrics].self, from: encoded)
        XCTAssertEqual(legacy[firstID]?.weeklyLimit?.used, 20)
    }

    func testProviderKeyAndPayloadMustAgreeOnEncodeAndDecode() throws {
        let wrong = metrics(.claudeCode, used: 80)
        let encoded = try XCTUnwrap(MetricsCodec.encode([.codexCli: wrong]))
        XCTAssertTrue(MetricsCodec.decode(encoded).isEmpty)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wrong))
        let legacy = try JSONSerialization.data(withJSONObject: [ServiceType.codexCli.rawValue: payload])
        XCTAssertTrue(MetricsCodec.decode(legacy).isEmpty)
    }

    func testDuplicateAccountSnapshotsKeepFreshestWithoutCollidingAcrossProviders() throws {
        let old = AccountUsageSnapshot(id: firstID, name: "Old", metrics: metrics(.codexCli, used: 10))
        let fresh = AccountUsageSnapshot(id: firstID, name: "New", metrics: metrics(.codexCli, used: 20, timestamp: 2))
        let other = AccountUsageSnapshot(id: firstID, name: "Other", metrics: metrics(.claudeCode, used: 30))
        for snapshots in [[old, fresh, other], [fresh, old, other]] {
            let restored = MetricsCodec.decodeAccounts(try JSONEncoder().encode(snapshots))
            XCTAssertEqual(restored.count, 2)
            XCTAssertEqual(restored.first { $0.metrics.service == .codexCli }?.metrics.weeklyLimit?.used, 20)
            XCTAssertEqual(restored.first { $0.metrics.service == .claudeCode }?.metrics.weeklyLimit?.used, 30)
        }
    }
}
