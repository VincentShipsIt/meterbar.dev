import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

@MainActor
final class UsageRefreshConfigurationStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteNames: [String] = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageRefreshConfigurationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for suiteName in suiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        try? FileManager.default.removeItem(at: tempDirectory)
        suiteNames = []
        tempDirectory = nil
    }

    func testStoresPublishOneCompleteNonSecretRefreshConfiguration() throws {
        let visibilityDefaults = try makeDefaults()
        let claudeDefaults = try makeDefaults()
        let codexDefaults = try makeDefaults()

        let visibility = ProviderVisibilityStore(
            userDefaults: visibilityDefaults,
            refreshConfigurationDirectory: tempDirectory
        )
        visibility.set(.cursor, isEnabled: false)

        let claude = ClaudeCodeAccountStore(
            userDefaults: claudeDefaults,
            refreshConfigurationDirectory: tempDirectory
        )
        claude.addAccount(name: "Work", configDirectory: "/tmp/claude-work")
        claude.setEnabled(false, for: ClaudeCodeAccount.defaultID)

        let codex = CodexAccountStore(
            userDefaults: codexDefaults,
            refreshConfigurationDirectory: tempDirectory
        )
        codex.addAccount(name: "Personal", homeDirectory: "/tmp/codex-personal")
        codex.setEnabled(false, for: CodexAccount.defaultID)

        let snapshot = try XCTUnwrap(
            UsageRefreshConfigurationStore.load(directory: tempDirectory)
        )
        XCTAssertTrue(snapshot.hiddenServices.contains(.cursor))
        XCTAssertEqual(snapshot.claudeAccounts.count, 2)
        XCTAssertEqual(snapshot.claudeAccounts.first(where: \.isDefault)?.isEnabled, false)
        XCTAssertEqual(snapshot.claudeAccounts.first(where: { !$0.isDefault })?.configDirectory, "/tmp/claude-work")
        XCTAssertEqual(snapshot.codexAccounts.count, 2)
        XCTAssertEqual(snapshot.codexAccounts.first(where: \.isDefault)?.isEnabled, false)
        XCTAssertEqual(snapshot.codexAccounts.first(where: { !$0.isDefault })?.homeDirectory, "/tmp/codex-personal")

        // The CLI projections preserve exact enabled state and account order
        // without reading or writing a process-local preferences domain.
        let projectedVisibility = ProviderVisibilityStore(hiddenServices: snapshot.hiddenServices)
        let projectedClaude = ClaudeCodeAccountStore(accounts: snapshot.claudeAccounts)
        let projectedCodex = CodexAccountStore(accounts: snapshot.codexAccounts)
        XCTAssertFalse(projectedVisibility.isEnabled(.cursor))
        XCTAssertEqual(projectedClaude.enabledAccounts.map(\.name), ["Work"])
        XCTAssertEqual(projectedCodex.enabledAccounts.map(\.name), ["Personal"])
    }

    func testLoadFailsClosedWhenAnyProjectionIsMissing() {
        UsageRefreshConfigurationStore.saveVisibility([.grok], directory: tempDirectory)
        UsageRefreshConfigurationStore.saveClaudeAccounts(
            [.defaultAccount],
            directory: tempDirectory
        )

        XCTAssertNil(UsageRefreshConfigurationStore.load(directory: tempDirectory))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "UsageRefreshConfigurationStoreTests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }
}
