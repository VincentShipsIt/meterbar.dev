import XCTest
@testable import MeterBar

final class ClaudeKeychainAccessPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testRefreshTriggerMapsToFailSafeKeychainAccessMode() {
        XCTAssertEqual(ClaudeKeychainAccessMode(trigger: .background), .background)
        XCTAssertEqual(ClaudeKeychainAccessMode(trigger: .userInitiated), .interactive)
    }

    func testBackgroundReadQueriesWithoutUIWhenNoDenialExists() {
        XCTAssertEqual(
            ClaudeKeychainPromptPolicy.decision(
                requestedMode: .background,
                deniedAt: nil,
                now: now
            ),
            .query(.background)
        )
    }

    func testBackgroundReadSkipsKeychainDuringSixHourDenialCooldown() {
        XCTAssertEqual(
            ClaudeKeychainPromptPolicy.decision(
                requestedMode: .background,
                deniedAt: now,
                now: now.addingTimeInterval(6 * 60 * 60 - 1)
            ),
            .skipKeychain
        )
        XCTAssertEqual(
            ClaudeKeychainPromptPolicy.decision(
                requestedMode: .background,
                deniedAt: now,
                now: now.addingTimeInterval(6 * 60 * 60)
            ),
            .query(.background)
        )
    }

    func testUserInitiatedReadExplicitlyRetriesDuringDenialCooldown() {
        XCTAssertEqual(
            ClaudeKeychainPromptPolicy.decision(
                requestedMode: .interactive,
                deniedAt: now,
                now: now.addingTimeInterval(1)
            ),
            .query(.interactive)
        )
    }

    func testFutureDenialTimestampDoesNotSuppressBackgroundReadsForever() {
        XCTAssertEqual(
            ClaudeKeychainPromptPolicy.decision(
                requestedMode: .background,
                deniedAt: now.addingTimeInterval(60),
                now: now
            ),
            .query(.background)
        )
    }

    func testDenialStorePersistsByServiceNameWithoutCredentialMaterial() throws {
        let fixture = try makeStore()
        let first = "Claude Code-credentials-c4394a73"
        let second = "Claude Code-credentials-ee16a9f4"

        fixture.store.recordDenial(for: first, at: now)
        fixture.store.recordDenial(for: second, at: now.addingTimeInterval(1))

        let reader = ClaudeKeychainDenialStore(userDefaults: fixture.defaults)
        XCTAssertEqual(reader.deniedAt(for: first), now)
        XCTAssertEqual(reader.deniedAt(for: second), now.addingTimeInterval(1))

        let data = try XCTUnwrap(fixture.defaults.data(forKey: StorageKeys.claudeCodeKeychainDenials))
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(serialized.contains(first))
        XCTAssertTrue(serialized.contains(second))
        XCTAssertFalse(serialized.lowercased().contains("token"))
        XCTAssertFalse(serialized.lowercased().contains("credential payload"))
    }

    func testDenialStoreOverwritesAndClearsOneServiceWithoutAffectingAnother() throws {
        let fixture = try makeStore()
        let first = "Claude Code-credentials-c4394a73"
        let second = "Claude Code-credentials-ee16a9f4"

        fixture.store.recordDenial(for: first, at: now)
        fixture.store.recordDenial(for: first, at: now.addingTimeInterval(2))
        fixture.store.recordDenial(for: second, at: now.addingTimeInterval(3))
        fixture.store.clearDenial(for: first)

        XCTAssertNil(fixture.store.deniedAt(for: first))
        XCTAssertEqual(fixture.store.deniedAt(for: second), now.addingTimeInterval(3))
    }

    private func makeStore() throws -> (
        store: ClaudeKeychainDenialStore,
        defaults: UserDefaults
    ) {
        let suite = "ClaudeKeychainAccessPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (ClaudeKeychainDenialStore(userDefaults: defaults), defaults)
    }
}
