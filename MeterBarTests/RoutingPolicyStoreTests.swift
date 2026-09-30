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

    func testAnExistingPolicyLocationThatCannotBeReadReturnsANoticeWithoutChangingIt() throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let marker = fileURL.appendingPathComponent("preserved")
        let original = Data("user policy bytes".utf8)
        try original.write(to: marker)
        let loaded = RoutingPolicyStore.load(directory: directory, persistMigration: true)
        XCTAssertEqual(loaded.catalog, RoutingPolicyCatalog())
        XCTAssertEqual(loaded.notice?.code, .policyUnreadable)
        XCTAssertFalse(loaded.notice?.message.contains(directory.path) == true)
        XCTAssertEqual(try Data(contentsOf: marker), original)
    }

    func testPolicyReadPermissionFailurePreservesOriginalBytes() throws {
        let original = Data(#"{"schemaVersion":1,"policies":[]}"#.utf8)
        try original.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path) }
        let loaded = RoutingPolicyStore.load(directory: directory, persistMigration: true)
        XCTAssertEqual(loaded.notice?.code, .policyUnreadable)
        XCTAssertFalse(loaded.notice?.message.contains(directory.path) == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testSaveWithoutAContainerFailsInsteadOfClaimingSuccess() {
        XCTAssertThrowsError(try RoutingPolicyStore.save(.empty, directory: nil)) {
            XCTAssertEqual($0 as? RoutingPolicyStore.PersistenceError, .containerUnavailable)
        }
    }

    func testSaveToAnUnwritableLocationPreservesThePreviousFile() throws {
        let old = Data("original bytes".utf8)
        try old.write(to: fileURL)
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blocked)
        XCTAssertThrowsError(try RoutingPolicyStore.save(.empty, directory: blocked))
        XCTAssertEqual(try Data(contentsOf: fileURL), old)
    }

    func testSaveEncodingFailurePreservesExistingBytesAndReportsTheStage() throws {
        let original = Data("original bytes".utf8)
        try original.write(to: fileURL)
        XCTAssertThrowsError(try RoutingPolicyStore.save(.empty, directory: directory, encoder: { _ in nil })) {
            XCTAssertEqual($0 as? RoutingPolicyStore.PersistenceError, .encodingFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testSaveWriteFailureReportsPathFreeErrorAndPreservesExistingBytes() throws {
        let original = Data("original bytes".utf8)
        try original.write(to: fileURL)
        XCTAssertThrowsError(try RoutingPolicyStore.save(.empty, directory: directory, writer: { _, url in
            throw SecureFileWriterError.write(code: 28, path: url.path)
        })) {
            XCTAssertEqual(
                $0 as? RoutingPolicyStore.PersistenceError,
                .writeFailed(reason: "write failed: No space left on device")
            )
            XCTAssertFalse($0.localizedDescription.contains(self.directory.path))
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testFailedMigrationWriteKeepsUpgradedCatalogAndOriginalBytesWithANotice() throws {
        let original = Data(#"{"schemaVersion":1,"policies":[{"task":"review","minimumRemainingPercent":41}]}"#.utf8)
        try original.write(to: fileURL)
        let codec = RoutingPolicyDocumentCodec(currentVersion: 2, migrations: [RoutingPolicyMigration(from: 1) { $0 }])
        let loaded = RoutingPolicyStore.load(
            directory: directory, codec: codec, persistMigration: true,
            writer: { _, url in throw SecureFileWriterError.write(code: 28, path: url.path) }
        )
        XCTAssertEqual(loaded.catalog.policy(for: .review)?.minimumRemainingPercent, 41)
        XCTAssertEqual(loaded.notice?.code, .policyMigrationFailed)
        XCTAssertFalse(loaded.notice?.message.contains(directory.path) == true)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(RoutingPolicyStore.load(directory: directory, codec: codec).catalog, loaded.catalog)
    }

    func testADanglingPolicySymlinkIsUnreadableRatherThanAbsent() throws {
        let missing = directory.appendingPathComponent("missing-policy")
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: missing)
        XCTAssertEqual(RoutingPolicyStore.load(directory: directory).notice?.code, .policyUnreadable)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path), missing.path)
    }

    func testSavingNeverOverwritesAFutureSchema() throws {
        let future = Data(#"{"schemaVersion":99,"policies":[]}"#.utf8)
        try future.write(to: fileURL)
        XCTAssertThrowsError(try RoutingPolicyStore.save(.empty, directory: directory)) {
            XCTAssertEqual($0 as? RoutingPolicyStore.PersistenceError, .unsupportedVersion(99))
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), future)
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
