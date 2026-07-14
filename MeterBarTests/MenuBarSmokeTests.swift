import AppKit
import Foundation
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

/// App-level end-to-end smoke suite (issue #18). Exercises the real
/// `UsageDataManager` through the same seams the production singletons use, so a
/// broken menu-bar data path, a broken widget data bridge, or missing settings
/// persistence fails here even though the narrower unit tests still pass.
///
/// This is the deterministic, credential-free equivalent of an XCUITest launch
/// flow: full XCUITest UI automation needs a signed .app + a UITest target run
/// via `xcodebuild`, which the SwiftPM CI (and credential-less daily run) cannot
/// drive. See `.agents/docs/TESTING.md` for the manual UI/widget QA checklist.
@MainActor
final class MenuBarSmokeTests: XCTestCase {

    /// Controllable single-account provider (Codex / Cursor stand-in).
    private final class StubUsageProvider: SimpleUsageProviding, CodexUsageProviding {
        var hasAccess: Bool
        private let metrics: UsageMetrics
        init(hasAccess: Bool, metrics: UsageMetrics) {
            self.hasAccess = hasAccess
            self.metrics = metrics
        }
        func fetchUsageMetrics() async throws -> UsageMetrics { metrics }
        func canAccess(account: CodexAccount) async -> Bool { hasAccess }
        func fetchUsageMetrics(account: CodexAccount) async throws -> UsageMetrics { metrics }
    }

    private var tempDirectory: URL!
    private var suiteName: String!
    private var savedRefreshInterval: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MenuBarSmokeTests-\(UUID().uuidString)"
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        // The refresh interval persists through @AppStorage (UserDefaults.standard);
        // snapshot it so the smoke test can assert on the real key and restore after.
        savedRefreshInterval = UserDefaults.standard.object(forKey: StorageKeys.refreshInterval)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        if let savedRefreshInterval {
            UserDefaults.standard.set(savedRefreshInterval, forKey: StorageKeys.refreshInterval)
        } else {
            UserDefaults.standard.removeObject(forKey: StorageKeys.refreshInterval)
        }
        // Drop the UUID-scoped suites so repeated runs don't accumulate
        // plist-backed preference domains (same convention as the other
        // suite-based tests, e.g. NotificationPreferencesStoreTests).
        if let suiteName {
            for suite in [suiteName, "\(suiteName)-vis"] {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
        }
        tempDirectory = nil
        suiteName = nil
        savedRefreshInterval = nil
        try super.tearDownWithError()
    }

    func testLaunchInjectFixturesChangeIntervalPersistsAndUpdatesSharedData() async throws {
        // 1. "Launch": construct the real manager wired to fixture providers and
        //    isolated stores (Claude Code hidden — no CLI creds in CI).
        let codex = StubUsageProvider(hasAccess: true, metrics: MetricsFixtures.codexCli())
        let cursor = StubUsageProvider(hasAccess: true, metrics: MetricsFixtures.cursor())
        let cacheDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let visibilityDefaults = try XCTUnwrap(UserDefaults(suiteName: "\(suiteName!)-vis"))
        let visibility = ProviderVisibilityStore(userDefaults: visibilityDefaults)
        visibility.set(.claudeCode, isEnabled: false)
        let sharedStore = SharedDataStore(directoryOverride: tempDirectory) {}

        let manager = UsageDataManager(
            codexCliService: codex,
            cursorService: cursor,
            providerVisibilityStore: visibility,
            sharedStore: sharedStore,
            cacheDefaults: cacheDefaults,
            schedulesAutoRefresh: false
        )

        // 2. "Inject fixture usage data": a refresh pulls from the fixture providers.
        await manager.refreshAll()
        XCTAssertEqual(Set(manager.metrics.keys), [.codexCli, .cursor])
        XCTAssertFalse(manager.isLoading)

        // 3. Shared-data update: the widget bridge file reflects the new snapshot.
        sharedStore.flushPendingWrites()
        let bridged = sharedStore.loadMetrics()
        XCTAssertEqual(Set(bridged.keys), [.codexCli, .cursor])
        XCTAssertEqual(bridged[.codexCli]?.weeklyLimit?.used, MetricsFixtures.codexCli().weeklyLimit?.used)

        // The persisted cache blob is also written (survives relaunch).
        XCTAssertNotNil(cacheDefaults.data(forKey: StorageKeys.cachedUsageMetrics))

        // 4. "Change refresh interval" through the same setter Settings uses, then
        //    assert it persisted under the app's storage key.
        manager.refreshInterval = .fiveMinutes
        XCTAssertEqual(manager.refreshInterval, .fiveMinutes)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: StorageKeys.refreshInterval),
                       RefreshInterval.fiveMinutes.rawValue)

        // Back to manual: invalidates the auto-refresh timer and persists 0.
        manager.refreshInterval = .manual
        XCTAssertEqual(UserDefaults.standard.integer(forKey: StorageKeys.refreshInterval),
                       RefreshInterval.manual.rawValue)
    }

    func testRelaunchRestoresCachedMetricsFromSharedDefaults() async throws {
        // Simulate a previous run having cached metrics, then a fresh "launch":
        // the manager must render them immediately (no blank UI before first fetch).
        let cacheDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let seeded = MetricsFixtures.allProviders()
        cacheDefaults.set(MetricsCodec.encode(seeded), forKey: StorageKeys.cachedUsageMetrics)

        let visibility = ProviderVisibilityStore(
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: "\(suiteName!)-vis"))
        )
        let manager = UsageDataManager(
            codexCliService: StubUsageProvider(hasAccess: false, metrics: MetricsFixtures.codexCli()),
            cursorService: StubUsageProvider(hasAccess: false, metrics: MetricsFixtures.cursor()),
            providerVisibilityStore: visibility,
            sharedStore: SharedDataStore(directoryOverride: tempDirectory) {},
            cacheDefaults: cacheDefaults,
            schedulesAutoRefresh: false
        )

        XCTAssertEqual(Set(manager.metrics.keys), Set(seeded.keys))
    }

    // MARK: - Popover provider card affordances

    /// The tappable popover card hosts with its hover button style, disclosure
    /// chevron, and context menu attached — a broken affordance (e.g. a bad
    /// command wiring or a layout regression from the chevron) fails to build here.
    func testPopoverProviderCardHostsWithContextMenu() throws {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: MetricsFixtures.codexCli(),
            emptyDetail: ""
        )
        let card = PopoverProviderStatusCard(snapshot: snapshot) {}

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 390, height: 160)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    /// Firing the popover card's context-menu commands runs each side effect for
    /// the card's own service — the "Refresh this provider" / "Hide provider"
    /// items must act on the provider the menu was opened from.
    func testPopoverProviderCardCommandsFireForItsService() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: nil,
            emptyDetail: ""
        )

        var refreshed: [ServiceType] = []
        var hidden: [ServiceType] = []
        let commands = ProviderCardCommands.make(
            snapshot: snapshot,
            refresh: { refreshed.append($0) },
            openStatusPage: { _ in },
            hide: { hidden.append($0) },
            openInDashboard: {}
        )

        commands.first { $0.id == .refresh }?.action()
        commands.first { $0.id == .hide }?.action()

        XCTAssertEqual(refreshed, [.codexCli])
        XCTAssertEqual(hidden, [.codexCli])
    }

    /// With no providers enabled the popover overview renders its empty state,
    /// whose sole CTA — "Open Settings" — adopted the `.glass` button style.
    /// SwiftPM CI can't hit-test AppKit controls, so this guards that the
    /// glass-styled CTA still compiles and lays out with a non-zero size inside
    /// the real panel. A removed button or an invalid `.glass` style regresses
    /// here; the `openSettings` action itself is a standard SwiftUI environment
    /// action and needs no separate coverage.
    func testEmptyStateOpenSettingsGlassCTARenders() {
        let panel = PopoverOverviewPanel(
            snapshots: [],
            openDashboard: {},
            openStatusDetail: {},
            openProviderOverview: { _ in }
        )
        let hostingView = NSHostingView(rootView: panel)
        hostingView.frame = NSRect(x: 0, y: 0, width: 390, height: 320)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
}
