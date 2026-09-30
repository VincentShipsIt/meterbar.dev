import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// The `meterbar route` contract: input resolution, candidate assembly from
/// MeterBar's caches, the versioned JSON document, the stable exit codes, the
/// human report, and the privacy invariants routing output must never break.
final class RouteCLITests: XCTestCase {
    private typealias Fixtures = RoutingFixtures

    // MARK: - Input resolution

    func testTaskFlagIsRequiredAndSaysWhatIsAccepted() {
        for raw in [nil, "", "   "] {
            let failure = expectFailure(task: raw)
            XCTAssertEqual(failure.code, "missing_task")
            XCTAssertEqual(failure.flag, "--task")
            XCTAssertNil(failure.value)
            XCTAssertTrue(failure.message.contains("implementation"), failure.message)
            XCTAssertTrue(failure.message.contains("quick-edit"), failure.message)
        }
    }

    func testMalformedTaskIsAUsageErrorNamingTheInput() {
        let failure = expectFailure(task: "Not Valid!")
        XCTAssertEqual(failure.code, "invalid_task")
        XCTAssertEqual(failure.flag, "--task")
        XCTAssertEqual(failure.value, "Not Valid!")
        XCTAssertTrue(failure.message.contains("Not Valid!"), failure.message)
    }

    func testWellFormedButUndefinedCustomTaskIsUnknownAndListsWhatExists() {
        let catalog = RoutingPolicyCatalog(
            document: RoutingPolicyDocument(policies: [RoutingPolicy(task: RoutingTaskID(token: "triage")!, name: "Triage")])
        )
        let failure = expectFailure(task: "release-notes", catalog: catalog)
        XCTAssertEqual(failure.code, "unknown_task")
        XCTAssertEqual(failure.value, "release-notes")
        XCTAssertTrue(failure.message.contains("triage"), failure.message)
    }

    func testEveryBuiltInTaskAndEveryDefinedCustomTaskResolves() throws {
        for id in RoutingTaskID.builtIn {
            XCTAssertEqual(try target(task: id.rawValue).policy.task, id)
        }
        XCTAssertEqual(try target(task: "Quick_Edit").policy.task, .quickEdit)

        let triage = RoutingTaskID(token: "triage")!
        let catalog = RoutingPolicyCatalog(
            document: RoutingPolicyDocument(policies: [RoutingPolicy(task: triage, name: "Triage")])
        )
        XCTAssertEqual(try target(task: "triage", catalog: catalog).policy.name, "Triage")
    }

    func testMalformedOrOutOfRangeRefreshTimeoutIsAUsageErrorNamingTheInput() {
        for raw in ["abc", "100000", "0", "-5", "", "1e"] {
            let failure = expectFailure(task: "review", refreshTimeout: raw)
            XCTAssertEqual(failure.code, "invalid_refresh_timeout", raw)
            XCTAssertEqual(failure.flag, "--refresh-timeout", raw)
            XCTAssertEqual(failure.value, raw, raw)
        }
        XCTAssertEqual(try target(task: "review", refreshTimeout: "45").refreshTimeout, 45)
        XCTAssertEqual(try target(task: "review").refreshTimeout, WorkloadRouteCLI.defaultRefreshTimeout)
    }

    func testUnsafeUsageErrorValuesNeverReachAnyJSONOrHumanField() throws {
        for raw in [
            "/Users/test/private-task.md",
            "review@example.invalid",
            "~private",
            "folder\\task",
            "\u{001B}[31mprivate",
        ] {
            for failure in [expectFailure(task: raw), expectFailure(task: "review", refreshTimeout: raw)] {
                let response = RouteCLIResponse(failure: failure, checkedAt: Fixtures.now)
                let json = try response.jsonString()
                XCTAssertFalse(json.contains(raw), json)
                XCTAssertFalse(failure.message.contains(raw), failure.message)
                XCTAssertEqual(response.exitCode, 13)
                XCTAssertEqual(failure.value, "[redacted]")
                XCTAssertTrue(failure.message.contains("[redacted]"))
            }
        }
    }

    // MARK: - JSON contract

    func testRecommendationDocumentShapeIsTheVersionOneContract() throws {
        let work = Fixtures.uuid(1)
        let personal = Fixtures.uuid(2)
        let result = evaluate(
            task: "implementation",
            candidates: [
                Fixtures.account(.codexCli, id: work, name: "Work", used: 26),
                Fixtures.account(.claudeCode, id: personal, name: "Personal", used: 60),
            ]
        )

        let json = try decode(result)
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["outcome"] as? String, "recommended")
        XCTAssertEqual(json["exitCode"] as? Int, 0)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(json["checkedAt"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(json["message"] as? String, "Use Codex · Work · standard model")
        XCTAssertNil(json["error"])
        XCTAssertEqual((json["policy"] as? [String: Any])?["customized"] as? Bool, false)
        XCTAssertEqual(
            json["task"] as? [String: AnyHashable],
            ["id": "implementation", "name": "Implementation", "builtIn": true]
        )

        let route = try XCTUnwrap(json["recommendation"] as? [String: Any])
        XCTAssertEqual(Set(route.keys), ["rank", "provider", "providerName", "account", "model", "score", "quota", "freshness", "reasons"])
        XCTAssertEqual(route["rank"] as? Int, 1)
        XCTAssertEqual(route["provider"] as? String, "codex")
        XCTAssertEqual(route["providerName"] as? String, "OpenAI Codex")
        XCTAssertEqual(route["account"] as? [String: String], ["id": work.uuidString, "label": "Work"])
        XCTAssertEqual(route["model"] as? [String: String], ["tier": "standard"])

        let quota = try XCTUnwrap(route["quota"] as? [String: Any])
        XCTAssertEqual(quota["window"] as? String, "session")
        XCTAssertEqual(quota["percentLeft"] as? Int, 74)
        XCTAssertEqual(quota["quotaBand"] as? String, "healthy")
        XCTAssertEqual(quota["estimated"] as? Bool, false)
        XCTAssertNotNil(quota["resetAt"] as? String)

        let freshness = try XCTUnwrap(route["freshness"] as? [String: Any])
        XCTAssertEqual(freshness["ageSeconds"] as? Int, 60)
        XCTAssertEqual(freshness["isStale"] as? Bool, false)
        XCTAssertEqual(freshness["lastUpdated"] as? String, "2023-11-14T22:12:20Z")

        let reasons = try XCTUnwrap(route["reasons"] as? [[String: String]])
        XCTAssertEqual(reasons.first?["code"], "quota_headroom")
        XCTAssertEqual(reasons.first?["message"], "74% session quota remains")

        let fallbacks = try XCTUnwrap(json["fallbacks"] as? [[String: Any]])
        XCTAssertEqual(fallbacks.map { $0["provider"] as? String }, ["claude"])
        XCTAssertEqual(fallbacks.first?["rank"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(json["rejected"] as? [Any]).count, 0)
    }

    func testFallbacksAndRejectedAreAlwaysArraysOnASuccessfulRoute() throws {
        let json = try decode(evaluate(task: "review", candidates: [Fixtures.candidate(.claudeCode, used: 10)]))
        XCTAssertEqual((json["fallbacks"] as? [Any])?.count, 0)
        XCTAssertEqual((json["rejected"] as? [Any])?.count, 0)
        XCTAssertEqual((json["reasons"] as? [[String: String]])?.map { $0["code"] }, ["only_eligible_candidate"])
    }

    func testNoEligibleCandidateEmitsExit11WithEveryRejectionAndNoRecommendation() throws {
        let result = evaluate(
            task: "planning",
            candidates: [
                Fixtures.candidate(.claudeCode, used: 100),
                Fixtures.candidate(.codexCli, used: 90),
            ]
        )

        let json = try decode(result)
        XCTAssertEqual(result.exitCode, 11)
        XCTAssertEqual(json["outcome"] as? String, "noEligibleCandidate")
        XCTAssertEqual(json["exitCode"] as? Int, 11)
        XCTAssertNil(json["recommendation"])
        let rejected = try XCTUnwrap(json["rejected"] as? [[String: Any]])
        XCTAssertEqual(rejected.map { $0["code"] as? String }, ["quota_exhausted", "below_minimum_headroom"])
        XCTAssertEqual(rejected.map { $0["provider"] as? String }, ["claude", "codex"])
        XCTAssertNotNil(rejected.first?["freshness"] as? [String: Any])
        XCTAssertEqual((json["fallbacks"] as? [Any])?.count, 0)
    }

    func testNoUsableDataEmitsExit12() throws {
        let result = evaluate(task: "review", candidates: [])
        let json = try decode(result)
        XCTAssertEqual(result.exitCode, 12)
        XCTAssertEqual(json["outcome"] as? String, "dataUnavailable")
        XCTAssertEqual((json["reasons"] as? [[String: String]])?.map { $0["code"] }, ["no_candidates"])
    }

    func testUsageErrorDocumentMirrorsGuardsErrorShape() throws {
        let failure = expectFailure(task: "nope!")
        let response = RouteCLIResponse(failure: failure, checkedAt: Fixtures.now)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.jsonString().utf8)) as? [String: Any]
        )

        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["outcome"] as? String, "usageError")
        XCTAssertEqual(json["exitCode"] as? Int, 13)
        XCTAssertEqual(response.exitCode, RoutingOutcome.usageErrorExitCode)
        XCTAssertEqual(json["message"] as? String, failure.message)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_task")
        XCTAssertEqual(error["flag"] as? String, "--task")
        XCTAssertEqual(error["value"] as? String, "nope!")
        XCTAssertNil(json["recommendation"])
        XCTAssertNil(json["task"])
    }

    func testACustomisedPolicyIsFlaggedAndAStoredPolicyBeatsTheDefault() throws {
        var edited = RoutingPolicyDefaults.policy(for: .review)
        edited.minimumRemainingPercent = 80
        let catalog = RoutingPolicyCatalog(document: RoutingPolicyDocument(policies: [edited]))

        let result = evaluate(task: "review", catalog: catalog, candidates: [Fixtures.candidate(.claudeCode, used: 50)])
        let json = try decode(result)

        XCTAssertEqual((json["policy"] as? [String: Any])?["customized"] as? Bool, true)
        XCTAssertEqual(json["outcome"] as? String, "noEligibleCandidate")
    }

    func testAPolicyNoticeSurfacesAsADecisionReasonWithoutChangingTheOutcome() throws {
        let notice = RoutingReason(code: .policyUnreadable, message: "Routing policies could not be read; using defaults.")
        let result = evaluate(task: "review", notice: notice, candidates: [Fixtures.candidate(.claudeCode, used: 10)])

        let codes = (try decode(result)["reasons"] as? [[String: String]])?.map { $0["code"] }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(codes, ["only_eligible_candidate", "policy_unreadable"])
        XCTAssertTrue(result.details.contains("Note: \(notice.message)"))
    }

    // MARK: - Privacy invariants

    func testNoCredentialPathEmailOrPromptContentCanAppearInRoutingJSON() throws {
        let hostile = [
            Fixtures.account(.claudeCode, id: Fixtures.uuid(1), name: "vincent@example.com", used: 10),
            Fixtures.account(.codexCli, id: Fixtures.uuid(2), name: "/Users/vincent/.codex", used: 20),
            Fixtures.account(.grok, id: Fixtures.uuid(3), name: "~/.grok-work", used: 30),
            Fixtures.candidate(.cursor, used: 100),
            RoutingCandidate(service: .openRouter, metrics: nil),
        ]
        var policy = RoutingPolicyDefaults.policy(for: .implementation)
        policy.modelAliases = [.codexCli: "gpt-test-1"]
        policy.name = "vincent@example.com"
        let catalog = RoutingPolicyCatalog(document: RoutingPolicyDocument(policies: [policy]))

        let output = evaluate(task: "implementation", catalog: catalog, candidates: hostile).jsonOutput

        for forbidden in ["@", "/Users", "~/", ".codex", ".grok", "example.com", "token", "Bearer", "password", "sk-", "http"] {
            XCTAssertFalse(output.contains(forbidden), "routing JSON leaked \(forbidden):\n\(output)")
        }
        XCTAssertTrue(output.contains("Account 01000000"))
    }

    func testRoutingSourcesCannotLaunchProcessesTouchCredentialsOrReadPrompts() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directories = [
            repoRoot.appendingPathComponent("Packages/MeterBarShared/Sources/MeterBarShared/Routing"),
            repoRoot.appendingPathComponent("MeterBar/Routing"),
        ]
        let forbidden = [
            "Process(", "NSTask", "posix_spawn", "execv", "system(", "Keychain", "SecItem", "UserDefaults",
            "URLSession", "NSPasteboard", "credential", "Credential", "prompt", "Prompt", "CLIBinaryLocator",
            "AccountCredentialSwitcher",
        ]
        // `CLIBoundedRefresh` is the one sanctioned side effect: the bounded
        // refresh `--refresh` opts into, shared with `meterbar guard`.
        let sources = try directories.flatMap { directory in
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
        }
        XCTAssertGreaterThanOrEqual(sources.count, 10)

        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(source.lastPathComponent) mentions \(token)")
            }
        }
    }

    // MARK: - Human report

    func testTheHumanReportFollowsTheEpicExample() {
        let result = evaluate(
            task: "implementation",
            candidates: [
                Fixtures.account(.codexCli, id: Fixtures.uuid(1), name: "Work", used: 26),
                Fixtures.account(.claudeCode, id: Fixtures.uuid(2), name: "Personal", used: 60),
                RoutingCandidate(service: .cursor, metrics: nil),
            ]
        )

        XCTAssertEqual(result.headline, "Route: Implementation → Codex · Work · standard model")
        XCTAssertEqual(result.details, [
            "Why:",
            "  • 74% session quota remains",
            "  • Uses included subscription quota",
            "Fallback: Claude · Personal · standard model",
            "Skipped:",
            "  • No usage cached yet for Cursor",
        ])
    }

    func testTheHumanReportListsSeveralFallbacksInOrder() {
        let result = evaluate(
            task: "review",
            candidates: [
                Fixtures.candidate(.claudeCode, used: 10),
                Fixtures.candidate(.codexCli, used: 20),
                Fixtures.candidate(.grok, used: 30),
            ]
        )
        XCTAssertTrue(result.details.contains("Fallbacks:"))
        XCTAssertTrue(result.details.contains("  1. Codex · premium model"))
        XCTAssertTrue(result.details.contains("  2. Grok · premium model"))
    }

    func testTheHumanReportExplainsEveryRejectionWhenNothingIsEligible() {
        let result = evaluate(
            task: "planning",
            candidates: [
                Fixtures.candidate(.claudeCode, used: 100),
                Fixtures.candidate(.codexCli, used: 5, age: 9 * 3_600),
            ]
        )

        XCTAssertEqual(result.exitCode, 11)
        XCTAssertEqual(result.headline, "Route: Planning → no route available")
        XCTAssertEqual(result.details.first, "No eligible route for Planning: every candidate was rejected.")
        XCTAssertTrue(result.details.contains("  • Claude Code: session quota is spent, resets in 3h"), "\(result.details)")
        XCTAssertTrue(result.details.contains { $0.contains("usage is 9h old") })
    }

    // MARK: - Candidate assembly

    func testAccountSnapshotsReplaceTheProviderWideRollUpSoQuotaIsNotCountedTwice() {
        let work = Fixtures.uuid(1)
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [.claudeCode: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 5))],
            accounts: [AccountUsageSnapshot(id: work, name: "Work", metrics: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 40)))],
            configuration: nil,
            health: [:]
        )

        let claude = candidates.filter { $0.service == .claudeCode }
        XCTAssertEqual(claude.count, 1)
        XCTAssertEqual(claude.first?.accountID, work)
        XCTAssertEqual(claude.first?.accountName, "Work")
    }

    func testProvidersWithoutAccountSnapshotsUseTheirProviderWideSnapshotAndCursorAlwaysDoes() {
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [
                .cursor: Fixtures.metrics(.cursor, session: Fixtures.limit(used: 20)),
                .codexCli: Fixtures.metrics(.codexCli, session: Fixtures.limit(used: 30)),
            ],
            accounts: [],
            configuration: nil,
            health: [:]
        )

        XCTAssertEqual(Set(candidates.map(\.service)), Set(ServiceType.allCases))
        XCTAssertTrue(candidates.allSatisfy { $0.accountID == nil })
        XCTAssertNotNil(candidates.first { $0.service == .cursor }?.metrics)
        XCTAssertNil(candidates.first { $0.service == .grok }?.metrics)
    }

    func testHiddenProvidersAreNeverCandidates() {
        let configuration = UsageRefreshConfigurationStore.Snapshot(
            hiddenServices: [.openRouter, .cursor],
            claudeAccounts: [],
            codexAccounts: []
        )
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [.cursor: Fixtures.metrics(.cursor, session: Fixtures.limit(used: 20))],
            accounts: [],
            configuration: configuration,
            health: [:]
        )
        XCTAssertFalse(candidates.contains { $0.service == .cursor || $0.service == .openRouter })
    }

    func testConfiguredAccountsSetOrderEnablementAndSurfaceAnAccountWithNoSnapshot() {
        let first = Fixtures.uuid(1)
        let second = Fixtures.uuid(2)
        let third = Fixtures.uuid(3)
        let configuration = UsageRefreshConfigurationStore.Snapshot(
            hiddenServices: [],
            claudeAccounts: [
                ClaudeCodeAccount(id: first, name: "Work", configDirectory: "/private/work"),
                ClaudeCodeAccount(id: second, name: "Personal", configDirectory: "/private/personal"),
                ClaudeCodeAccount(id: third, name: "Old", configDirectory: nil, isEnabled: false),
            ],
            codexAccounts: []
        )
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [:],
            accounts: [
                AccountUsageSnapshot(id: second, name: "Personal", metrics: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 40))),
                AccountUsageSnapshot(id: third, name: "Old", metrics: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 10))),
            ],
            configuration: configuration,
            health: [:]
        )

        let claude = candidates.filter { $0.service == .claudeCode }
        XCTAssertEqual(claude.map(\.accountID), [first, second, third])
        XCTAssertEqual(claude.map(\.displayOrder), [0, 1, 2])
        XCTAssertEqual(claude.map(\.isEnabled), [true, true, false])
        XCTAssertNil(claude[0].metrics, "a configured account with no cached usage is reported, not hidden")
        XCTAssertNotNil(claude[1].metrics)

        let decision = Fixtures.route(claude)
        XCTAssertEqual(decision.recommendation?.account?.label, "Personal")
        XCTAssertEqual(Set(decision.rejectionCodes), [.snapshotMissing, .providerDisabled])
        let encoded = String(decoding: (try? JSONEncoder().encode(decision)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("/private"), "config directories must never reach routing output")
    }

    func testDisabledAndUnlistedCachedAccountsAreRejected() {
        let listed = Fixtures.uuid(1)
        let stray = Fixtures.uuid(5)
        let configuration = UsageRefreshConfigurationStore.Snapshot(
            hiddenServices: [],
            claudeAccounts: [ClaudeCodeAccount(id: listed, name: "Off", configDirectory: nil, isEnabled: false)],
            codexAccounts: []
        )
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [:],
            accounts: [AccountUsageSnapshot(id: stray, name: "Stray", metrics: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 40)))],
            configuration: configuration,
            health: [:]
        )

        let claude = candidates.filter { $0.service == .claudeCode }
        XCTAssertEqual(claude.map(\.accountID), [listed, stray])
        XCTAssertEqual(claude.map(\.isEnabled), [false, false])
        let decision = Fixtures.route(claude)
        XCTAssertEqual(decision.outcome, .noEligibleCandidate)
        XCTAssertNil(decision.recommendation)
        XCTAssertEqual(decision.rejectionCodes, [.providerDisabled, .providerDisabled])
    }

    func testConfiguredAccountsWithOnlyAProviderWideCacheStillRouteOnThatCache() {
        let configuration = UsageRefreshConfigurationStore.Snapshot(
            hiddenServices: [],
            claudeAccounts: [.defaultAccount],
            codexAccounts: [.defaultAccount]
        )
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [.claudeCode: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 20))],
            accounts: [],
            configuration: configuration,
            health: [:]
        )

        let claude = candidates.filter { $0.service == .claudeCode }
        XCTAssertEqual(claude.count, 1)
        XCTAssertNil(claude.first?.accountID)
        XCTAssertNotNil(claude.first?.metrics)
        XCTAssertEqual(Fixtures.route(claude).outcome, .recommended)
    }

    func testProviderWideCandidateIsOffOnlyWhenEveryConfiguredAccountIsOff() {
        func candidate(_ accounts: [CodexAccount]) -> RoutingCandidate? {
            RoutingCandidateAssembler.assemble(
                metrics: [.codexCli: Fixtures.metrics(.codexCli, session: Fixtures.limit(used: 20))],
                accounts: [],
                configuration: UsageRefreshConfigurationStore.Snapshot(
                    hiddenServices: [],
                    claudeAccounts: [],
                    codexAccounts: accounts
                ),
                health: [:]
            ).first { $0.service == .codexCli }
        }
        let on = CodexAccount(id: Fixtures.uuid(1), name: "On", homeDirectory: nil)
        let off = CodexAccount(id: Fixtures.uuid(2), name: "Off", homeDirectory: nil, isEnabled: false)

        XCTAssertEqual(candidate([on, off])?.isEnabled, true)
        XCTAssertEqual(candidate([off])?.isEnabled, false)
        XCTAssertEqual(candidate([])?.isEnabled, false)
    }

    func testEmptyAuthoritativeAccountListsCannotReviveProviderWideSnapshots() {
        let configuration = UsageRefreshConfigurationStore.Snapshot(
            hiddenServices: [], claudeAccounts: [], codexAccounts: [], grokAccounts: [], openRouterAccounts: []
        )
        let metrics = Dictionary(uniqueKeysWithValues: ServiceType.allCases.map {
            ($0, Fixtures.metrics($0, session: Fixtures.limit(used: 20)))
        })
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: metrics, accounts: [], configuration: configuration, health: [:]
        )
        XCTAssertEqual(Fixtures.route(candidates).chain, ["cursor"])
        XCTAssertEqual(candidates.filter { $0.service != .cursor }.map(\.isEnabled), [false, false, false, false])
    }

    func testAnOrphanWithMoreHeadroomNeverBecomesARecommendationOrFallback() {
        let listed = Fixtures.uuid(1)
        let removed = Fixtures.uuid(42)
        let configuration = UsageRefreshConfigurationStore.Snapshot(
            hiddenServices: [],
            claudeAccounts: [ClaudeCodeAccount(id: listed, name: "Active", configDirectory: nil)],
            codexAccounts: []
        )
        let snapshots = [
            AccountUsageSnapshot(
                id: removed,
                name: "Removed",
                metrics: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 0))
            ),
            AccountUsageSnapshot(
                id: listed,
                name: "Active",
                metrics: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 50))
            ),
        ]
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [:], accounts: snapshots, configuration: configuration, health: [:]
        ).filter { $0.service == .claudeCode }
        let decision = Fixtures.route(candidates)
        XCTAssertEqual(decision.recommendation?.account?.id, listed.uuidString)
        XCTAssertTrue(decision.fallbacks.isEmpty)
        XCTAssertEqual(decision.rejected.first?.account?.id, removed.uuidString)
        XCTAssertEqual(decision.rejected.first?.code, .providerDisabled)

        let legacy = RoutingCandidateAssembler.assemble(
            metrics: [:], accounts: snapshots, configuration: nil, health: [:]
        ).filter { $0.service == .claudeCode }
        XCTAssertEqual(Fixtures.route(legacy).recommendation?.account?.id, removed.uuidString)
    }

    func testLegacyAccountDecisionsDoNotDependOnCacheOrder() {
        let snapshots = [
            AccountUsageSnapshot(
                id: Fixtures.uuid(42),
                name: "Second",
                metrics: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 50))
            ),
            AccountUsageSnapshot(
                id: Fixtures.uuid(1),
                name: "First",
                metrics: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 50))
            ),
        ]
        func decision(_ snapshots: [AccountUsageSnapshot]) -> RoutingDecision {
            Fixtures.route(RoutingCandidateAssembler.assemble(
                metrics: [:], accounts: snapshots, configuration: nil, health: [:]
            ).filter { $0.service == .claudeCode })
        }
        XCTAssertEqual(decision(snapshots), decision(snapshots.reversed()))
        XCTAssertEqual(decision(snapshots).recommendation?.account?.id, Fixtures.uuid(1).uuidString)
    }

    func testProviderHealthMapsFromTheParseHealthRecord() {
        let now = Fixtures.now
        func record(failures: Int, mismatches: Int = 0) -> ProviderParseHealthRecord {
            ProviderParseHealthRecord(
                provider: .grok,
                lastSuccess: now,
                lastAttempt: now,
                consecutiveFailures: failures,
                lastFailureWasShapeMismatch: mismatches > 0,
                consecutiveShapeMismatches: mismatches
            )
        }

        XCTAssertEqual(RoutingCandidateAssembler.routingHealth(nil), .healthy)
        XCTAssertEqual(RoutingCandidateAssembler.routingHealth(record(failures: 0)), .healthy)
        XCTAssertEqual(RoutingCandidateAssembler.routingHealth(record(failures: 1)), .degraded)
        XCTAssertEqual(RoutingCandidateAssembler.routingHealth(record(failures: 2)), .degraded)
        XCTAssertEqual(RoutingCandidateAssembler.routingHealth(record(failures: 3)), .failing)
        XCTAssertEqual(RoutingCandidateAssembler.routingHealth(record(failures: 2, mismatches: 2)), .failing)

        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [.grok: Fixtures.metrics(.grok, session: Fixtures.limit(used: 20))],
            accounts: [],
            configuration: nil,
            health: [.grok: record(failures: 3)]
        )
        XCTAssertEqual(candidates.first { $0.service == .grok }?.health, .failing)
    }

    func testEndToEndFromCachesToDecisionForASingleProviderUser() throws {
        let candidates = RoutingCandidateAssembler.assemble(
            metrics: [.claudeCode: Fixtures.metrics(.claudeCode, session: Fixtures.limit(used: 35))],
            accounts: [],
            configuration: UsageRefreshConfigurationStore.Snapshot(
                hiddenServices: [.cursor, .openRouter, .grok],
                claudeAccounts: [.defaultAccount],
                codexAccounts: []
            ),
            health: [:]
        )
        let result = evaluate(task: "debugging", candidates: candidates)

        let json = try decode(result)
        XCTAssertEqual(json["outcome"] as? String, "recommended")
        XCTAssertEqual((json["recommendation"] as? [String: Any])?["provider"] as? String, "claude")
        XCTAssertEqual(result.headline, "Route: Debugging → Claude · standard model")
    }

    // MARK: - Helpers

    private func target(
        task: String?,
        catalog: RoutingPolicyCatalog = RoutingPolicyCatalog(),
        refreshTimeout: String? = nil
    ) throws -> WorkloadRouteCLI.Target {
        switch WorkloadRouteCLI.resolve(
            WorkloadRouteCLI.Request(task: task, refreshTimeout: refreshTimeout),
            catalog: catalog
        ) {
        case let .success(target): return target
        case let .failure(failure): throw failure
        }
    }

    private func expectFailure(
        task: String?,
        catalog: RoutingPolicyCatalog = RoutingPolicyCatalog(),
        refreshTimeout: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> RouteUsageFailure {
        do {
            _ = try target(task: task, catalog: catalog, refreshTimeout: refreshTimeout)
        } catch let failure as RouteUsageFailure {
            return failure
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        XCTFail("expected a usage failure", file: file, line: line)
        return RouteUsageFailure(code: "", message: "", flag: nil, value: nil)
    }

    private func evaluate(
        task: String,
        catalog: RoutingPolicyCatalog = RoutingPolicyCatalog(),
        notice: RoutingReason? = nil,
        candidates: [RoutingCandidate]
    ) -> WorkloadRouteCLI.Result {
        guard let target = try? target(task: task, catalog: catalog) else {
            XCTFail("task \(task) did not resolve")
            return WorkloadRouteCLI.Result(jsonOutput: "{}", headline: "", details: [], exitCode: -1)
        }
        return WorkloadRouteCLI.evaluate(
            target: target,
            catalog: catalog,
            notice: notice,
            candidates: candidates,
            now: Fixtures.now
        )
    }

    private func decode(_ result: WorkloadRouteCLI.Result) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.jsonOutput.utf8)) as? [String: Any])
    }
}
