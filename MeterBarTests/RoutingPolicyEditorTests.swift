import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// The Routing page's policy editor: a draft over the built-in tasks that is
/// only written on Save, can be cancelled or reset to the shipped defaults, and
/// refuses to save a policy that could never produce a route.
final class RoutingPolicyEditorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-policy-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL {
        directory.appendingPathComponent(RoutingPolicyStore.fileName)
    }

    private func editor(_ document: RoutingPolicyDocument = .empty) -> RoutingPolicyEditor {
        RoutingPolicyEditor(catalog: RoutingPolicyCatalog(document: document))
    }

    // MARK: Drafting

    func testStartsCleanWithOneDraftPerBuiltInTaskInOrder() {
        let editor = editor()

        XCTAssertEqual(editor.drafts.map(\.task), RoutingTaskID.builtIn)
        XCTAssertFalse(editor.isDirty)
        XCTAssertTrue(editor.problems.isEmpty)
        XCTAssertNil(editor.saveBlockedReason)
    }

    func testEditingMarksDirtyAndCancelRestoresTheLoadedPolicies() {
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }

        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(editor.draft(.planning)?.modelTier, .economy)

        editor.cancel()
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(editor.draft(.planning), RoutingPolicyDefaults.policy(for: .planning))
    }

    func testEditingClampsOutOfRangeNumbersWithoutLosingTheNoLimitChoice() {
        var editor = editor()
        editor.edit(.planning) {
            $0.minimumRemainingPercent = 250
            $0.maximumFallbacks = 99
            $0.maximumDeficitPercent = nil
        }

        let draft = editor.draft(.planning)
        XCTAssertEqual(draft?.minimumRemainingPercent, 100)
        XCTAssertEqual(draft?.maximumFallbacks, RoutingPolicy.maximumFallbackCount)
        XCTAssertNil(draft?.maximumDeficitPercent)
    }

    func testEditingAnUnknownTaskIsIgnored() throws {
        var editor = editor()
        let custom = try XCTUnwrap(RoutingTaskID(token: "release-notes"))
        editor.edit(custom) { $0.modelTier = .premium }
        XCTAssertFalse(editor.isDirty)
        XCTAssertNil(editor.draft(custom))
    }

    // MARK: Reset

    func testResetTaskRestoresOnlyThatTasksDefault() {
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }
        editor.edit(.review) { $0.minimumRemainingPercent = 77 }

        editor.reset(.planning)

        XCTAssertEqual(editor.draft(.planning), RoutingPolicyDefaults.policy(for: .planning))
        XCTAssertEqual(editor.draft(.review)?.minimumRemainingPercent, 77)
    }

    func testResetAllRestoresEveryBuiltInDefault() {
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }
        editor.edit(.review) { $0.minimumRemainingPercent = 77 }

        editor.resetAll()

        XCTAssertEqual(editor.drafts, RoutingPolicyDefaults.all)
    }

    func testResetIsADraftUntilSaved() throws {
        let customised = RoutingPolicyDocument.empty
            .setting(RoutingPolicyDefaults.policy(for: .planning).with { $0.modelTier = .economy })
        try RoutingPolicyStore.save(customised, directory: directory)
        var editor = editor(customised)

        editor.resetAll()

        XCTAssertTrue(editor.isDirty)
        XCTAssertNotNil(RoutingPolicyStore.load(directory: directory).catalog.document.policy(for: .planning))
    }

    // MARK: Blocking

    func testPreferredOnlyWithNoProvidersCannotSave() {
        var editor = editor()
        editor.edit(.planning) { $0.providerScope = .preferredOnly }

        XCTAssertEqual(editor.problems.map(\.task), [.planning])
        XCTAssertEqual(
            editor.saveBlockedReason,
            "Planning is limited to preferred providers, but none are chosen. Pick a provider or allow any."
        )
    }

    func testPreferredOnlyWithOnlyProvidersThatCannotRouteCannotSave() {
        var editor = editor()
        editor.edit(.review) {
            $0.providerScope = .preferredOnly
            $0.providerPreference = [.kimiCode]
        }

        XCTAssertNotNil(editor.saveBlockedReason)
    }

    func testPreferredOnlyWithARoutableProviderCanSave() {
        var editor = editor()
        editor.edit(.review) {
            $0.providerScope = .preferredOnly
            $0.providerPreference = [.kimiCode, .codexCli]
        }

        XCTAssertNil(editor.saveBlockedReason)
    }

    func testAnInvalidModelAliasBlocksSaveInsteadOfBeingDroppedSilently() {
        var editor = editor()
        editor.setAlias("../secret", for: .claudeCode, in: .implementation)

        XCTAssertEqual(
            editor.saveBlockedReason,
            "Implementation: the model name for Claude Code may only use letters, numbers and . _ : -"
        )
    }

    func testClearingAnAliasRemovesItAndUnblocks() {
        var editor = editor()
        editor.setAlias("bad alias", for: .claudeCode, in: .implementation)
        editor.setAlias("", for: .claudeCode, in: .implementation)

        XCTAssertNil(editor.saveBlockedReason)
        XCTAssertNil(editor.draft(.implementation)?.modelAliases[.claudeCode])
    }

    func testSaveRefusesWhileBlockedAndWritesNothing() {
        var editor = editor()
        editor.edit(.planning) { $0.providerScope = .preferredOnly }

        XCTAssertThrowsError(try editor.save(directory: directory)) {
            XCTAssertEqual($0 as? RoutingPolicyEditor.SaveError, .blocked(editor.saveBlockedReason ?? ""))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(editor.isDirty)
    }

    // MARK: Saving

    func testSavePersistsOnlyWhatDiffersFromTheDefaults() throws {
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }

        try editor.save(directory: directory)

        let loaded = RoutingPolicyStore.load(directory: directory)
        XCTAssertEqual(loaded.catalog.document.policies.map(\.task), [.planning])
        XCTAssertEqual(loaded.catalog.policy(for: .planning)?.modelTier, .economy)
        XCTAssertFalse(editor.isDirty)
    }

    func testEditingBackToTheDefaultRemovesTheStoredOverride() throws {
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }
        try editor.save(directory: directory)

        editor.edit(.planning) { $0.modelTier = .premium }
        try editor.save(directory: directory)

        XCTAssertTrue(RoutingPolicyStore.load(directory: directory).catalog.document.policies.isEmpty)
    }

    func testSaveAfterResetAllClearsTheBuiltInOverrides() throws {
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }
        editor.edit(.review) { $0.minimumRemainingPercent = 77 }
        try editor.save(directory: directory)

        editor.resetAll()
        try editor.save(directory: directory)

        XCTAssertTrue(RoutingPolicyStore.load(directory: directory).catalog.document.policies.isEmpty)
    }

    func testSavingKeepsACustomTaskTheEditorDoesNotShow() throws {
        let custom = try XCTUnwrap(RoutingTaskID(token: "release-notes"))
        let existing = RoutingPolicyDocument.empty.setting(RoutingPolicy(task: custom, name: "Release notes"))
        try RoutingPolicyStore.save(existing, directory: directory)
        var editor = editor(RoutingPolicyStore.load(directory: directory).catalog.document)

        editor.edit(.planning) { $0.modelTier = .economy }
        try editor.save(directory: directory)
        editor.resetAll()
        try editor.save(directory: directory)

        let document = RoutingPolicyStore.load(directory: directory).catalog.document
        XCTAssertNotNil(document.policy(for: custom))
        XCTAssertNil(document.policy(for: .planning))
    }

    func testANoLimitPacingChoiceSurvivesSaveAndReload() throws {
        var editor = editor()
        editor.edit(.planning) { $0.maximumDeficitPercent = nil }

        try editor.save(directory: directory)

        let reloaded = RoutingPolicyStore.load(directory: directory).catalog.policy(for: .planning)
        XCTAssertNil(reloaded?.maximumDeficitPercent)
        XCTAssertNotEqual(RoutingPolicyDefaults.policy(for: .planning).maximumDeficitPercent, nil)
    }

    func testUntouchedPolicyWithAMalformedCapKeepsTheDefaultCapOnSave() throws {
        let raw = #"{"schemaVersion":1,"policies":[{"task":"planning","modelTier":"economy","maximumDeficitPercent":"lots"}]}"#
        try Data(raw.utf8).write(to: fileURL)
        var editor = editor(RoutingPolicyStore.load(directory: directory).catalog.document)

        editor.edit(.planning) { $0.minimumRemainingPercent = 50 }
        try editor.save(directory: directory)

        let reloaded = RoutingPolicyStore.load(directory: directory).catalog.policy(for: .planning)
        XCTAssertEqual(reloaded?.maximumDeficitPercent, RoutingPolicyDefaults.policy(for: .planning).maximumDeficitPercent)
    }

    func testSaveNeverOverwritesAFileFromANewerMeterBar() throws {
        let future = Data(#"{"schemaVersion":99,"policies":[]}"#.utf8)
        try future.write(to: fileURL)
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }

        XCTAssertThrowsError(try editor.save(directory: directory)) {
            XCTAssertEqual(
                $0 as? RoutingPolicyEditor.SaveError,
                .storage(RoutingPolicyStore.PersistenceError.unsupportedVersion(99).localizedDescription)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), future)
        XCTAssertTrue(editor.isDirty)
    }

    func testSaveNeverOverwritesAnUnreadablePolicyLocation() throws {
        let missing = directory.appendingPathComponent("nowhere")
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: missing)
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }

        XCTAssertThrowsError(try editor.save(directory: directory))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path), missing.path)
        XCTAssertTrue(editor.isDirty)
    }

    func testAFailedWriteKeepsTheDraftAndReportsAReason() {
        var editor = editor()
        editor.edit(.planning) { $0.modelTier = .economy }
        struct Boom: Error {}

        XCTAssertThrowsError(try editor.save(directory: directory, writer: { _, _ in throw Boom() })) {
            guard case .storage = $0 as? RoutingPolicyEditor.SaveError else {
                return XCTFail("expected a storage error, got \($0)")
            }
        }
        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(editor.draft(.planning)?.modelTier, .economy)
    }

    // MARK: Accounts

    func testAccountOptionsComeFromCandidatesOfRoutableProvidersAndAreLabelled() {
        let id = UUID()
        let options = RoutingPolicyEditor.accountOptions(from: [
            RoutingCandidate(service: .claudeCode, accountID: id, accountName: "Work", metrics: nil),
            RoutingCandidate(service: .claudeCode, metrics: nil),
            RoutingCandidate(service: .kimiCode, accountID: UUID(), accountName: "Nope", metrics: nil),
        ])

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.ref, RoutingAccountRef(provider: .claudeCode, accountID: id))
        XCTAssertEqual(options.first?.label, "Work")
    }

    func testTogglingAnAccountAddsAndRemovesItWithoutDuplicates() {
        let ref = RoutingAccountRef(provider: .claudeCode, accountID: UUID())
        var editor = editor()

        editor.setAccount(ref, included: true, in: .implementation)
        editor.setAccount(ref, included: true, in: .implementation)
        XCTAssertEqual(editor.draft(.implementation)?.accounts, [ref])

        editor.setAccount(ref, included: false, in: .implementation)
        XCTAssertEqual(editor.draft(.implementation)?.accounts, [])
    }

    func testMovingAProviderReordersThePreference() {
        var editor = editor()
        editor.edit(.review) { $0.providerPreference = [.claudeCode, .codexCli, .xai] }

        editor.moveProvider(.xai, up: true, in: .review)
        XCTAssertEqual(editor.draft(.review)?.providerPreference, [.claudeCode, .xai, .codexCli])

        editor.moveProvider(.claudeCode, up: true, in: .review)
        XCTAssertEqual(editor.draft(.review)?.providerPreference, [.claudeCode, .xai, .codexCli])
    }

    func testTogglingAProviderAppendsAndRemovesItFromThePreference() {
        var editor = editor()

        editor.setPreferred(.codexCli, included: true, in: .review)
        editor.setPreferred(.claudeCode, included: true, in: .review)
        editor.setPreferred(.codexCli, included: false, in: .review)

        XCTAssertEqual(editor.draft(.review)?.providerPreference, [.claudeCode])
    }
}

private extension RoutingPolicy {
    func with(_ change: (inout RoutingPolicy) -> Void) -> RoutingPolicy {
        var copy = self
        change(&copy)
        return copy
    }
}
