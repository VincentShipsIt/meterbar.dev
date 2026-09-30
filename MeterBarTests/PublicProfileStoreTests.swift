import Combine
import XCTest
@testable import MeterBar

@MainActor
final class PublicProfileStoreTests: XCTestCase {
    private final class FakeKeys: PublicProfileKeyStoring {
        var stored: [String: String] = [:]
        var failsSaves = false

        func key(for slug: String) -> String? { stored[slug] }
        func save(_ key: String, for slug: String) -> Bool {
            guard !failsSaves else { return false }
            stored[slug] = key
            return true
        }
        func remove(for slug: String) { stored[slug] = nil }
    }

    private final class FakeService: PublicProfileServing, @unchecked Sendable {
        enum Call: Equatable {
            case publish(slug: String, key: String)
            case delete(slug: String, key: String)
        }

        var calls: [Call] = []
        var publishResult: PublicProfileResult = .ok
        var deleteResult: PublicProfileResult = .ok
        var onDelete: (() -> Void)?
        /// When set, `publish` suspends here until the test releases it.
        var publishGate: CheckedContinuation<Void, Never>?
        var gatesNextPublish = false
        var onPublishStarted: (() -> Void)?

        func publish(_ document: PublicProfileDocument, slug: String, publishKey: String) async -> PublicProfileResult {
            calls.append(.publish(slug: slug, key: publishKey))
            if gatesNextPublish {
                gatesNextPublish = false
                await withCheckedContinuation { publishGate = $0; onPublishStarted?() }
            }
            return publishResult
        }

        func delete(slug: String, publishKey: String) async -> PublicProfileResult {
            calls.append(.delete(slug: slug, key: publishKey))
            onDelete?()
            return deleteResult
        }

        var publishCount: Int { calls.filter { if case .publish = $0 { true } else { false } }.count }
        var deleteCount: Int { calls.filter { if case .delete = $0 { true } else { false } }.count }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var keys: FakeKeys!
    private var service: FakeService!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let base = URL(string: "https://meterbar.test")!

    override func setUp() {
        super.setUp()
        suiteName = "PublicProfileStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keys = FakeKeys()
        service = FakeService()
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(isDemoMode: @escaping () -> Bool = { false }) -> PublicProfileStore {
        PublicProfileStore(
            userDefaults: defaults,
            keys: keys,
            service: service,
            baseURL: base,
            now: { [unowned self] in clock },
            isDemoMode: isDemoMode
        )
    }

    private func document(percent: Int = 10) -> PublicProfileDocument {
        PublicProfileDocument(
            schema: 1,
            updatedAt: clock,
            providers: [
                .init(
                    provider: "Claude Code",
                    name: "Claude Code",
                    plan: nil,
                    windows: [.init(label: "Weekly", usedPercent: percent, resetsAt: nil, pace: nil)]
                ),
            ],
            receipt: nil
        )
    }

    private var emptyDocument: PublicProfileDocument {
        PublicProfileDocument(schema: 1, updatedAt: clock, providers: [], receipt: nil)
    }

    // MARK: - Off means silent

    func testFreshStoreIsOffAndSendsNothing() async {
        let store = makeStore()

        await store.sync(document: document())
        await store.resumePendingDeletions()

        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.status, .off)
        XCTAssertNil(store.profileURL)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertTrue(keys.stored.isEmpty, "no identity is minted before opt-in")
    }

    // MARK: - Opt in

    func testOptInMintsAnIdentityAndPublishesOnce() async throws {
        let store = makeStore()

        await store.setEnabled(true, document: document())

        let slug = try XCTUnwrap(store.slug)
        XCTAssertTrue(PublicProfileIdentity.isValidSlug(slug))
        XCTAssertEqual(service.calls, [.publish(slug: slug, key: try XCTUnwrap(keys.stored[slug]))])
        XCTAssertEqual(store.profileURL?.absoluteString, "https://meterbar.test/u/\(slug)")
        XCTAssertEqual(store.status, .live)
        XCTAssertEqual(store.lastPublishedAt, clock)
    }

    func testOptInWithNothingToPublishWaitsWithoutTouchingTheNetwork() async {
        let store = makeStore()

        await store.setEnabled(true, document: emptyDocument)

        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.status, .waiting)
        XCTAssertTrue(service.calls.isEmpty)
    }

    /// An unstorable key is a profile that could never be deleted.
    func testKeychainFailureRefusesToPublishAnything() async {
        keys.failsSaves = true
        let store = makeStore()

        await store.setEnabled(true, document: document())

        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.profileURL)
        XCTAssertTrue(service.calls.isEmpty)
        guard case .error = store.status else { return XCTFail("expected an error, got \(store.status)") }
    }

    func testEnabledStateAndSlugSurviveRelaunch() async throws {
        let first = makeStore()
        await first.setEnabled(true, document: document())

        let second = makeStore()

        XCTAssertTrue(second.isEnabled)
        XCTAssertEqual(second.slug, first.slug)
        XCTAssertEqual(second.profileURL, first.profileURL)
    }

    // MARK: - Live sync

    func testSyncIsThrottledAndOnlySpendsWritesOnChangeOrHeartbeat() async {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        XCTAssertEqual(service.publishCount, 1)

        clock.addTimeInterval(60)
        await store.sync(document: document(percent: 50))
        XCTAssertEqual(service.publishCount, 1, "inside the 15 minute floor")

        clock.addTimeInterval(15 * 60)
        await store.sync(document: document(percent: 50))
        XCTAssertEqual(service.publishCount, 2, "changed content once the floor passes")

        clock.addTimeInterval(20 * 60)
        await store.sync(document: document(percent: 50))
        XCTAssertEqual(service.publishCount, 2, "unchanged content waits for the heartbeat")

        clock.addTimeInterval(45 * 60)
        await store.sync(document: document(percent: 50))
        XCTAssertEqual(service.publishCount, 3, "the hourly heartbeat")
    }

    func testRefusedKeySurfacesAnErrorInsteadOfRetryingForever() async {
        service.publishResult = .rejected
        let store = makeStore()

        await store.setEnabled(true, document: document())

        guard case .error = store.status else { return XCTFail("expected an error, got \(store.status)") }
        XCTAssertNil(store.lastPublishedAt)
    }

    func testFailedPublishIsRetriedOnlyAfterTheFloor() async {
        service.publishResult = .failed("Could not reach meterbar.dev.")
        let store = makeStore()
        await store.setEnabled(true, document: document())
        XCTAssertEqual(store.status, .error("Could not reach meterbar.dev."))

        clock.addTimeInterval(60)
        await store.sync(document: document())
        XCTAssertEqual(service.publishCount, 1)

        service.publishResult = .ok
        clock.addTimeInterval(15 * 60)
        await store.sync(document: document())
        XCTAssertEqual(service.publishCount, 2)
        XCTAssertEqual(store.status, .live)
    }

    // MARK: - Unpublish

    func testTurningOffDeletesTheServerCopyAndKeepsTheLinkStable() async throws {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        let slug = try XCTUnwrap(store.slug)
        let key = try XCTUnwrap(keys.stored[slug])

        await store.setEnabled(false, document: document())

        XCTAssertEqual(service.calls.last, .delete(slug: slug, key: key))
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.status, .off)
        XCTAssertNil(store.profileURL, "an unpublished link is not offered")
        XCTAssertTrue(store.pendingDeletions.isEmpty)
        XCTAssertNil(store.lastPublishedAt)

        await store.setEnabled(true, document: document())
        XCTAssertEqual(store.slug, slug, "turning it back on reuses the same URL")
    }

    /// The server copy must not outlive the opt-in just because the network was
    /// down at the moment of toggling.
    func testFailedDeleteIsRememberedAcrossRelaunchAndRetried() async throws {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        let slug = try XCTUnwrap(store.slug)

        service.deleteResult = .failed("Could not reach meterbar.dev.")
        await store.setEnabled(false, document: document())
        XCTAssertEqual(store.pendingDeletions, [slug])
        XCTAssertFalse(store.isEnabled, "the toggle is off locally whatever the server says")

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.pendingDeletions, [slug])

        service.deleteResult = .ok
        await relaunched.resumePendingDeletions()
        XCTAssertTrue(relaunched.pendingDeletions.isEmpty)
        XCTAssertEqual(service.deleteCount, 2)
    }

    func testPendingDeleteIsNotRetriedOnEveryRefresh() async {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        service.deleteResult = .failed("offline")
        await store.setEnabled(false, document: document())
        let attempts = service.deleteCount

        await store.resumePendingDeletions()
        XCTAssertEqual(service.deleteCount, attempts, "inside the retry interval")

        clock.addTimeInterval(PublicProfileStore.flushRetryInterval + 1)
        await store.resumePendingDeletions()
        XCTAssertEqual(service.deleteCount, attempts + 1)
    }

    func testReenablingCancelsAPendingDeleteBecauseThePutSupersedesIt() async throws {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        service.deleteResult = .failed("offline")
        await store.setEnabled(false, document: document())
        XCTAssertEqual(store.pendingDeletions.count, 1)

        await store.setEnabled(true, document: document())

        XCTAssertTrue(store.pendingDeletions.isEmpty)
        XCTAssertEqual(store.status, .live)
    }

    func testRefusedDeleteKeepsItsCredentialsUntilTheServerConfirmsDeletion() async throws {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        let oldSlug = try XCTUnwrap(store.slug)
        let oldKey = try XCTUnwrap(keys.key(for: oldSlug))
        service.deleteResult = .rejected
        await store.reset(document: document())
        XCTAssertEqual(store.pendingDeletions, [oldSlug])
        XCTAssertEqual(keys.key(for: oldSlug), oldKey)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.pendingDeletions, [oldSlug])
        service.deleteResult = .ok
        await relaunched.resumePendingDeletions()
        XCTAssertTrue(relaunched.pendingDeletions.isEmpty)
        XCTAssertNil(keys.key(for: oldSlug))
    }

    func testAPendingDeleteWithNoKeyLeftIsDroppedNotRetriedForever() async throws {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        service.deleteResult = .failed("offline")
        await store.setEnabled(false, document: document())
        keys.stored.removeAll()

        clock.addTimeInterval(PublicProfileStore.flushRetryInterval + 1)
        await store.resumePendingDeletions()

        XCTAssertTrue(store.pendingDeletions.isEmpty)
    }

    // MARK: - Reset

    func testResetDeletesTheOldProfileAndPublishesUnderAnUnrelatedSlug() async throws {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        let oldSlug = try XCTUnwrap(store.slug)
        let oldKey = try XCTUnwrap(keys.stored[oldSlug])

        await store.reset(document: document())

        let newSlug = try XCTUnwrap(store.slug)
        XCTAssertNotEqual(newSlug, oldSlug)
        XCTAssertNotEqual(keys.stored[newSlug], oldKey)
        XCTAssertNil(keys.stored[oldSlug], "the old key is discarded once its profile is deleted")
        XCTAssertTrue(service.calls.contains(.delete(slug: oldSlug, key: oldKey)))
        XCTAssertEqual(service.calls.last, .publish(slug: newSlug, key: try XCTUnwrap(keys.stored[newSlug])))
        XCTAssertEqual(store.profileURL?.absoluteString, "https://meterbar.test/u/\(newSlug)")
        XCTAssertTrue(store.pendingDeletions.isEmpty)
    }

    func testResetWhileOffDeletesButPublishesNothing() async throws {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        await store.setEnabled(false, document: document())
        let publishes = service.publishCount

        await store.reset(document: document())

        XCTAssertEqual(service.publishCount, publishes)
        XCTAssertFalse(store.isEnabled)
    }

    func testResetKeepsTheOldDeleteOwedWhenTheServerIsUnreachable() async throws {
        let store = makeStore()
        await store.setEnabled(true, document: document())
        let oldSlug = try XCTUnwrap(store.slug)
        service.deleteResult = .failed("offline")

        await store.reset(document: document())

        XCTAssertEqual(store.pendingDeletions, [oldSlug])
        XCTAssertNotNil(keys.stored[oldSlug], "the key stays until the delete is confirmed")
        XCTAssertNotEqual(store.slug, oldSlug)
    }

    // MARK: - Coordinator privacy retries

    func testCoordinatorRefreshRetriesFailedUnpublishWhileDisabledWithoutReadingUsage() async throws {
        let store = makeStore()
        let refreshes = PassthroughSubject<Void, Never>()
        let coordinator = PublicProfileCoordinator(
            store: store,
            refreshEvents: refreshes.eraseToAnyPublisher(),
            document: { XCTFail("disabled retries must not read live usage"); return self.emptyDocument }
        )
        coordinator.start()
        await store.setEnabled(true, document: document())
        let slug = try XCTUnwrap(store.slug)
        service.deleteResult = .failed("offline")
        await store.setEnabled(false, document: document())
        XCTAssertNotNil(keys.key(for: slug), "keep deletion credentials while offline")

        clock.addTimeInterval(PublicProfileStore.flushRetryInterval + 1)
        let retried = expectation(description: "off-state coordinator delete retry")
        service.deleteResult = .ok
        service.onDelete = { retried.fulfill() }
        refreshes.send(())
        await fulfillment(of: [retried], timeout: 5)
        await store.resumePendingDeletions()

        XCTAssertEqual(service.deleteCount, 2)
        XCTAssertEqual(service.publishCount, 1)
        XCTAssertTrue(store.pendingDeletions.isEmpty)
        XCTAssertFalse(store.isEnabled)
    }

    func testCoordinatorRetriesAfterAFailedLaunchDeletionWhileOff() async throws {
        let first = makeStore()
        await first.setEnabled(true, document: document())
        let slug = try XCTUnwrap(first.slug)
        service.deleteResult = .failed("offline")
        await first.setEnabled(false, document: document())

        let relaunched = makeStore()
        let refreshes = PassthroughSubject<Void, Never>()
        let coordinator = PublicProfileCoordinator(
            store: relaunched,
            refreshEvents: refreshes.eraseToAnyPublisher(),
            document: { XCTFail("off-state relaunch must not read usage"); return self.emptyDocument }
        )
        let failedLaunch = expectation(description: "failed launch retry")
        service.onDelete = { failedLaunch.fulfill() }
        coordinator.start()
        await fulfillment(of: [failedLaunch], timeout: 5)
        await relaunched.resumePendingDeletions()
        XCTAssertEqual(relaunched.pendingDeletions, [slug])
        XCTAssertNotNil(keys.key(for: slug))

        let recovered = expectation(description: "later refresh recovers deletion")
        service.onDelete = { recovered.fulfill() }
        service.deleteResult = .ok
        clock.addTimeInterval(PublicProfileStore.flushRetryInterval + 1)
        refreshes.send(())
        await fulfillment(of: [recovered], timeout: 5)
        await relaunched.resumePendingDeletions()

        XCTAssertTrue(relaunched.pendingDeletions.isEmpty)
        XCTAssertEqual(service.deleteCount, 3)
        XCTAssertEqual(service.publishCount, 1)
        XCTAssertFalse(relaunched.isEnabled)
    }

    // MARK: - Demo publication boundary

    func testDemoEnableAndResetDoNotPublishEnableOrMintAnIdentity() async {
        let store = makeStore(isDemoMode: { true })
        await store.setEnabled(true, document: document())
        await store.reset(document: document())
        await store.sync(document: document())

        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.status, .off)
        XCTAssertNil(store.slug)
        XCTAssertNil(store.lastPublishedAt)
        XCTAssertNil(store.profileURL)
        XCTAssertTrue(keys.stored.isEmpty)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: StorageKeys.publicProfileEnabled))
        XCTAssertNil(defaults.string(forKey: StorageKeys.publicProfileSlug))
    }

    func testDemoBlocksForcedAndBackgroundPublicationWithoutChangingExistingIdentity() async throws {
        var demo = false
        let store = makeStore(isDemoMode: { demo })
        await store.setEnabled(true, document: document())
        let slug = try XCTUnwrap(store.slug)
        let originalKeys = keys.stored
        let publishedAt = store.lastPublishedAt
        demo = true
        clock.addTimeInterval(3601)

        await store.setEnabled(true, document: document(percent: 90))
        await store.reset(document: document(percent: 90))
        await store.sync(document: document(percent: 90))

        XCTAssertEqual(service.publishCount, 1)
        XCTAssertEqual(service.deleteCount, 0)
        XCTAssertEqual(store.slug, slug)
        XCTAssertEqual(keys.stored, originalKeys)
        XCTAssertEqual(store.lastPublishedAt, publishedAt)
        XCTAssertEqual(defaults.string(forKey: StorageKeys.publicProfileSlug), slug)
    }

    func testDemoUnpublishAndCoordinatorRetriesStillDelete() async throws {
        var demo = false
        let store = makeStore(isDemoMode: { demo })
        let refreshes = PassthroughSubject<Void, Never>()
        let coordinator = PublicProfileCoordinator(
            store: store,
            refreshEvents: refreshes.eraseToAnyPublisher(),
            document: { XCTFail("demo must not construct a publication"); return self.emptyDocument }
        )
        coordinator.start()
        await store.setEnabled(true, document: document())
        let slug = try XCTUnwrap(store.slug)
        demo = true
        service.deleteResult = .failed("offline")
        await store.setEnabled(false, document: document())
        XCTAssertEqual(store.pendingDeletions, [slug])

        let deleted = expectation(description: "demo permits privacy retry")
        service.deleteResult = .ok
        service.onDelete = { deleted.fulfill() }
        clock.addTimeInterval(PublicProfileStore.flushRetryInterval + 1)
        refreshes.send(())
        await fulfillment(of: [deleted], timeout: 5)
        await store.resumePendingDeletions()

        XCTAssertEqual(service.publishCount, 1)
        XCTAssertEqual(service.deleteCount, 2)
        XCTAssertTrue(store.pendingDeletions.isEmpty)
        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.lastPublishedAt)
    }

    func testQueuedDemoEnableAndResetAreBlockedWhenTheSerialOperationRuns() async throws {
        var demo = false
        service.gatesNextPublish = true
        let entered = expectation(description: "initial publish in flight")
        service.onPublishStarted = { entered.fulfill() }
        let store = makeStore(isDemoMode: { demo })
        let enabling = Task { await store.setEnabled(true, document: self.document()) }
        await fulfillment(of: [entered], timeout: 5)
        let slug = try XCTUnwrap(store.slug)
        let originalKeys = keys.stored
        let reset = Task { await store.reset(document: self.document()) }
        let reenabling = Task { await store.setEnabled(true, document: self.document()) }
        await Task.yield()
        demo = true
        service.publishGate?.resume()
        await enabling.value
        await reset.value
        await reenabling.value

        XCTAssertEqual(service.publishCount, 1)
        XCTAssertEqual(service.deleteCount, 0)
        XCTAssertEqual(store.slug, slug)
        XCTAssertEqual(keys.stored, originalKeys)
    }

    // MARK: - Ordering

    /// A toggle-off must not be overtaken by a publish already in flight: the
    /// delete has to land after it, or the profile outlives the opt-in.
    func testToggleOffQueuedBehindAnInFlightPublishDeletesAfterIt() async throws {
        service.gatesNextPublish = true
        let started = expectation(description: "publish started")
        service.onPublishStarted = { started.fulfill() }
        let store = makeStore()

        let enabling = Task { await store.setEnabled(true, document: self.document()) }
        await fulfillment(of: [started], timeout: 5)
        let disabling = Task { await store.setEnabled(false, document: self.document()) }
        await Task.yield()
        service.publishGate?.resume()
        await enabling.value
        await disabling.value

        XCTAssertEqual(service.calls.map { if case .publish = $0 { "publish" } else { "delete" } }, ["publish", "delete"])
        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(store.pendingDeletions.isEmpty)
    }
}
