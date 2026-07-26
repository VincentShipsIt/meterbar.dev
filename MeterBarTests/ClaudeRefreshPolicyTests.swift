import XCTest
@testable import MeterBar

final class ClaudeRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testBackgroundAttemptIsAllowedWithoutARecord() {
        XCTAssertEqual(
            ClaudeRefreshPolicy.decision(record: nil, trigger: .background, now: now),
            .attempt
        )
    }

    func testInconclusiveOutcomeUsesShortCooldown() {
        let record = ClaudeRefreshCooldownRecord(
            outcome: .inconclusive,
            completedAt: now
        )

        XCTAssertEqual(
            ClaudeRefreshPolicy.decision(
                record: record,
                trigger: .background,
                now: now.addingTimeInterval(19)
            ),
            .cooldown(until: now.addingTimeInterval(20))
        )
        XCTAssertEqual(
            ClaudeRefreshPolicy.decision(
                record: record,
                trigger: .background,
                now: now.addingTimeInterval(20)
            ),
            .attempt
        )
    }

    func testSuccessUsesLongCooldown() {
        let record = ClaudeRefreshCooldownRecord(
            outcome: .refreshed,
            completedAt: now
        )

        XCTAssertEqual(
            ClaudeRefreshPolicy.decision(
                record: record,
                trigger: .background,
                now: now.addingTimeInterval(299)
            ),
            .cooldown(until: now.addingTimeInterval(300))
        )
    }

    func testHardFailureUsesLongCooldown() {
        let record = ClaudeRefreshCooldownRecord(
            outcome: .hardFailure,
            completedAt: now
        )

        XCTAssertEqual(
            ClaudeRefreshPolicy.decision(
                record: record,
                trigger: .background,
                now: now.addingTimeInterval(299)
            ),
            .cooldown(until: now.addingTimeInterval(300))
        )
    }

    func testUserInitiatedAttemptBypassesActiveCooldown() {
        for outcome in ClaudeTokenRefreshOutcome.allCases {
            let record = ClaudeRefreshCooldownRecord(outcome: outcome, completedAt: now)

            XCTAssertEqual(
                ClaudeRefreshPolicy.decision(
                    record: record,
                    trigger: .userInitiated,
                    now: now.addingTimeInterval(1)
                ),
                .attempt
            )
        }
    }

    func testFutureCompletionDateDoesNotDisableRefreshForever() {
        let future = now.addingTimeInterval(60 * 60)
        let record = ClaudeRefreshCooldownRecord(outcome: .hardFailure, completedAt: future)

        XCTAssertEqual(
            ClaudeRefreshPolicy.decision(record: record, trigger: .background, now: now),
            .attempt
        )
    }

    func testCooldownStorePersistsRecordsByAccount() throws {
        let suite = "ClaudeRefreshPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let firstAccount = UUID()
        let secondAccount = UUID()

        let writer = ClaudeRefreshCooldownStore(userDefaults: defaults)
        writer.record(.refreshed, for: firstAccount, at: now)
        writer.record(.inconclusive, for: secondAccount, at: now.addingTimeInterval(1))

        let reader = ClaudeRefreshCooldownStore(userDefaults: defaults)
        XCTAssertEqual(
            reader.record(for: firstAccount),
            ClaudeRefreshCooldownRecord(outcome: .refreshed, completedAt: now)
        )
        XCTAssertEqual(
            reader.record(for: secondAccount),
            ClaudeRefreshCooldownRecord(
                outcome: .inconclusive,
                completedAt: now.addingTimeInterval(1)
            )
        )
    }
}
