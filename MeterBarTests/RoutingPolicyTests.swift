import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// The routing-policy contract: task ids, shipped defaults, sanitising, the
/// tolerant decoder, and the versioned on-disk document with its migrations.
final class RoutingPolicyTests: XCTestCase {
    // MARK: - Task ids

    func testTaskTokensAreTolerantOfCaseSeparatorsAndTheQuickEditSpelling() {
        XCTAssertEqual(RoutingTaskID(token: "Implementation"), .implementation)
        XCTAssertEqual(RoutingTaskID(token: "  DEBUGGING "), .debugging)
        XCTAssertEqual(RoutingTaskID(token: "quick-edit"), .quickEdit)
        XCTAssertEqual(RoutingTaskID(token: "quick_edit"), .quickEdit)
        XCTAssertEqual(RoutingTaskID(token: "Quick Edit"), .quickEdit)
        XCTAssertEqual(RoutingTaskID(token: "quickedit"), .quickEdit)
        XCTAssertEqual(RoutingTaskID(token: "release-notes")?.rawValue, "release-notes")
    }

    func testMalformedTaskTokensAreRejected() {
        let tooLong = String(repeating: "a", count: RoutingTaskID.maximumLength + 1)
        for bad in ["", "   ", "-lead", "trail-", "double--dash", "ünï", "a/b", "a.b", "x@y", "../etc", tooLong] {
            XCTAssertNil(RoutingTaskID(token: bad), bad)
        }
        XCTAssertNotNil(RoutingTaskID(token: String(repeating: "a", count: RoutingTaskID.maximumLength)))
    }

    func testBuiltInTasksAreTheSevenDocumentedOnesInOrder() {
        XCTAssertEqual(
            RoutingTaskID.builtIn.map(\.rawValue),
            ["planning", "implementation", "debugging", "review", "research", "quick-edit", "custom"]
        )
        XCTAssertTrue(RoutingTaskID.builtIn.allSatisfy(\.isBuiltIn))
        XCTAssertNil(RoutingTaskID(token: "release-notes")?.builtInName)
        XCTAssertEqual(RoutingTaskID.quickEdit.builtInName, "Quick edit")
    }

    func testTaskOrderingListsBuiltInsFirstThenCustomAlphabetically() {
        let ids = ["zeta", "alpha", "review", "planning"].compactMap { RoutingTaskID(token: $0) }
        XCTAssertEqual(ids.sorted().map(\.rawValue), ["planning", "review", "alpha", "zeta"])
    }

    func testTaskIDEncodesAsAPlainStringAndRejectsAnInvalidOne() throws {
        let data = try JSONEncoder().encode([RoutingTaskID.quickEdit])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"quick-edit\"]")
        XCTAssertThrowsError(try JSONDecoder().decode([RoutingTaskID].self, from: Data("[\"Not Valid!\"]".utf8)))
    }

    // MARK: - Safe defaults

    func testEveryBuiltInTaskShipsASaneDefaultPolicy() {
        XCTAssertEqual(RoutingPolicyDefaults.all.map(\.task), RoutingTaskID.builtIn)

        for policy in RoutingPolicyDefaults.all {
            XCTAssertEqual(policy, policy.sanitized(), "\(policy.task) default is not already sanitised")
            XCTAssertEqual(policy.name, policy.task.builtInName)
            XCTAssertTrue((1...100).contains(policy.minimumRemainingPercent), "\(policy.task)")
            XCTAssertTrue(policy.providerPreference.isEmpty, "\(policy.task) must not ship a vendor opinion")
            XCTAssertEqual(policy.providerScope, .anyProvider)
            XCTAssertEqual(policy.accountSelection, .automatic)
            XCTAssertTrue(policy.modelAliases.isEmpty)
            XCTAssertEqual(policy.maximumFallbacks, 2)
            XCTAssertEqual(policy.fallbackOrder, .score)
        }
    }

    func testDefaultsDemandMoreHeadroomForLongerWork() {
        func minimum(_ task: RoutingTaskID) -> Int { RoutingPolicyDefaults.policy(for: task).minimumRemainingPercent }

        XCTAssertGreaterThan(minimum(.planning), minimum(.implementation))
        XCTAssertGreaterThan(minimum(.implementation), minimum(.debugging))
        XCTAssertGreaterThan(minimum(.debugging), minimum(.quickEdit))
        XCTAssertEqual(RoutingPolicyDefaults.policy(for: .planning).modelTier, .premium)
        XCTAssertEqual(RoutingPolicyDefaults.policy(for: .quickEdit).modelTier, .economy)
    }

    func testEstimatedQuotaIsEligibleOnlyForTheLowStakesTasks() {
        let allowed = RoutingPolicyDefaults.all.filter(\.allowsEstimatedQuota).map(\.task)
        XCTAssertEqual(Set(allowed), [.research, .quickEdit])
    }

    func testAnUnknownCustomTaskGetsTheNeutralPolicyNamedAfterItself() {
        let id = RoutingTaskID(token: "release-notes")!
        let policy = RoutingPolicyDefaults.policy(for: id)
        XCTAssertEqual(policy.task, id)
        XCTAssertEqual(policy.name, "release-notes")
        XCTAssertEqual(policy.modelTier, .standard)
        XCTAssertEqual(policy.minimumRemainingPercent, RoutingPolicyDefaults.policy(for: .custom).minimumRemainingPercent)
    }

    // MARK: - Sanitising

    func testSanitisingClampsRangesAndDropsDuplicatesKeepingTheFirst() {
        let account = RoutingAccountRef(provider: .claudeCode, accountID: RoutingFixtures.uuid(1))
        let policy = RoutingPolicy(
            task: .review,
            name: "  Review   the\nthing ",
            providerPreference: [.codexCli, .claudeCode, .codexCli],
            accounts: [account, account],
            modelAliases: [.codexCli: "ok.alias-1", .claudeCode: "no/slash", .grok: "a@b", .cursor: ""],
            minimumRemainingPercent: 250,
            maximumDeficitPercent: -4,
            maximumFallbacks: 99
        )

        XCTAssertEqual(policy.name, "Review the thing")
        XCTAssertEqual(policy.providerPreference, [.codexCli, .claudeCode])
        XCTAssertEqual(policy.accounts, [account])
        XCTAssertEqual(policy.minimumRemainingPercent, 100)
        XCTAssertEqual(policy.maximumDeficitPercent, 0)
        XCTAssertEqual(policy.maximumFallbacks, RoutingPolicy.maximumFallbackCount)
        XCTAssertEqual(policy.modelAliases, [.codexCli: "ok.alias-1"])
    }

    func testTaskNamesThatLookLikeEmailsOrPathsFallBackToTheTaskName() {
        for unsafe in ["me@example.com", "/Users/me/notes", "~/notes", "a\\b", "   "] {
            XCTAssertEqual(RoutingPolicy(task: .review, name: unsafe).name, "Review", unsafe)
        }
        let custom = RoutingTaskID(token: "release-notes")!
        XCTAssertEqual(RoutingPolicy(task: custom, name: "me@example.com").name, "release-notes")
    }

    func testNamesAreLengthCapped() {
        let policy = RoutingPolicy(task: .custom, name: String(repeating: "x", count: 200))
        XCTAssertEqual(policy.name.count, RoutingPolicy.maximumNameLength)
    }

    // MARK: - Codable

    func testAPolicyRoundTripsIncludingAnExplicitlyClearedDeficitLimit() throws {
        var policy = RoutingPolicyDefaults.policy(for: .implementation)
        policy.providerPreference = [.codexCli, .claudeCode]
        policy.providerScope = .preferredOnly
        policy.accountSelection = .preferred
        policy.accounts = [RoutingAccountRef(provider: .codexCli, accountID: RoutingFixtures.uuid(4))]
        policy.modelTier = .premium
        policy.modelAliases = [.codexCli: "gpt-test-1"]
        policy.costPreference = .cost
        policy.fallbackOrder = .policyPreference
        policy.maximumFallbacks = 1
        policy.maximumDeficitPercent = nil // the default is 25: nil is a deliberate "no limit"
        policy.allowsEstimatedQuota = true

        let decoded = try JSONDecoder().decode(RoutingPolicy.self, from: JSONEncoder().encode(policy))

        XCTAssertEqual(decoded, policy)
        XCTAssertNil(decoded.maximumDeficitPercent)
    }

    func testMalformedNonNullDeficitRetainsTaskDefaultWhileNullClearsIt() throws {
        let expected = RoutingPolicyDefaults.policy(for: .implementation).maximumDeficitPercent
        XCTAssertNotNil(expected)
        for value in ["\"unreadable\"", "25.5", "true", "{}", "[]"] {
            let body = #"{"task":"implementation","maximumDeficitPercent":\#(value)}"#
            let decoded = try JSONDecoder().decode(RoutingPolicy.self, from: Data(body.utf8))
            XCTAssertEqual(decoded.maximumDeficitPercent, expected, value)
        }
        let cleared = try JSONDecoder().decode(
            RoutingPolicy.self,
            from: Data(#"{"task":"implementation","maximumDeficitPercent":null}"#
                .utf8)
        )
        XCTAssertNil(cleared.maximumDeficitPercent)
        let valid = try JSONDecoder().decode(
            RoutingPolicy.self,
            from: Data(#"{"task":"implementation","maximumDeficitPercent":17}"#.utf8)
        )
        XCTAssertEqual(valid.maximumDeficitPercent, 17)
    }

    func testMissingFieldsTakeThatTasksDefaults() throws {
        let decoded = try JSONDecoder().decode(RoutingPolicy.self, from: Data(#"{"task":"planning"}"#.utf8))
        XCTAssertEqual(decoded, RoutingPolicyDefaults.policy(for: .planning))
    }

    func testAnUnreadableFieldDegradesAloneAndTheRestOfThePolicySurvives() throws {
        let json = """
        {
          "task": "review",
          "providerPreference": ["Codex CLI", "Some Future Provider", "Claude Code"],
          "costPreference": "someFutureMode",
          "modelTier": "premium",
          "minimumRemainingPercent": "lots",
          "accounts": [
            {"provider": "Codex CLI", "accountID": "not-a-uuid"},
            {"provider": "Claude Code", "accountID": "01000000-0000-0000-0000-000000000001"}
          ],
          "modelAliases": {"Codex CLI": "gpt-test-1", "Unknown Provider": "x"}
        }
        """
        let defaults = RoutingPolicyDefaults.policy(for: .review)
        let decoded = try JSONDecoder().decode(RoutingPolicy.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.providerPreference, [.codexCli, .claudeCode])
        XCTAssertEqual(decoded.costPreference, defaults.costPreference)
        XCTAssertEqual(decoded.modelTier, .premium)
        XCTAssertEqual(decoded.minimumRemainingPercent, defaults.minimumRemainingPercent)
        XCTAssertEqual(decoded.accounts.map(\.provider), [.claudeCode])
        XCTAssertEqual(decoded.modelAliases, [.codexCli: "gpt-test-1"])
    }

    func testAPolicyWithoutAValidTaskCannotBeDecoded() {
        XCTAssertThrowsError(try JSONDecoder().decode(RoutingPolicy.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(RoutingPolicy.self, from: Data(#"{"task":"No Good!"}"#.utf8)))
    }

    func testDecodedValuesAreSanitised() throws {
        let json = #"{"task":"review","minimumRemainingPercent":500,"maximumFallbacks":-3}"#
        let decoded = try JSONDecoder().decode(RoutingPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.minimumRemainingPercent, 100)
        XCTAssertEqual(decoded.maximumFallbacks, 0)
    }

    // MARK: - Document and catalog

    func testStoringAPolicyIdenticalToItsDefaultStoresNothing() {
        var document = RoutingPolicyDocument.empty
        var edited = RoutingPolicyDefaults.policy(for: .review)
        edited.minimumRemainingPercent = 55
        document = document.setting(edited)
        XCTAssertEqual(document.policies.map(\.task), [.review])

        document = document.setting(RoutingPolicyDefaults.policy(for: .review))
        XCTAssertEqual(document, .empty)
    }

    func testResettingRestoresABuiltInAndDeletesACustomTask() {
        let custom = RoutingTaskID(token: "release-notes")!
        var edited = RoutingPolicyDefaults.policy(for: .planning)
        edited.modelTier = .economy
        let document = RoutingPolicyDocument.empty
            .setting(edited)
            .setting(RoutingPolicy(task: custom, name: "Release notes"))

        let catalog = RoutingPolicyCatalog(document: document)
        XCTAssertEqual(catalog.policy(for: .planning)?.modelTier, .economy)
        XCTAssertNotNil(catalog.policy(for: custom))

        let reset = RoutingPolicyCatalog(document: document.resetting(.planning).resetting(custom))
        XCTAssertEqual(reset.policy(for: .planning), RoutingPolicyDefaults.policy(for: .planning))
        XCTAssertNil(reset.policy(for: custom))
    }

    func testTheCatalogListsBuiltInsInOrderThenCustomTasksAndKnowsWhatIsCustomised() {
        let custom = RoutingTaskID(token: "release-notes")!
        var edited = RoutingPolicyDefaults.policy(for: .debugging)
        edited.minimumRemainingPercent = 60
        let catalog = RoutingPolicyCatalog(
            document: RoutingPolicyDocument(policies: [
                RoutingPolicy(task: custom, name: "Release notes"),
                edited,
            ])
        )

        XCTAssertEqual(catalog.taskIDs, RoutingTaskID.builtIn + [custom])
        XCTAssertEqual(catalog.policy(for: .debugging)?.minimumRemainingPercent, 60)
        XCTAssertTrue(catalog.isCustomized(.debugging))
        XCTAssertFalse(catalog.isCustomized(.planning))
        XCTAssertEqual(RoutingPolicyCatalog().taskIDs, RoutingTaskID.builtIn)
        XCTAssertNil(RoutingPolicyCatalog().policy(for: custom))
    }

    func testTheDocumentKeepsOnePolicyPerTaskInStableOrder() {
        let document = RoutingPolicyDocument(policies: [
            RoutingPolicy(task: .review, name: "Review", minimumRemainingPercent: 30),
            RoutingPolicy(task: .planning, name: "Planning", minimumRemainingPercent: 30),
            RoutingPolicy(task: .review, name: "Review", minimumRemainingPercent: 99),
        ])
        XCTAssertEqual(document.policies.map(\.task), [.planning, .review])
        XCTAssertEqual(document.policy(for: .review)?.minimumRemainingPercent, 30)
    }

    // MARK: - Versioned file format and migration

    func testDocumentRoundTripsThroughTheStandardCodec() throws {
        var edited = RoutingPolicyDefaults.policy(for: .research)
        edited.providerPreference = [.grok]
        let document = RoutingPolicyDocument(policies: [
            edited,
            RoutingPolicy(task: RoutingTaskID(token: "triage")!, name: "Triage"),
        ])
        let codec = RoutingPolicyDocumentCodec.standard

        let data = try XCTUnwrap(codec.encode(document))
        XCTAssertEqual(codec.decode(data), .document(document, migratedFrom: nil))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, RoutingPolicyDocumentCodec.currentSchemaVersion)
        XCTAssertEqual(RoutingPolicyDocumentCodec.currentSchemaVersion, 1)
    }

    func testANewerSchemaIsReportedAndNeverInterpreted() {
        let future = Data(#"{"schemaVersion":2,"policies":[{"task":"review"}]}"#.utf8)
        XCTAssertEqual(RoutingPolicyDocumentCodec.standard.decode(future), .unsupportedVersion(2))
    }

    func testUnreadableDocumentsAreReportedAsSuch() {
        let codec = RoutingPolicyDocumentCodec.standard
        for bad in ["", "not json", "[]", #"{"policies":[]}"#, #"{"schemaVersion":0,"policies":[]}"#,
                    #"{"schemaVersion":"1","policies":[]}"#, #"{"schemaVersion":1}"#] {
            XCTAssertEqual(codec.decode(Data(bad.utf8)), .unreadable, bad)
        }
    }

    func testOneBadPolicyEntryDoesNotTakeTheUsersOthersWithIt() throws {
        let json = """
        {"schemaVersion":1,"policies":[
          {"task":"review","minimumRemainingPercent":44},
          {"name":"no task id"},
          {"task":"Bad Id!"},
          {"task":"planning","minimumRemainingPercent":55}
        ]}
        """
        guard case let .document(document, migratedFrom) = RoutingPolicyDocumentCodec.standard.decode(Data(json.utf8)) else {
            return XCTFail("expected a document")
        }
        XCTAssertNil(migratedFrom)
        XCTAssertEqual(document.policies.map(\.task), [.planning, .review])
        XCTAssertEqual(document.policy(for: .review)?.minimumRemainingPercent, 44)
    }

    /// The migration seam, exercised with injected steps because version 1 is
    /// the first shipped schema: v1 -> v2 renames a field, v2 -> v3 adds one.
    func testOlderDocumentsAreWalkedForwardOneRegisteredStepAtATime() throws {
        let renameStep = RoutingPolicyMigration(from: 1) { object in
            var object = object
            let policies = (object["policies"] as? [[String: Any]] ?? []).map { policy -> [String: Any] in
                var policy = policy
                policy["minimumRemainingPercent"] = policy.removeValue(forKey: "floorPercent")
                return policy
            }
            object["policies"] = policies
            return object
        }
        let tierStep = RoutingPolicyMigration(from: 2) { object in
            var object = object
            let policies = (object["policies"] as? [[String: Any]] ?? []).map { policy -> [String: Any] in
                var policy = policy
                policy["modelTier"] = "premium"
                return policy
            }
            object["policies"] = policies
            return object
        }
        let codec = RoutingPolicyDocumentCodec(currentVersion: 3, migrations: [renameStep, tierStep])
        let legacy = Data(#"{"schemaVersion":1,"policies":[{"task":"review","floorPercent":41}]}"#.utf8)

        guard case let .document(document, migratedFrom) = codec.decode(legacy) else {
            return XCTFail("expected a migrated document")
        }
        XCTAssertEqual(migratedFrom, 1)
        XCTAssertEqual(document.policy(for: .review)?.minimumRemainingPercent, 41)
        XCTAssertEqual(document.policy(for: .review)?.modelTier, .premium)

        let midway = Data(#"{"schemaVersion":2,"policies":[{"task":"review","minimumRemainingPercent":12}]}"#.utf8)
        guard case let .document(fromTwo, twoFrom) = codec.decode(midway) else {
            return XCTFail("expected a migrated document")
        }
        XCTAssertEqual(twoFrom, 2)
        XCTAssertEqual(fromTwo.policy(for: .review)?.minimumRemainingPercent, 12)

        let written = try XCTUnwrap(codec.encode(document))
        XCTAssertEqual(codec.decode(written), .document(document, migratedFrom: nil))
    }

    func testAnOlderDocumentWithNoRegisteredStepIsUnreadableNotGuessedAt() {
        let codec = RoutingPolicyDocumentCodec(currentVersion: 2, migrations: [])
        let legacy = Data(#"{"schemaVersion":1,"policies":[]}"#.utf8)
        XCTAssertEqual(codec.decode(legacy), .unreadable)
    }
}
