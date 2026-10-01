import Combine
import Foundation
import os

// MARK: - Collaborators

/// Where the per-slug publish key lives. The Keychain in production; an
/// in-memory fake in tests, because the real login keychain is unavailable on
/// CI and sealed off in unit-test runs (`RealKeychainTestGuard`).
protocol PublicProfileKeyStoring {
    func key(for slug: String) -> String?
    func save(_ key: String, for slug: String) -> Bool
    func remove(for slug: String)
}

nonisolated struct KeychainPublicProfileKeyStore: PublicProfileKeyStoring {
    var keychain: KeychainManager = .shared

    private func account(_ slug: String) -> String { "public-profile-key.\(slug)" }

    func key(for slug: String) -> String? { keychain.get(key: account(slug)) }
    func save(_ key: String, for slug: String) -> Bool { keychain.save(key: account(slug), value: key) }
    func remove(for slug: String) { keychain.delete(key: account(slug)) }
}

protocol PublicProfileServing: Sendable {
    func publish(_ document: PublicProfileDocument, slug: String, publishKey: String) async -> PublicProfileResult
    func delete(slug: String, publishKey: String) async -> PublicProfileResult
}

extension PublicProfileClient: PublicProfileServing {}

// MARK: - PublicProfileStore

/// Opt-in state and the publish / unpublish / reset flows for the anonymous
/// public profile (#594).
///
/// Nothing here touches the network while `isEnabled` is false and no delete is
/// pending. Every operation runs through one serial chain, so a toggle-off can
/// never be overtaken by a publish that was already in flight.
@MainActor
final class PublicProfileStore: ObservableObject {
    static let shared = PublicProfileStore()

    enum Status: Equatable {
        case off
        /// On, with nothing to publish yet (no provider has reported usage).
        case waiting
        case syncing
        case live
        case error(String)
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var slug: String?
    @Published private(set) var lastPublishedAt: Date?
    @Published private(set) var status: Status
    @Published private(set) var pendingDeletions: [String]
    @Published private(set) var isResetPending: Bool

    private let userDefaults: UserDefaults
    private let keys: PublicProfileKeyStoring
    private let service: PublicProfileServing
    private let baseURL: URL
    private let now: () -> Date
    private let isDemoMode: () -> Bool

    private var lastAttempt: Date?
    private var lastSuccess: Date?
    private var lastDocument: PublicProfileDocument?
    private var lastFlushAttempt: Date?
    private var chain: Task<Void, Never>?

    /// Failed deletes are retried at most this often on their own; a user
    /// action (toggle, reset) always tries at once.
    static let flushRetryInterval: TimeInterval = 5 * 60

    init(
        userDefaults: UserDefaults = .standard,
        keys: PublicProfileKeyStoring = KeychainPublicProfileKeyStore(),
        service: PublicProfileServing = PublicProfileClient(),
        baseURL: URL = PublicProfileEndpoint.baseURL,
        now: @escaping () -> Date = Date.init,
        isDemoMode: @escaping () -> Bool = { DemoMode.isActive }
    ) {
        self.userDefaults = userDefaults
        self.keys = keys
        self.service = service
        self.baseURL = baseURL
        self.now = now
        self.isDemoMode = isDemoMode
        let enabled = userDefaults.bool(forKey: StorageKeys.publicProfileEnabled)
        isEnabled = enabled
        slug = userDefaults.string(forKey: StorageKeys.publicProfileSlug)
            .flatMap { PublicProfileIdentity.isValidSlug($0) ? $0 : nil }
        lastPublishedAt = userDefaults.object(forKey: StorageKeys.publicProfileLastPublishedAt) as? Date
        pendingDeletions = (userDefaults.stringArray(forKey: StorageKeys.publicProfilePendingDeletions) ?? [])
            .filter(PublicProfileIdentity.isValidSlug)
        isResetPending = userDefaults.bool(forKey: StorageKeys.publicProfileResetPending)
        status = enabled ? .waiting : .off
    }

    /// The link to share, only while the profile is actually published.
    var profileURL: URL? {
        guard isEnabled, !isResetPending, let slug else { return nil }
        return PublicProfileIdentity.profileURL(slug: slug, base: baseURL)
    }

    /// Shared publication gate, also used before constructing a live document.
    /// Deletion deliberately does not depend on this gate.
    var canPublish: Bool { !isDemoMode() }

    // MARK: Intent

    func setEnabled(_ enabled: Bool, document: PublicProfileDocument) async {
        await serialized { [self] in
            if enabled {
                guard canPublish else { return }
                if isResetPending {
                    isEnabled = true
                    userDefaults.set(true, forKey: StorageKeys.publicProfileEnabled)
                    await completePendingReset(document: document, force: true)
                    return
                }
                guard ensureIdentity() else { return }
                pendingDeletions.removeAll { $0 == slug }
                persist()
                isEnabled = true
                userDefaults.set(true, forKey: StorageKeys.publicProfileEnabled)
                await publishNow(document, force: true)
            } else {
                isEnabled = false
                userDefaults.set(false, forKey: StorageKeys.publicProfileEnabled)
                status = .off
                lastPublishedAt = nil
                lastSuccess = nil
                lastDocument = nil
                userDefaults.removeObject(forKey: StorageKeys.publicProfileLastPublishedAt)
                if let slug, !pendingDeletions.contains(slug) { pendingDeletions.append(slug) }
                persist()
                if isResetPending {
                    await completePendingReset(document: nil, force: true)
                } else {
                    await flushPendingDeletions(force: true)
                }
            }
        }
    }

    /// Kills the old URL and mints a new one. The old profile is deleted from
    /// the server; the new slug and key share nothing with it.
    func reset(document: PublicProfileDocument) async {
        await serialized { [self] in
            guard canPublish else { return }
            isResetPending = true
            if let slug, !pendingDeletions.contains(slug) { pendingDeletions.append(slug) }
            persist()
            await completePendingReset(document: document, force: true)
        }
    }

    /// Called after each refresh by the coordinator.
    func sync(document: PublicProfileDocument) async {
        await serialized { [self] in
            if isResetPending {
                await completePendingReset(document: document, force: false)
                return
            }
            await flushPendingDeletions(force: false)
            guard isEnabled else { return }
            await publishNow(document, force: false)
        }
    }

    /// Called at launch so a delete that failed last session is not forgotten.
    func resumePendingDeletions() async {
        await serialized { [self] in
            if isResetPending {
                await completePendingReset(document: nil, force: false)
            } else {
                await flushPendingDeletions(force: false)
            }
        }
    }

    private func completePendingReset(document: PublicProfileDocument?, force: Bool) async {
        status = .syncing
        await flushPendingDeletions(force: force)
        guard pendingDeletions.isEmpty else {
            status = .error("The old profile could not be deleted. Reset is pending and will retry.")
            return
        }
        if let slug { keys.remove(for: slug) }
        slug = nil
        userDefaults.removeObject(forKey: StorageKeys.publicProfileSlug)
        lastPublishedAt = nil
        lastSuccess = nil
        lastAttempt = nil
        lastDocument = nil
        userDefaults.removeObject(forKey: StorageKeys.publicProfileLastPublishedAt)
        guard canPublish else {
            status = .error("Reset will finish when demo mode is off.")
            return
        }
        guard mintIdentity() != nil else { return }
        isResetPending = false
        persist()
        status = isEnabled ? .waiting : .off
        if isEnabled, let document { await publishNow(document, force: true) }
    }

    // MARK: Publishing

    private func publishNow(_ document: PublicProfileDocument, force: Bool) async {
        guard canPublish, isEnabled, !isResetPending, let slug, let key = keys.key(for: slug) else { return }
        guard !document.isEmpty else {
            status = .waiting
            return
        }
        let changed = !(lastDocument?.hasSameContent(as: document) ?? false)
        guard PublicProfilePublishPolicy.shouldPublish(
            now: now(),
            lastAttempt: lastAttempt,
            lastSuccess: lastSuccess,
            contentChanged: changed,
            force: force
        ) else { return }

        lastAttempt = now()
        status = .syncing
        var stamped = document
        stamped.updatedAt = now()
        switch await service.publish(stamped, slug: slug, publishKey: key) {
        case .ok:
            lastSuccess = now()
            lastDocument = stamped
            lastPublishedAt = stamped.updatedAt
            userDefaults.set(stamped.updatedAt, forKey: StorageKeys.publicProfileLastPublishedAt)
            status = .live
        case .rejected:
            status = .error("meterbar.dev refused this link. Reset it to get a new one.")
        case let .failed(message):
            status = .error(message)
        }
    }

    // MARK: Deleting

    /// Deletes every slug whose server copy is still owed a delete. A slug only
    /// leaves the list once the server confirms deletion (or no key remains).
    /// A refused key is not deletion confirmation; keep it for later retries.
    /// The server's seven-day expiry is the backstop.
    private func flushPendingDeletions(force: Bool) async {
        guard !pendingDeletions.isEmpty else { return }
        if !force, let lastFlushAttempt, now().timeIntervalSince(lastFlushAttempt) < Self.flushRetryInterval {
            return
        }
        lastFlushAttempt = now()
        for pending in pendingDeletions {
            guard let key = keys.key(for: pending) else {
                if isResetPending, pending == slug { continue }
                pendingDeletions.removeAll { $0 == pending }
                continue
            }
            switch await service.delete(slug: pending, publishKey: key) {
            case .ok:
                pendingDeletions.removeAll { $0 == pending }
                if pending != slug { keys.remove(for: pending) }
            case .rejected:
                break
            case let .failed(message):
                AppLog.app.error("Public profile delete failed: \(message, privacy: .public)")
            }
        }
        persist()
    }

    // MARK: Identity

    /// Makes sure there is a slug with a key in the Keychain. Refuses to
    /// publish under a key that could not be stored: an unstorable key is a
    /// profile that can never be deleted.
    private func ensureIdentity() -> Bool {
        if let slug, keys.key(for: slug) != nil { return true }
        return mintIdentity() != nil
    }

    private func mintIdentity() -> String? {
        let identity = PublicProfileIdentity.mint()
        guard keys.save(identity.publishKey, for: identity.slug) else {
            status = .error("MeterBar could not store the profile key in your Keychain, so nothing was published.")
            return nil
        }
        slug = identity.slug
        userDefaults.set(identity.slug, forKey: StorageKeys.publicProfileSlug)
        return identity.slug
    }

    private func persist() {
        userDefaults.set(pendingDeletions, forKey: StorageKeys.publicProfilePendingDeletions)
        userDefaults.set(isResetPending, forKey: StorageKeys.publicProfileResetPending)
        if let slug { userDefaults.set(slug, forKey: StorageKeys.publicProfileSlug) }
    }

    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        chain = task
        await task.value
    }
}
