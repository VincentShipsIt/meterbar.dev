import XCTest
import MeterBarShared
@testable import MeterBar

/// Redaction tests for the inspector's error sanitizer — the layer that keeps
/// `meterbar doctor` / Diagnostics output safe to paste into a public issue.
final class ProviderReadinessInspectorTests: XCTestCase {
    func testGrokReadinessChecksEveryEnabledProfileWithoutReadingTokens() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderReadinessInspectorTests-\(UUID().uuidString)", isDirectory: true)
        let healthyHome = root.appendingPathComponent("healthy", isDirectory: true)
        try FileManager.default.createDirectory(at: healthyHome, withIntermediateDirectories: true)
        try Data().write(to: healthyHome.appendingPathComponent("auth.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let healthy = GrokAccount(id: UUID(), name: "Healthy", homeDirectory: healthyHome.path)
        let missing = GrokAccount(
            id: UUID(),
            name: "Missing",
            homeDirectory: root.appendingPathComponent("missing").path
        )

        let healthyReport = ProviderReadinessInspector.grokReport(
            accounts: [healthy],
            isCLIInstalled: true
        )
        let mixedReport = ProviderReadinessInspector.grokReport(
            accounts: [healthy, missing],
            isCLIInstalled: true
        )

        XCTAssertEqual(healthyReport.check(ReadinessCheckID.auth)?.level, .pass)
        XCTAssertEqual(mixedReport.check(ReadinessCheckID.auth)?.level, .fail)
    }

    func testMixedGrokProfilesIdentifyOnlyTheFailingAccount() throws {
        let fixtures = try grokMixedFixtures()
        defer { fixtures.tearDown() }

        let reports = ProviderReadinessInspector.reports(
            providers: [.grok],
            grokAccounts: [fixtures.healthy, fixtures.missing],
            grokIsCLIInstalled: true,
            parseHealth: [:],
            cachedMetrics: [:],
            cachedAccountMetrics: []
        )
        let byID = Dictionary(uniqueKeysWithValues: reports.compactMap { report -> (UUID, ProviderReadiness)? in
            guard let id = report.identity.accountID else { return nil }
            return (id, report)
        })

        XCTAssertEqual(byID[fixtures.healthy.id]?.check(ReadinessCheckID.installed)?.level, .pass)
        XCTAssertEqual(byID[fixtures.healthy.id]?.check(ReadinessCheckID.auth)?.level, .pass)
        XCTAssertEqual(byID[fixtures.missing.id]?.check(ReadinessCheckID.auth)?.level, .fail)
        XCTAssertNotEqual(byID[fixtures.healthy.id]?.overall, .fail)
        XCTAssertEqual(byID[fixtures.missing.id]?.overall, .fail)
        XCTAssertEqual(
            reports.first { !$0.identity.isAccountScoped }?.check(ReadinessCheckID.auth)?.level,
            .fail
        )
        XCTAssertEqual(byID[fixtures.missing.id]?.identity.accountName, "Missing")
        XCTAssertFalse((byID[fixtures.healthy.id]?.identity.accountName ?? "").contains("/"))
    }

    func testDisabledDefaultAndCustomOnlyGrokConfigurationReportsTheEnabledAccount() throws {
        let fixtures = try grokMixedFixtures()
        defer { fixtures.tearDown() }

        var disabledDefault = GrokAccount.defaultAccount
        disabledDefault.isEnabled = false
        let reports = ProviderReadinessInspector.reports(
            providers: [.grok],
            grokAccounts: [disabledDefault, fixtures.healthy],
            grokIsCLIInstalled: true,
            parseHealth: [:],
            cachedMetrics: [:],
            cachedAccountMetrics: []
        )
        let accountIDs = Set(reports.compactMap(\.identity.accountID))

        XCTAssertFalse(accountIDs.contains(GrokAccount.defaultID))
        XCTAssertTrue(accountIDs.contains(fixtures.healthy.id))
        XCTAssertEqual(
            reports.first { $0.identity.accountID == fixtures.healthy.id }?.check(ReadinessCheckID.auth)?.level,
            .pass
        )
    }

    func testMixedCodexProfilesIdentifyOnlyTheFailingAccount() {
        let healthyID = UUID()
        let failingID = UUID()
        let healthy = CodexAccount(id: healthyID, name: "Healthy", homeDirectory: "/tmp/healthy-codex")
        let failing = CodexAccount(id: failingID, name: "Broken", homeDirectory: "/tmp/broken-codex")
        let token = futureCodexAuthJSON()

        let reports = ProviderReadinessInspector.reports(
            providers: [.codexCli],
            now: Date(timeIntervalSince1970: 1_000_000),
            codexAccounts: [healthy, failing],
            codexAuthProbe: { account in
                if account.id == healthyID {
                    return (true, true, token)
                }
                return (false, false, nil)
            },
            parseHealth: [:],
            cachedMetrics: [:]
        )
        let byID = Dictionary(uniqueKeysWithValues: reports.compactMap { report -> (UUID, ProviderReadiness)? in
            guard let id = report.identity.accountID else { return nil }
            return (id, report)
        })

        XCTAssertEqual(byID[healthyID]?.check(ReadinessCheckID.auth)?.level, .pass)
        XCTAssertEqual(byID[failingID]?.check(ReadinessCheckID.auth)?.level, .fail)
        XCTAssertEqual(byID[healthyID]?.identity.accountName, "Healthy")
        XCTAssertFalse((byID[failingID]?.check(ReadinessCheckID.auth)?.detail ?? "").contains("/tmp/"))
    }

    func testDisabledDefaultClaudeUsesOnlyEnabledCustomAccount() {
        let customID = UUID()
        let custom = ClaudeCodeAccount(
            id: customID,
            name: "Work",
            configDirectory: "/tmp/claude-work",
            isEnabled: true
        )
        var disabledDefault = ClaudeCodeAccount.defaultAccount
        disabledDefault.isEnabled = false
        let now = Date(timeIntervalSince1970: 20_000)
        let recent = UsageMetrics(service: .claudeCode, lastUpdated: now.addingTimeInterval(-60))
        var probed = [UUID]()

        let reports = ProviderReadinessInspector.reports(
            providers: [.claudeCode],
            now: now,
            claudeAccounts: [disabledDefault, custom],
            claudeAccountMetrics: [customID: recent],
            claudeCredentialsProbe: { account in
                probed.append(account.id)
                return nil
            },
            parseHealth: [:],
            cachedMetrics: [:]
        )
        let accountIDs = Set(reports.compactMap(\.identity.accountID))

        XCTAssertFalse(accountIDs.contains(ClaudeCodeAccount.defaultID))
        XCTAssertTrue(accountIDs.contains(customID))
        XCTAssertFalse(probed.contains(ClaudeCodeAccount.defaultID))
        XCTAssertEqual(
            reports.first { $0.identity.accountID == customID }?.check(ReadinessCheckID.auth)?.level,
            .pass
        )
    }

    func testClaudeCustomFailureDoesNotPoisonAHealthyDefault() {
        let now = Date(timeIntervalSince1970: 70_000)
        let customID = UUID()
        let custom = ClaudeCodeAccount(id: customID, name: "Work", configDirectory: "/tmp/claude-work")
        let recent = UsageMetrics(service: .claudeCode, lastUpdated: now.addingTimeInterval(-60))

        let reports = ProviderReadinessInspector.reports(
            providers: [.claudeCode],
            refreshErrors: [.claudeCode: .apiError("HTTP 500 <body>")],
            accountRefreshErrors: [
                .claudeCode: [customID: .apiError("HTTP 500 <body>")],
            ],
            now: now,
            claudeAccounts: [.defaultAccount, custom],
            claudeAccountMetrics: [
                ClaudeCodeAccount.defaultID: recent,
            ],
            parseHealth: [
                .claudeCode: ProviderParseHealthRecord(
                    provider: .claudeCode,
                    lastSuccess: now.addingTimeInterval(-60),
                    lastAttempt: now,
                    consecutiveFailures: 1,
                    lastFailureWasShapeMismatch: true
                ),
            ],
            cachedMetrics: [.claudeCode: recent],
            cachedAccountMetrics: []
        )
        let byID = Dictionary(uniqueKeysWithValues: reports.compactMap { report -> (UUID, ProviderReadiness)? in
            guard let id = report.identity.accountID else { return nil }
            return (id, report)
        })

        XCTAssertEqual(byID[ClaudeCodeAccount.defaultID]?.check(ReadinessCheckID.refresh)?.level, .pass)
        XCTAssertEqual(byID[ClaudeCodeAccount.defaultID]?.check(ReadinessCheckID.parseHealth)?.level, .pass)
        XCTAssertNotEqual(byID[ClaudeCodeAccount.defaultID]?.overall, .fail)
        XCTAssertEqual(byID[customID]?.check(ReadinessCheckID.refresh)?.level, .fail)
    }

    func testClaudeCustomOnlyReportsTheCustomAccountError() {
        let now = Date(timeIntervalSince1970: 71_000)
        let customID = UUID()
        var disabledDefault = ClaudeCodeAccount.defaultAccount
        disabledDefault.isEnabled = false
        let custom = ClaudeCodeAccount(id: customID, name: "Work", configDirectory: "/tmp/claude-work")
        let recent = UsageMetrics(service: .claudeCode, lastUpdated: now.addingTimeInterval(-60))

        let reports = ProviderReadinessInspector.reports(
            providers: [.claudeCode],
            refreshErrors: [.claudeCode: .notAuthenticated],
            accountRefreshErrors: [
                .claudeCode: [customID: .notAuthenticated],
            ],
            now: now,
            claudeAccounts: [disabledDefault, custom],
            claudeAccountMetrics: [customID: recent],
            parseHealth: [:],
            cachedMetrics: [:],
            cachedAccountMetrics: []
        )
        let accountIDs = Set(reports.compactMap(\.identity.accountID))

        XCTAssertFalse(accountIDs.contains(ClaudeCodeAccount.defaultID))
        XCTAssertTrue(accountIDs.contains(customID))
        XCTAssertEqual(
            reports.first { $0.identity.accountID == customID }?.check(ReadinessCheckID.refresh)?.level,
            .fail
        )
    }

    func testParseHealthAggregationStaysHonestWhenOneAccountSucceedsAndOneFails() {
        let now = Date(timeIntervalSince1970: 80_000)
        let healthyID = UUID()
        let failingID = UUID()
        let healthy = GrokAccount(id: healthyID, name: "Healthy", homeDirectory: nil)
        let failing = GrokAccount(id: failingID, name: "Broken", homeDirectory: nil)
        let recent = UsageMetrics(service: .grok, lastUpdated: now.addingTimeInterval(-60))

        let reports = ProviderReadinessInspector.reports(
            providers: [.grok],
            accountRefreshErrors: [
                .grok: [failingID: .parsingError("HTTP 500 <body>")],
            ],
            now: now,
            grokAccounts: [healthy, failing],
            grokIsCLIInstalled: true,
            grokAuthProbe: { _ in (true, true) },
            parseHealth: [
                .grok: .success(provider: .grok, at: now.addingTimeInterval(-60)),
            ],
            cachedMetrics: [.grok: recent],
            cachedAccountMetrics: [
                AccountUsageSnapshot(id: healthyID, name: "Healthy", metrics: recent),
            ]
        )
        let byID = Dictionary(uniqueKeysWithValues: reports.compactMap { report -> (UUID, ProviderReadiness)? in
            guard let id = report.identity.accountID else { return nil }
            return (id, report)
        })
        let aggregate = reports.first { !$0.identity.isAccountScoped }

        XCTAssertEqual(byID[healthyID]?.check(ReadinessCheckID.parseHealth)?.level, .pass)
        XCTAssertEqual(byID[failingID]?.check(ReadinessCheckID.parseHealth)?.level, .fail)
        XCTAssertEqual(aggregate?.check(ReadinessCheckID.parseHealth)?.level, .warn)
        XCTAssertTrue(
            (aggregate?.check(ReadinessCheckID.parseHealth)?.detail ?? "").contains("Some accounts"),
            aggregate?.check(ReadinessCheckID.parseHealth)?.detail ?? ""
        )
    }

    func testDoctorJSONIncludesPerAccountIdentityWithoutPaths() throws {
        let fixtures = try grokMixedFixtures()
        defer { fixtures.tearDown() }

        let reports = ProviderReadinessInspector.reports(
            providers: [.grok],
            grokAccounts: [fixtures.healthy, fixtures.missing],
            grokIsCLIInstalled: true,
            parseHealth: [:],
            cachedMetrics: [:],
            cachedAccountMetrics: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(reports.map(ProviderReadinessExport.init))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertTrue(payload.contains { $0["accountName"] as? String == "Missing" })
        XCTAssertTrue(payload.contains { $0["accountId"] as? String == fixtures.missing.id.uuidString })
        XCTAssertFalse(json.contains(fixtures.missing.homeDirectory ?? "___"))
        XCTAssertFalse(json.contains("auth.json"))
        XCTAssertFalse(json.contains("homeDirectory"))
    }

    func testReportsGatherOnlyRequestedProvidersInStableOrder() {
        var gathered: [ServiceType] = []
        let reports = ProviderReadinessInspector.reports(
            providers: [.cursor, .codexCli],
            refreshErrors: [:],
            now: Date(timeIntervalSince1970: 1_000),
            claudeReport: { _, _ in
                gathered.append(.claudeCode)
                return [self.report(for: .claudeCode)]
            },
            codexReport: { _, _ in
                gathered.append(.codexCli)
                return [self.report(for: .codexCli)]
            },
            cursorReport: { _, _ in
                gathered.append(.cursor)
                return [self.report(for: .cursor)]
            }
        )

        XCTAssertEqual(gathered, [.codexCli, .cursor])
        XCTAssertEqual(reports.map(\.provider), [.codexCli, .cursor])
    }

    func testUnrelatedProvidersAreNotProbedWhenFiltered() {
        var probed: [ServiceType] = []
        _ = ProviderReadinessInspector.reports(
            providers: [.grok],
            refreshErrors: [:],
            now: Date(timeIntervalSince1970: 2_000),
            claudeReport: { _, _ in
                probed.append(.claudeCode)
                return [self.report(for: .claudeCode)]
            },
            codexReport: { _, _ in
                probed.append(.codexCli)
                return [self.report(for: .codexCli)]
            },
            cursorReport: { _, _ in
                probed.append(.cursor)
                return [self.report(for: .cursor)]
            },
            openRouterReport: { _, _ in
                probed.append(.openRouter)
                return [self.report(for: .openRouter)]
            },
            grokReport: { _, _ in
                probed.append(.grok)
                return [self.report(for: .grok)]
            }
        )

        XCTAssertEqual(probed, [.grok])
    }

    func testRecentClaudeUsageSkipsCredentialRead() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = UsageMetrics(service: .claudeCode, lastUpdated: now.addingTimeInterval(-60))
        var didReadCredentials = false

        _ = ProviderReadinessInspector.claudeReport(
            now: now,
            cachedMetrics: recent,
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertFalse(didReadCredentials)
    }

    func testStaleClaudeUsageFallsBackToCredentialRead() {
        let now = Date(timeIntervalSince1970: 100_000)
        let stale = UsageMetrics(
            service: .claudeCode,
            lastUpdated: now.addingTimeInterval(-ProviderReadinessInspector.recentUsageFetchWindow - 1)
        )
        var didReadCredentials = false

        _ = ProviderReadinessInspector.claudeReport(
            now: now,
            cachedMetrics: stale,
            isOAuthFallbackEnabled: { true },
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertTrue(didReadCredentials)
    }

    func testDisabledClaudeOAuthFallbackSkipsCredentialReadWithoutRecentUsage() {
        var didReadCredentials = false

        _ = ProviderReadinessInspector.claudeReport(
            cachedMetrics: nil,
            isOAuthFallbackEnabled: { false },
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertFalse(didReadCredentials)
    }

    func testDisabledDefaultClaudeProfileUsesEnabledCustomProfileMetrics() {
        let now = Date(timeIntervalSince1970: 20_000)
        let recentCustomMetrics = UsageMetrics(
            service: .claudeCode,
            lastUpdated: now.addingTimeInterval(-60)
        )
        var didReadCredentials = false

        let report = ProviderReadinessInspector.claudeReport(
            now: now,
            cachedMetrics: nil,
            defaultAccountEnabled: false,
            enabledAccountMetrics: [recentCustomMetrics],
            isCLIInstalled: true,
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertFalse(didReadCredentials)
        XCTAssertEqual(report.check(ReadinessCheckID.auth)?.level, .pass)
        XCTAssertFalse(report.needsSetup)
    }

    func testDisabledDefaultClaudeProfileNeverReadsGlobalCredentials() {
        var didReadCredentials = false

        let report = ProviderReadinessInspector.claudeReport(
            cachedMetrics: UsageMetrics(service: .claudeCode),
            defaultAccountEnabled: false,
            enabledAccountMetrics: [],
            isCLIInstalled: true,
            credentialsData: {
                didReadCredentials = true
                return Data(#"{"claudeAiOauth":{"accessToken":"disabled-default"}}"#.utf8)
            }
        )

        XCTAssertFalse(didReadCredentials)
        XCTAssertEqual(report.check(ReadinessCheckID.auth)?.level, .warn)
        XCTAssertFalse(report.needsSetup)
    }

    func testEnabledDefaultClaudeProfileFallsBackToRecentSharedMetrics() {
        let now = Date(timeIntervalSince1970: 30_000)
        let recentCachedMetrics = UsageMetrics(
            service: .claudeCode,
            lastUpdated: now.addingTimeInterval(-60)
        )
        var didReadCredentials = false

        let report = ProviderReadinessInspector.claudeReport(
            now: now,
            cachedMetrics: recentCachedMetrics,
            defaultAccountEnabled: true,
            enabledAccountMetrics: [],
            isCLIInstalled: true,
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertFalse(didReadCredentials)
        XCTAssertEqual(report.check(ReadinessCheckID.auth)?.level, .pass)
        XCTAssertFalse(report.needsSetup)
    }

    func testDisabledDefaultClaudeProfileIgnoresStaleCustomMetricsWithoutCredentialRead() {
        let now = Date(timeIntervalSince1970: 40_000)
        let staleCustomMetrics = UsageMetrics(
            service: .claudeCode,
            lastUpdated: now.addingTimeInterval(-ProviderReadinessInspector.recentUsageFetchWindow - 1)
        )
        var didReadCredentials = false

        let report = ProviderReadinessInspector.claudeReport(
            now: now,
            cachedMetrics: nil,
            defaultAccountEnabled: false,
            enabledAccountMetrics: [staleCustomMetrics],
            isCLIInstalled: true,
            credentialsData: {
                didReadCredentials = true
                return nil
            }
        )

        XCTAssertFalse(didReadCredentials)
        XCTAssertEqual(report.check(ReadinessCheckID.auth)?.level, .warn)
        XCTAssertFalse(report.needsSetup)
    }

    func testReportsForwardEnabledCustomClaudeMetrics() {
        let now = Date(timeIntervalSince1970: 50_000)
        let recentCustomMetrics = UsageMetrics(
            service: .claudeCode,
            lastUpdated: now.addingTimeInterval(-60)
        )

        var disabledDefault = ClaudeCodeAccount.defaultAccount
        disabledDefault.isEnabled = false
        let custom = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/tmp/claude-work"
        )
        let reports = ProviderReadinessInspector.reports(
            providers: [.claudeCode],
            now: now,
            claudeAccounts: [disabledDefault, custom],
            claudeAccountMetrics: [custom.id: recentCustomMetrics],
            claudeDefaultAccountEnabled: false,
            claudeEnabledAccountMetrics: [recentCustomMetrics],
            parseHealth: [:]
        )

        XCTAssertEqual(
            reports.first { $0.identity.accountID == custom.id }?.check(ReadinessCheckID.auth)?.level,
            .pass
        )
    }

    func testApiErrorDropsResponseBodyKeepsStatusCode() {
        let raw = ServiceError.apiError("HTTP 500: {\"user\":\"vincent@genfeed.ai\",\"token\":\"sk-SECRET\"}")
        let sanitized = ProviderReadinessInspector.sanitize(raw)

        XCTAssertEqual(sanitized, "API error (HTTP 500)")
        XCTAssertFalse(sanitized?.contains("SECRET") ?? false)
        XCTAssertFalse(sanitized?.contains("vincent@genfeed.ai") ?? false)
    }

    func testApiErrorWithoutStatusIsGeneric() {
        let sanitized = ProviderReadinessInspector.sanitize(.apiError("Bearer sk-SECRET leaked here"))

        XCTAssertEqual(sanitized, "API error")
        XCTAssertFalse(sanitized?.contains("SECRET") ?? false)
    }

    func testSafeNetworkMessagesPassThrough() {
        XCTAssertEqual(
            ProviderReadinessInspector.sanitize(.apiError("No internet connection")),
            "No internet connection"
        )
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.apiError("Request timed out")), "Request timed out")
        XCTAssertEqual(
            ProviderReadinessInspector.sanitize(.apiError("Secure connection failed")),
            "Secure connection failed"
        )
    }

    func testKnownCasesMapToStableStrings() {
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.notAuthenticated), "Not authenticated")
        XCTAssertEqual(ProviderReadinessInspector.sanitize(.parsingError(nil)), "Could not parse the provider response")
        XCTAssertNil(ProviderReadinessInspector.sanitize(nil))
    }

    func testParseHealthAddsImmediateFormatMismatchCheckWithStalenessThreshold() {
        let now = Date(timeIntervalSince1970: 40_000)
        let record = ProviderParseHealthRecord(
            provider: .cursor,
            lastSuccess: now.addingTimeInterval(-60),
            lastAttempt: now,
            consecutiveFailures: 1,
            lastFailureWasShapeMismatch: true
        )

        let reports = ProviderReadinessInspector.reports(
            providers: [.cursor],
            now: now,
            parseHealth: [.cursor: record],
            cachedMetrics: [:],
            cachedAccountMetrics: []
        )
        let check = reports.first?.check(ReadinessCheckID.parseHealth)

        XCTAssertEqual(check?.level, .fail)
        XCTAssertTrue(check?.detail.contains("format") ?? false)
        XCTAssertTrue(check?.detail.contains("2 hours") ?? false)
    }

    func testFreshPayloadSupersedesOlderParseHealthTimestamp() {
        let now = Date(timeIntervalSince1970: 50_000)
        let record = ProviderParseHealthRecord.success(
            provider: .cursor,
            at: now.addingTimeInterval(-ProviderParseHealthRecord.staleAfter - 1)
        )
        let metrics = UsageMetrics(
            service: .cursor,
            lastUpdated: now.addingTimeInterval(-60)
        )

        let reports = ProviderReadinessInspector.reports(
            providers: [.cursor],
            now: now,
            parseHealth: [.cursor: record],
            cachedMetrics: [.cursor: metrics],
            cachedAccountMetrics: []
        )

        XCTAssertEqual(reports.first?.check(ReadinessCheckID.parseHealth)?.level, .pass)
    }

    func testPersistedFailureReplacesContradictoryNoErrorRefreshCheck() {
        let now = Date(timeIntervalSince1970: 60_000)
        let metrics = UsageMetrics(
            service: .cursor,
            lastUpdated: now.addingTimeInterval(-ProviderParseHealthRecord.staleAfter - 60)
        )
        let record = ProviderParseHealthRecord(
            provider: .cursor,
            lastSuccess: metrics.lastUpdated,
            lastAttempt: now.addingTimeInterval(-60),
            consecutiveFailures: 1,
            lastFailureWasShapeMismatch: false
        )

        let reports = ProviderReadinessInspector.reports(
            providers: [.cursor],
            now: now,
            parseHealth: [.cursor: record],
            cachedMetrics: [.cursor: metrics],
            cachedAccountMetrics: []
        )
        let refresh = reports.first?.check(ReadinessCheckID.refresh)

        XCTAssertEqual(refresh?.level, .warn)
        XCTAssertTrue(refresh?.detail.contains("latest recorded refresh failed") ?? false)
    }

    func testHttpStatusExtraction() {
        XCTAssertEqual(ProviderReadinessInspector.httpStatus(in: "HTTP 404: not found"), 404)
        XCTAssertNil(ProviderReadinessInspector.httpStatus(in: "no status here"))
    }

    private func report(for provider: ServiceType) -> ProviderReadiness {
        ProviderReadiness(
            provider: provider,
            checks: [ReadinessCheck(id: "test", title: "Test", level: .pass, detail: "Ready")]
        )
    }

    private func grokMixedFixtures() throws -> (
        healthy: GrokAccount,
        missing: GrokAccount,
        tearDown: () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderReadinessInspectorTests-\(UUID().uuidString)", isDirectory: true)
        let healthyHome = root.appendingPathComponent("healthy", isDirectory: true)
        try FileManager.default.createDirectory(at: healthyHome, withIntermediateDirectories: true)
        try Data().write(to: healthyHome.appendingPathComponent("auth.json"))
        let healthy = GrokAccount(id: UUID(), name: "Healthy", homeDirectory: healthyHome.path)
        let missing = GrokAccount(
            id: UUID(),
            name: "Missing",
            homeDirectory: root.appendingPathComponent("missing").path
        )
        return (healthy, missing, { try? FileManager.default.removeItem(at: root) })
    }

    private func futureCodexAuthJSON() -> Data {
        let payload = Data(#"{"exp":2000000}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).signature"
        return Data(
            """
            {"OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"\(token)",\
            "refresh_token":"refresh","account_id":"acct_test"},"last_refresh":"2026-07-03T00:00:00Z"}
            """.utf8
        )
    }
}
