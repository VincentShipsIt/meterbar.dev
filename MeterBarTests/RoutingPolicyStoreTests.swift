import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Persistence of the routing-policy file: it survives a relaunch, upgrades
/// explicitly, and never lets a bad or newer file cost the user their bytes.
final class RoutingPolicyStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-policy-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent(RoutingPolicyStore.fileName) }

    func testWithNoFileTheShippedDefaultsApplyWithoutANotice() {
        let loaded = RoutingPolicyStore.load(directory: directory)
        XCTAssertEqual(loaded.catalog, RoutingPolicyCatalog())
        XCTAssertNil(loaded.notice)
    }

    func testWithNoContainerTheShippedDefaultsApply() {
        XCTAssertEqual(RoutingPolicyStore.load(directory: nil).catalog, RoutingPolicyCatalog())
    }

    func testACustomPolicyIsRestoredAcrossRelaunch() throws {
        let custom = RoutingTaskID(token: "release-notes")!
        var edited = RoutingPolicyDefaults.policy(for: .implementation)
        edited.providerPreference = [.codexCli, .claudeCode]
        edited.minimumRemainingPercent = 35
        let saved = RoutingPolicyDocument.empty
            .setting(edited)
            .setting(RoutingPolicy(task: custom, name: "Release notes", modelTier: .economy))

        try RoutingPolicyStore.save(saved, directory: directory)

        // "Relaunch": nothing in memory, only the file.
        let loaded = RoutingPolicyStore.load(directory: directory)
        XCTAssertNil(loaded.notice)
        XCTAssertEqual(loaded.catalog.document, saved)
        XCTAssertEqual(loaded.catalog.policy(for: .implementation)?.providerPreference, [.codexCli, .claudeCode])
        XCTAssertEqual(loaded.catalog.policy(for: custom)?.modelTier, .economy)
    }

    func testThePolicyFileIsOwnerOnly() throws {
        try RoutingPolicyStore.save(RoutingPolicyDocument.empty.setting(RoutingPolicy(task: .custom, name: "X", minimumRemainingPercent: 50)), directory: directory)
        let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testAnOlderFileIsMigratedOnLoadAndOnlyRewrittenWhenAsked() throws {
        let step = RoutingPolicyMigration(from: 1) { object in
            var object = object
            object["policies"] = (object["policies"] as? [[String: Any]] ?? []).map { policy -> [String: Any] in
                var policy = policy
                policy["minimumRemainingPercent"] = policy.removeValue(forKey: "floorPercent")
                return policy
            }
            return object
        }
        let codec = RoutingPolicyDocumentCodec(currentVersion: 2, migrations: [step])
        let legacy = Data(#"{"schemaVersion":1,"policies":[{"task":"review","floorPercent":41}]}"#.utf8)
        try legacy.write(to: fileURL)

        let readOnly = RoutingPolicyStore.load(directory: directory, codec: codec)
        XCTAssertEqual(readOnly.catalog.policy(for: .review)?.minimumRemainingPercent, 41)
        XCTAssertEqual(try Data(contentsOf: fileURL), legacy, "a read-only load must not write")

        _ = RoutingPolicyStore.load(directory: directory, codec: codec, persistMigration: true)
        let rewritten = try Data(contentsOf: fileURL)
        XCTAssertNotEqual(rewritten, legacy)
        XCTAssertEqual(codec.decode(rewritten), .document(readOnly.catalog.document, migratedFrom: nil))
    }

    func testAFileFromANewerMeterBarFallsBackToDefaultsWithANoticeAndIsLeftUntouched() throws {
        let future = Data(#"{"schemaVersion":99,"policies":[{"task":"review","fancyNewField":true}]}"#.utf8)
        try future.write(to: fileURL)

        let loaded = RoutingPolicyStore.load(directory: directory, persistMigration: true)

        XCTAssertEqual(loaded.catalog, RoutingPolicyCatalog())
        XCTAssertEqual(loaded.notice?.code, .policyUnsupportedVersion)
        XCTAssertTrue(loaded.notice?.message.contains("99") == true)
        XCTAssertEqual(try Data(contentsOf: fileURL), future)
    }

    func testAnUnreadableFileFallsBackToDefaultsWithANoticeAndIsLeftUntouched() throws {
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: fileURL)

        let loaded = RoutingPolicyStore.load(directory: directory, persistMigration: true)

        XCTAssertEqual(loaded.catalog, RoutingPolicyCatalog())
        XCTAssertEqual(loaded.notice?.code, .policyUnreadable)
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage)
    }
}
