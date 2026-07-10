import Combine
import Foundation

/// The UI-facing seam over the shared Session Wake automation core.
///
/// Issue #98 delivers the control surfaces (Settings, account selection, status,
/// notifications) *over* the native coordinator built in #95–#97. To keep this
/// branch self-contained and to keep automation logic out of views, the surfaces
/// bind to this small observable seam rather than to the discovery / quota-gate /
/// runner types directly. The real coordinator (once #95–#97 land) subclasses
/// this and drives `status` / `lastRun` / `eligibility` from its state machine;
/// until then the honest `StubSessionWakeCoordinator` is installed as `shared`.
///
/// Views must not implement discovery, quota, or resume logic — they only read
/// this state and call the intent methods.
class SessionWakeCoordinator: ObservableObject {
    /// The process-wide coordinator. Replaced with the native implementation
    /// when the #95–#97 coordinator lands; the stub is a no-op placeholder that
    /// performs no subprocess or filesystem work.
    static let shared: SessionWakeCoordinator = StubSessionWakeCoordinator()

    /// The current presentation status. One shared binding drives both the
    /// Settings pane and the menu-bar popover.
    @Published private(set) var status: SessionWakeStatus = .off
    /// The most recent completed run's counts, or nil if none this session.
    @Published private(set) var lastRun: SessionWakeRunSummary?
    /// The latest read-only Preview result, or nil before the first Preview.
    @Published private(set) var eligibility: SessionWakeEligibility?

    // MARK: Intents (overridden by concrete coordinators)

    /// Runs a read-only dry run and publishes `eligibility`. Permitted even when
    /// the feature is disabled; must never spawn a process or mutate the disk.
    func preview() async {}

    /// One-shot resume, only when fresh quota proves availability. Does not
    /// require the watcher to be armed.
    func resumeNow() async {}

    /// Begins the watch loop for the selected account.
    func armWatcher() {}

    /// Cancels any in-progress watch within one poll interval and stops polling.
    func stopWatcher() {}

    // MARK: State plumbing for subclasses

    /// Reflects persisted settings intent into the idle-family status when no
    /// run is in flight. Concrete coordinators call this from their settings
    /// observation so "Off / Idle / Armed" always match the store.
    func reflectSettings(featureEnabled: Bool, watcherArmed: Bool) {
        // Never stomp on an in-flight run; only reconcile the resting states.
        switch status {
        case .off, .idle, .armed:
            apply(status: Self.restingStatus(featureEnabled: featureEnabled, watcherArmed: watcherArmed))
        case .scanning, .waiting, .quotaUnknown, .running, .stopping, .completed, .needsAttention:
            break
        }
    }

    /// The resting status implied purely by persisted intent.
    static func restingStatus(featureEnabled: Bool, watcherArmed: Bool) -> SessionWakeStatus {
        guard featureEnabled else { return .off }
        return watcherArmed ? .armed : .idle
    }

    func apply(status: SessionWakeStatus) {
        self.status = status
    }

    func apply(eligibility: SessionWakeEligibility?) {
        self.eligibility = eligibility
    }

    func apply(lastRun: SessionWakeRunSummary?) {
        self.lastRun = lastRun
    }
}

// MARK: - StubSessionWakeCoordinator

/// The interim production coordinator installed until the native automation core
/// (#95–#97) is wired in. It is deliberately inert: it reflects settings intent
/// into the resting status and reports that discovery is not yet available,
/// rather than fabricating session counts. Because it performs no subprocess or
/// filesystem work, the dry-run "no mutation" invariant holds trivially.
final class StubSessionWakeCoordinator: SessionWakeCoordinator {
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()
        // Keep the resting status (Off / Idle / Armed) honest by mirroring the
        // persisted intent. The real coordinator (#95–#97) will additionally
        // drive the active states from its watcher state machine.
        let settings = SessionWakeSettingsStore.shared
        reflectSettings(
            featureEnabled: settings.isFeatureEnabled,
            watcherArmed: settings.isWatcherArmed
        )
        settings.$isFeatureEnabled
            .combineLatest(settings.$isWatcherArmed)
            .sink { [weak self] featureEnabled, watcherArmed in
                self?.reflectSettings(featureEnabled: featureEnabled, watcherArmed: watcherArmed)
            }
            .store(in: &cancellables)
    }

    override func preview() async {
        apply(eligibility: SessionWakeEligibility(
            eligibleCount: 0,
            note: "Session Wake discovery is not available in this build yet."
        ))
    }
}

// MARK: - PreviewSessionWakeCoordinator

/// A fully-injectable coordinator for SwiftUI previews and view tests. Lets a
/// caller pin any status / eligibility / last-run so every state can be rendered
/// and asserted without the automation core.
final class PreviewSessionWakeCoordinator: SessionWakeCoordinator {
    init(
        status: SessionWakeStatus = .idle,
        eligibility: SessionWakeEligibility? = nil,
        lastRun: SessionWakeRunSummary? = nil
    ) {
        super.init()
        apply(status: status)
        apply(eligibility: eligibility)
        apply(lastRun: lastRun)
    }

    /// Test/preview hook to drive an arbitrary status transition.
    func set(status: SessionWakeStatus) {
        apply(status: status)
    }
}
