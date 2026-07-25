import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Contract coverage for `meterbar guard`: input resolution, the quota decision
/// core, the stable exit codes scripts depend on, and the versioned JSON body.
final class QuotaGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Exit-code contract

    func testExitCodesAreStableAndDistinct() {
        XCTAssertEqual(QuotaGuardOutcome.available.exitCode, 0)
        XCTAssertEqual(QuotaGuardOutcome.belowThreshold.exitCode, 10)
        XCTAssertEqual(QuotaGuardOutcome.exhausted.exitCode, 11)
        XCTAssertEqual(QuotaGuardOutcome.dataUnavailable.exitCode, 12)
        XCTAssertEqual(QuotaGuardOutcome.usageError.exitCode, 13)

        let codes = QuotaGuardOutcome.allCases.map(\.exitCode)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    // MARK: - Input resolution

    func testResolveAcceptsDocumentedWindowSpellings() throws {
        XCTAssertEqual(try target(window: "session").window, .session)
        XCTAssertEqual(try target(window: "weekly").window, .weekly)
        XCTAssertEqual(try target(window: "code-review").window, .codeReview)
        XCTAssertEqual(try target(window: "codeReview").window, .codeReview)
        XCTAssertEqual(try target(window: " CODE_REVIEW ").window, .codeReview)
    }

    func testResolveAcceptsStableProviderTokens() throws {
        XCTAssertEqual(try target(provider: "claude").service, .claudeCode)
        XCTAssertEqual(try target(provider: "codex").service, .codexCli)
        XCTAssertEqual(try target(provider: " Cursor ").service, .cursor)
    }

    func testUnknownProviderIsAUsageErrorNamingTheInput() {
        let failure = expectFailure(provider: "clod")
        XCTAssertEqual(failure.outcome, .usageError)
        XCTAssertEqual(failure.code, "invalid_provider")
        XCTAssertEqual(failure.flag, "--provider")
        XCTAssertEqual(failure.value, "clod")
        XCTAssertTrue(failure.message.contains("clod"), failure.message)
        XCTAssertTrue(failure.message.contains("claude"), failure.message)
    }

    func testUnknownWindowIsAUsageErrorNamingTheInput() {
        let failure = expectFailure(window: "hourly")
        XCTAssertEqual(failure.outcome, .usageError)
        XCTAssertEqual(failure.code, "invalid_window")
        XCTAssertEqual(failure.flag, "--limit")
        XCTAssertTrue(failure.message.contains("hourly"), failure.message)
    }

    func testMalformedThresholdIsAUsageErrorNamingTheInput() {
        for raw in ["abc", "-5", "120", ""] {
            let failure = expectFailure(minRemaining: raw)
            XCTAssertEqual(failure.outcome, .usageError, raw)
            XCTAssertEqual(failure.code, "invalid_threshold", raw)
            XCTAssertEqual(failure.flag, "--min-remaining", raw)
            XCTAssertTrue(failure.message.contains("--min-remaining"), failure.message)
        }
    }

    /// `--refresh-timeout` is taken as text so a non-numeric value reaches this
    /// check at all: typed as `Double` it died inside ArgumentParser's own
    /// conversion with EX_USAGE and no JSON document, never producing the
    /// exit 13 that docs/cli-json-schema.md promises for this flag.
    func testMalformedOrOutOfRangeRefreshTimeoutIsAUsageErrorNamingTheInput() {
        for raw in ["abc", "100000", "0", "-5", "", "1e"] {
            let failure = expectFailure(refreshTimeout: raw)
            XCTAssertEqual(failure.outcome, .usageError, raw)
            XCTAssertEqual(failure.outcome.exitCode, 13, raw)
            XCTAssertEqual(failure.code, "invalid_refresh_timeout", raw)
            XCTAssertEqual(failure.flag, "--refresh-timeout", raw)
            XCTAssertEqual(failure.value, raw, raw)
            XCTAssertTrue(failure.message.contains("--refresh-timeout"), failure.message)
        }
    }

    func testRefreshTimeoutFallsBackToTheDefaultWhenOmitted() throws {
        XCTAssertEqual(try target().refreshTimeout, QuotaGuardCLI.defaultRefreshTimeout)
        XCTAssertEqual(try target(refreshTimeout: " 45 ").refreshTimeout, 45)
    }

    func testConfigDirIsRejectedForProvidersWithoutAccounts() {
        let failure = expectFailure(provider: "cursor", configDirectory: "/tmp/x")
        XCTAssertEqual(failure.outcome, .usageError)
        XCTAssertEqual(failure.code, "unsupported_config_dir")
        XCTAssertTrue(failure.message.contains("Cursor"), failure.message)
    }

    // MARK: - Available

    func testQuotaAboveThresholdExitsZeroAndReportsTheEvaluatedWindow() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(minRemaining: "25"),
            account: .providerWide,
            metrics: metrics(session: limit(used: 42.5)),
            now: now
        )

        XCTAssertEqual(evaluation.outcome, .available)
        XCTAssertEqual(evaluation.outcome.exitCode, 0)
        XCTAssertEqual(evaluation.window, .session)
        XCTAssertEqual(evaluation.percentLeft, 58)
        XCTAssertEqual(evaluation.band, .healthy)
        XCTAssertTrue(evaluation.summaryLine.contains("session"), evaluation.summaryLine)
    }

    func testQuotaExactlyAtThresholdIsAvailable() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(minRemaining: "25"),
            account: .providerWide,
            metrics: metrics(session: limit(used: 75)),
            now: now
        )

        XCTAssertEqual(evaluation.percentLeft, 25)
        XCTAssertEqual(evaluation.outcome, .available)
    }

    func testWithoutAThresholdOnlyExhaustionBlocks() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(),
            account: .providerWide,
            metrics: metrics(session: limit(used: 98)),
            now: now
        )

        XCTAssertEqual(evaluation.band, .critical)
        XCTAssertEqual(evaluation.outcome, .available)
        XCTAssertNil(evaluation.minRemainingPercent)
    }

    // MARK: - Below threshold

    func testBelowThresholdUsesItsOwnExitCodeNotTheExhaustedOne() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(minRemaining: "25"),
            account: .providerWide,
            metrics: metrics(session: limit(used: 82)),
            now: now
        )

        XCTAssertEqual(evaluation.outcome, .belowThreshold)
        XCTAssertEqual(evaluation.outcome.exitCode, 10)
        XCTAssertNotEqual(evaluation.outcome.exitCode, QuotaGuardOutcome.exhausted.exitCode)
        XCTAssertEqual(evaluation.percentLeft, 18)
        XCTAssertTrue(evaluation.message.contains("25%"), evaluation.message)
    }

    func testFractionalThresholdIsHonored() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(minRemaining: "58.5"),
            account: .providerWide,
            metrics: metrics(session: limit(used: 42.5)),
            now: now
        )

        XCTAssertEqual(evaluation.percentLeft, 58)
        XCTAssertEqual(evaluation.outcome, .belowThreshold)
    }

    // MARK: - Exhausted

    func testExhaustedQuotaReportsResetTimeAndOutranksTheThreshold() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(minRemaining: "25"),
            account: .providerWide,
            metrics: metrics(session: limit(used: 100)),
            now: now
        )

        XCTAssertEqual(evaluation.outcome, .exhausted)
        XCTAssertEqual(evaluation.outcome.exitCode, 11)
        XCTAssertEqual(evaluation.band, .exhausted)
        XCTAssertEqual(evaluation.resetAt, now.addingTimeInterval(3_600))
        XCTAssertTrue(evaluation.message.contains("1h"), evaluation.message)
        XCTAssertTrue(evaluation.summaryLine.contains("1h"), evaluation.summaryLine)
    }

    func testExhaustionDerivesFromTheSharedQuotaBandModel() throws {
        // A limit that lands exactly on the shared "no percent left" rule must be
        // exhausted here too — guard owns no second threshold table.
        let spent = limit(used: 100)
        XCTAssertEqual(QuotaBand.forLimit(spent), .exhausted)

        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(),
            account: .providerWide,
            metrics: metrics(session: spent),
            now: now
        )

        XCTAssertEqual(evaluation.outcome, .exhausted)
        XCTAssertEqual(evaluation.band, QuotaBand.forLimit(spent))
        XCTAssertEqual(evaluation.percentLeft, QuotaMath.percentLeft(for: spent))
    }

    // MARK: - Data unavailable

    func testMissingSnapshotNeverReportsAvailability() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(),
            account: .providerWide,
            metrics: nil,
            now: now
        )

        XCTAssertEqual(evaluation.outcome, .dataUnavailable)
        XCTAssertEqual(evaluation.outcome.exitCode, 12)
        XCTAssertEqual(evaluation.failure?.code, "snapshot_missing")
    }

    func testSnapshotOlderThanTheFreshnessBoundIsUnavailable() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(),
            account: .providerWide,
            metrics: metrics(
                session: limit(used: 10),
                ageSeconds: ProviderParseHealthRecord.staleAfter + 60
            ),
            now: now
        )

        XCTAssertEqual(evaluation.outcome, .dataUnavailable)
        XCTAssertEqual(evaluation.failure?.code, "snapshot_stale")
        XCTAssertTrue(evaluation.isStale)
        XCTAssertTrue(evaluation.message.contains("--refresh"), evaluation.message)
    }

    func testSnapshotInsideTheFreshnessBoundIsUsable() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(),
            account: .providerWide,
            metrics: metrics(
                session: limit(used: 10),
                ageSeconds: ProviderParseHealthRecord.staleAfter - 60
            ),
            now: now
        )

        XCTAssertFalse(evaluation.isStale)
        XCTAssertEqual(evaluation.outcome, .available)
    }

    func testWindowTheProviderDoesNotReportIsUnavailable() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(window: "code-review"),
            account: .providerWide,
            metrics: metrics(session: limit(used: 10)),
            now: now
        )

        XCTAssertEqual(evaluation.outcome, .dataUnavailable)
        XCTAssertEqual(evaluation.failure?.code, "window_unavailable")
        XCTAssertTrue(evaluation.message.contains("code review"), evaluation.message)
    }

    func testWindowWithoutAUsableTotalIsUnavailableRatherThanFullyAvailable() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(),
            account: .providerWide,
            metrics: metrics(session: limit(used: 0, total: 0)),
            now: now
        )

        XCTAssertEqual(evaluation.outcome, .dataUnavailable)
        XCTAssertEqual(evaluation.failure?.code, "window_unavailable")
    }

    // MARK: - Account selection

    func testConfigDirSelectsTheMatchingAccountSnapshot() throws {
        let account = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work-claude")
        let snapshot = AccountUsageSnapshot(
            id: account.id,
            name: account.name,
            metrics: metrics(session: limit(used: 10))
        )

        let selection = try QuotaGuardAccountResolver.resolve(
            target: try target(configDirectory: "/tmp/work-claude/"),
            configuration: configuration(claudeAccounts: [account]),
            accountSnapshots: [snapshot],
            providerMetrics: [:],
            defaultDirectories: defaultDirectories
        ).get()

        XCTAssertEqual(selection.account.scope, .account)
        XCTAssertEqual(selection.account.name, "Work")
        XCTAssertEqual(selection.metrics?.sessionLimit?.used, 10)
    }

    func testUnknownConfigDirIsAUsageErrorNamingTheDirectory() throws {
        let failure = QuotaGuardAccountResolver.resolve(
            target: try target(configDirectory: "/tmp/nowhere"),
            configuration: configuration(claudeAccounts: [.defaultAccount]),
            accountSnapshots: [],
            providerMetrics: [:],
            defaultDirectories: defaultDirectories
        ).failureValue

        XCTAssertEqual(failure?.outcome, .usageError)
        XCTAssertEqual(failure?.code, "unknown_account")
        XCTAssertTrue(failure?.message.contains("/tmp/nowhere") == true, failure?.message ?? "")
    }

    func testMissingMirroredConfigurationIsUnavailableNotAUsageError() throws {
        let failure = QuotaGuardAccountResolver.resolve(
            target: try target(configDirectory: "/tmp/work-claude"),
            configuration: nil,
            accountSnapshots: [],
            providerMetrics: [:],
            defaultDirectories: defaultDirectories
        ).failureValue

        XCTAssertEqual(failure?.outcome, .dataUnavailable)
        XCTAssertEqual(failure?.code, "account_lookup_unavailable")
    }

    func testWithoutConfigDirTheProviderWideSnapshotIsUsed() throws {
        let selection = try QuotaGuardAccountResolver.resolve(
            target: try target(),
            configuration: nil,
            accountSnapshots: [],
            providerMetrics: [.claudeCode: metrics(session: limit(used: 5))],
            defaultDirectories: defaultDirectories
        ).get()

        XCTAssertEqual(selection.account, .providerWide)
        XCTAssertEqual(selection.metrics?.sessionLimit?.used, 5)
    }

    // MARK: - JSON contract

    func testAvailableResponseMatchesVersionOneFixture() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(minRemaining: "25"),
            account: .providerWide,
            metrics: metrics(session: limit(used: 42.5)),
            now: now
        )

        XCTAssertEqual(try GuardCLIResponse(evaluation: evaluation).jsonString(), availableFixture)
    }

    func testExhaustedResponseCarriesResetTimeAndBand() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(provider: "codex", window: "weekly"),
            account: .providerWide,
            metrics: metrics(service: .codexCli, weekly: limit(used: 100)),
            now: now
        )
        let object = try json(evaluation)

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["outcome"] as? String, "exhausted")
        XCTAssertEqual(object["exitCode"] as? Int, 11)
        XCTAssertEqual(object["provider"] as? String, "codex")
        XCTAssertEqual(object["window"] as? String, "weekly")
        XCTAssertEqual(object["quotaBand"] as? String, "exhausted")
        XCTAssertEqual(object["percentLeft"] as? Int, 0)
        XCTAssertEqual(object["resetAt"] as? String, "2023-11-14T23:13:20Z")
        XCTAssertNil(object["minRemainingPercent"])
    }

    func testUnavailableResponseCarriesTheStableReasonCode() throws {
        let evaluation = QuotaGuardEvaluator.evaluate(
            target: try target(),
            account: .providerWide,
            metrics: nil,
            now: now
        )
        let object = try json(evaluation)
        let error = try XCTUnwrap(object["error"] as? [String: Any])

        XCTAssertEqual(object["outcome"] as? String, "dataUnavailable")
        XCTAssertEqual(object["exitCode"] as? Int, 12)
        XCTAssertEqual(error["code"] as? String, "snapshot_missing")
        XCTAssertNil(object["percentLeft"])
        XCTAssertNil(object["quotaBand"])
    }

    func testUsageErrorResponseNamesTheOffendingFlagAndValue() throws {
        let failure = expectFailure(provider: "clod")
        let object = try json(.failed(failure, checkedAt: now))
        let error = try XCTUnwrap(object["error"] as? [String: Any])

        XCTAssertEqual(object["outcome"] as? String, "usageError")
        XCTAssertEqual(object["exitCode"] as? Int, 13)
        XCTAssertEqual(error["code"] as? String, "invalid_provider")
        XCTAssertEqual(error["flag"] as? String, "--provider")
        XCTAssertEqual(error["value"] as? String, "clod")
        XCTAssertNil(object["provider"])
    }

    // MARK: - Helpers

    private var defaultDirectories: QuotaGuardDefaultDirectories {
        QuotaGuardDefaultDirectories(claude: "/Users/test/.claude", codex: "/Users/test/.codex")
    }

    private func configuration(
        claudeAccounts: [ClaudeCodeAccount] = [],
        codexAccounts: [CodexAccount] = []
    ) -> UsageRefreshConfigurationStore.Snapshot {
        UsageRefreshConfigurationStore.Snapshot(
            hiddenServices: [],
            claudeAccounts: claudeAccounts,
            codexAccounts: codexAccounts
        )
    }

    private func limit(
        used: Double,
        total: Double = 100,
        resetOffset: TimeInterval? = 3_600
    ) -> UsageLimit {
        UsageLimit(
            used: used,
            total: total,
            resetTime: resetOffset.map { now.addingTimeInterval($0) },
            windowSeconds: 18_000
        )
    }

    private func metrics(
        service: ServiceType = .claudeCode,
        session: UsageLimit? = nil,
        weekly: UsageLimit? = nil,
        codeReview: UsageLimit? = nil,
        ageSeconds: TimeInterval = 60
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: session,
            weeklyLimit: weekly,
            codeReviewLimit: codeReview,
            lastUpdated: now.addingTimeInterval(-ageSeconds)
        )
    }

    private func target(
        provider: String = "claude",
        window: String = "session",
        minRemaining: String? = nil,
        configDirectory: String? = nil,
        refreshTimeout: String? = nil
    ) throws -> QuotaGuardTarget {
        try QuotaGuardTarget.resolve(
            provider: provider,
            window: window,
            minRemaining: minRemaining,
            configDirectory: configDirectory,
            refreshTimeout: refreshTimeout
        ).get()
    }

    private func expectFailure(
        provider: String = "claude",
        window: String = "session",
        minRemaining: String? = nil,
        configDirectory: String? = nil,
        refreshTimeout: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> QuotaGuardFailure {
        let result = QuotaGuardTarget.resolve(
            provider: provider,
            window: window,
            minRemaining: minRemaining,
            configDirectory: configDirectory,
            refreshTimeout: refreshTimeout
        )
        guard let failure = result.failureValue else {
            XCTFail("Expected resolution to fail", file: file, line: line)
            return QuotaGuardFailure(outcome: .usageError, code: "unexpected", message: "")
        }
        return failure
    }

    private func json(_ evaluation: QuotaGuardEvaluation) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: GuardCLIResponse(evaluation: evaluation).jsonData()
            ) as? [String: Any]
        )
    }

    private var availableFixture: String {
        """
        {
          "account" : {
            "name" : "All accounts",
            "scope" : "provider"
          },
          "checkedAt" : "2023-11-14T22:13:20Z",
          "displayName" : "Claude Code",
          "estimated" : false,
          "exitCode" : 0,
          "message" : "Claude Code session quota available: 58% left (minimum 25%).",
          "minRemainingPercent" : 25,
          "outcome" : "available",
          "percentLeft" : 58,
          "percentUsed" : 42.5,
          "provider" : "claude",
          "quotaBand" : "healthy",
          "resetAt" : "2023-11-14T23:13:20Z",
          "schemaVersion" : 1,
          "snapshot" : {
            "ageSeconds" : 60,
            "isStale" : false,
            "lastUpdated" : "2023-11-14T22:12:20Z"
          },
          "total" : 100,
          "used" : 42.5,
          "window" : "session"
        }
        """
    }
}

private extension Result {
    var failureValue: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
