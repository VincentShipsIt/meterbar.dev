import AppKit
import Combine
import Foundation

/// Publishes which app the user is currently working in, for merged-mode focus
/// following (issue #341).
///
/// Privacy posture, deliberately narrow: the monitor reads the frontmost app's
/// **bundle identifier and nothing else**. No polling, no accessibility APIs, no
/// window titles, no document paths, no inspection of what runs inside a
/// terminal. It also stays completely dormant until the user opts in — the
/// workspace subscription is created when the preference turns on and torn down
/// when it turns off, so "off" means "not observing", not "observing quietly".
@MainActor
final class FrontmostAppMonitor: ObservableObject {
    // MARK: Lifecycle

    init(
        preferences: MenuBarDisplayPreferencesStore = .shared,
        interval: TimeInterval = MenuBarFocusDebouncer.defaultInterval
    ) {
        self.preferences = preferences
        debouncer = MenuBarFocusDebouncer(interval: interval)
    }

    // MARK: Internal

    static let shared = FrontmostAppMonitor()

    /// Bundle identifier of the settled frontmost app, or nil while the feature
    /// is off (or the frontmost app has none).
    @Published private(set) var bundleIdentifier: String?

    /// Starts watching the opt-in preference. Safe to call more than once.
    func activate() {
        guard !isActivated else { return }
        isActivated = true

        preferences.$followsFocusedApp
            .removeDuplicates()
            .sink { [weak self] enabled in
                // `@Published` fires on `willSet`; hop once so the store is
                // committed before the monitor reacts to it.
                Task { @MainActor in
                    self?.setFollowing(enabled)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Private

    private let preferences: MenuBarDisplayPreferencesStore

    /// Coalesces a cmd-tab sweep into the app the user actually landed on.
    private var debouncer: MenuBarFocusDebouncer

    private var cancellables = Set<AnyCancellable>()

    /// Held separately from `cancellables` so following can be switched off
    /// without also dropping the preference subscription that turns it back on.
    private var workspaceObservation: AnyCancellable?

    /// Supersedes an in-flight debounce window instead of cancelling a timer —
    /// same idiom as the presenter's update generation.
    private var flushGeneration = 0

    private var isActivated = false
    private var isFollowing = false

    private func setFollowing(_ enabled: Bool) {
        guard enabled != isFollowing else { return }
        isFollowing = enabled
        if enabled {
            startObserving()
        } else {
            stopObserving()
        }
    }

    private func startObserving() {
        // Seed from whatever is already frontmost, without a debounce window:
        // there is no burst to sit out at the moment the user opts in.
        debouncer = MenuBarFocusDebouncer(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        bundleIdentifier = debouncer.bundleID

        workspaceObservation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                // Bundle identifier only — the rest of `NSRunningApplication` is
                // never read.
                let bundleID = application?.bundleIdentifier
                Task { @MainActor in
                    self?.record(bundleID)
                }
            }
    }

    private func stopObserving() {
        workspaceObservation = nil
        flushGeneration += 1
        debouncer = MenuBarFocusDebouncer(interval: debouncer.interval)
        bundleIdentifier = nil
    }

    private func record(_ bundleID: String?, at now: Date = Date()) {
        // Bumping first cancels any pending flush, including the case where the
        // debouncer reports "nothing to do" because the user came straight back
        // to the app already on screen.
        flushGeneration += 1
        guard let deadline = debouncer.record(bundleID, at: now) else { return }

        let generation = flushGeneration
        let delay = max(0, deadline.timeIntervalSince(now))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, generation == self.flushGeneration else { return }
            self.commit()
        }
    }

    private func commit() {
        guard debouncer.flush() else { return }
        bundleIdentifier = debouncer.bundleID
    }
}
