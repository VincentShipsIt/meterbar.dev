import Combine
import Foundation
import MeterBarShared
import os
import UserNotifications

/// The shape `AccountNotificationPlanner` needs from a provider account.
/// `ClaudeCodeAccount`, `CodexAccount`, and `GrokAccount` were mapped by
/// byte-identical closures in `checkAndNotify()`; this collapses them to one.
nonisolated protocol NotificationAccountIdentity {
    var id: UUID { get }
    var name: String { get }
    var isEnabled: Bool { get }
}

extension ClaudeCodeAccount: NotificationAccountIdentity {}
extension CodexAccount: NotificationAccountIdentity {}
extension GrokAccount: NotificationAccountIdentity {}

extension AccountNotificationIdentity {
    nonisolated init(account: some NotificationAccountIdentity) {
        self.init(id: account.id, name: account.name, isEnabled: account.isEnabled)
    }
}

/// Owns quota-threshold and Session Wake banners, extracted from
/// `MeterBarApp.swift` (C1 split).
///
/// Pure move apart from the account mapping above: authorization, the trigger
/// fan-in, the threshold sweep, and the two notification posts keep their exact
/// bodies. It holds its own `cancellables` and launch task so `AppDelegate` no
/// longer has to.
final class UsageNotificationCoordinator {
    private let notificationPreferences = NotificationPreferencesStore.shared
    private let providerVisibilityStore = ProviderVisibilityStore.shared
    private var cancellables = Set<AnyCancellable>()

    /// The launch refresh, held so it can be cancelled instead of orphaned.
    private var monitorTask: Task<Void, Never>?

    /// Tracks which (service, limit, level) notifications have already fired so
    /// repeated trigger events don't re-alert while usage stays above a
    /// threshold. Keys are cleared when usage drops back below.
    private var notifiedLimitKeys: Set<String> = []

    /// Providers whose quotas are tracked as a single flat snapshot. Account-
    /// scoped providers fan out through `AccountNotificationPlanner` instead.
    static var flatNotificationServices: [ServiceType] {
        ServiceType.allCases.filter { !$0.hasAccountScopedNotifications }
    }

    func start() {
        // Check current authorization status first
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Request permission only if not yet determined
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error = error {
                        AppLog.app.error(
                            "Notification permission error: \(error.localizedDescription, privacy: .public)"
                        )
                    } else if !granted {
                        AppLog.app.info("Notification permission denied by user")
                    }
                }
            case .denied:
                AppLog.app.info("Notification permission previously denied; user can enable it in System Settings.")
            case .authorized, .provisional, .ephemeral:
                // Already authorized, no action needed
                break
            @unknown default:
                break
            }
        }

        // Subscribe before the first refresh so its committed snapshot is
        // observed rather than raced past.
        observeNotificationTriggers()

        // Kick off the launch refresh. Store the task so it can be cancelled,
        // and so it isn't an orphaned unstructured Task.
        monitorTask?.cancel()
        monitorTask = Task { @MainActor in
            await UsageDataManager.shared.refreshAll(trigger: .background)
        }
    }

    /// Re-evaluates limits whenever something a notification decision depends on
    /// actually changes, instead of on a five-minute timer.
    ///
    /// Deleting the poll is safe because elapsed time alone can never newly fire
    /// a notification: `NotificationDecider` reads `now` only for its staleness
    /// gate (`now - lastUpdated <= threshold`), so a tick can flip a provider
    /// from deliverable to stale but never the reverse. Everything that *can*
    /// newly fire one — a committed metric snapshot, an account being added or
    /// enabled, a provider being unhidden, a threshold being lowered — is
    /// published below. `checkAndNotify()` is idempotent through
    /// `notifiedLimitKeys`, so overlapping triggers cost nothing.
    private func observeNotificationTriggers() {
        let claudeAccountChanges = Publishers.Merge3(
            ClaudeCodeAccountStore.shared.$customAccounts.map { _ in () },
            ClaudeCodeAccountStore.shared.$defaultAccountConfigDirectory.map { _ in () },
            ClaudeCodeAccountStore.shared.$defaultAccountIsEnabled.map { _ in () }
        )
        let codexAccountChanges = Publishers.MergeMany([
            CodexAccountStore.shared.$customAccounts.map { _ in () }.eraseToAnyPublisher(),
            CodexAccountStore.shared.$defaultAccountHomeDirectory.map { _ in () }.eraseToAnyPublisher(),
            CodexAccountStore.shared.$defaultAccountIsEnabled.map { _ in () }.eraseToAnyPublisher(),
        ])
        let grokAccountChanges = Publishers.Merge3(
            GrokAccountStore.shared.$customAccounts.map { _ in () },
            GrokAccountStore.shared.$defaultAccountName.map { _ in () },
            GrokAccountStore.shared.$defaultAccountIsEnabled.map { _ in () }
        )
        let thresholdChanges = Publishers.Merge3(
            notificationPreferences.$isEnabled.map { _ in () },
            notificationPreferences.$warningThreshold.map { _ in () },
            notificationPreferences.$criticalThreshold.map { _ in () }
        )
        let refreshChanges = UsageDataManager.shared.$refreshGeneration.map { _ in () }
        let visibilityChanges = providerVisibilityStore.$hiddenServices.map { _ in () }

        let triggers: [AnyPublisher<Void, Never>] = [
            refreshChanges.eraseToAnyPublisher(),
            claudeAccountChanges.eraseToAnyPublisher(),
            codexAccountChanges.eraseToAnyPublisher(),
            grokAccountChanges.eraseToAnyPublisher(),
            visibilityChanges.eraseToAnyPublisher(),
            thresholdChanges.eraseToAnyPublisher()
        ]

        for trigger in triggers {
            trigger
                .sink { [weak self] _ in
                    // Deferred to the next main-actor hop so the published
                    // property has committed before it is read back.
                    Task { @MainActor in
                        self?.checkAndNotify()
                    }
                }
                .store(in: &cancellables)
        }
    }

    /// Evaluates every tracked service's metrics against the user's notification
    /// preferences and posts any warning/critical crossings. Threshold decisions
    /// live in `NotificationDecider`; account/fallback orchestration lives in
    /// `AccountNotificationPlanner`.
    func checkAndNotify() {
        let decider = NotificationDecider(preferences: notificationPreferences.preferences)
        let now = Date()
        var keys = notifiedLimitKeys
        let currentMetrics = UsageDataManager.shared.metrics

        for service in Self.flatNotificationServices {
            // Disabled providers are removed from UsageDataManager. Evaluate an
            // empty snapshot so their stale band keys are cleared instead of
            // suppressing a future crossing after the provider is re-enabled.
            let metrics = currentMetrics[service] ?? UsageMetrics(service: service, lastUpdated: now)
            let evaluation = decider.evaluate(
                metrics: metrics,
                providerEnabled: providerVisibilityStore.isEnabled(service),
                alreadyNotified: keys,
                now: now
            )
            keys = evaluation.notifiedKeys
            for fired in evaluation.notifications {
                postNotification(fired)
            }
        }

        let claudeAccounts = ClaudeCodeAccountStore.shared.accounts.map(AccountNotificationIdentity.init(account:))
        let claudeAccountMetrics = UsageDataManager.shared.claudeCodeAccountMetrics
        let codexAccounts = CodexAccountStore.shared.accounts.map(AccountNotificationIdentity.init(account:))
        let codexAccountMetrics = UsageDataManager.shared.codexAccountMetrics
        let grokAccounts = GrokAccountStore.shared.accounts.map(AccountNotificationIdentity.init(account:))
        let grokAccountMetrics = UsageDataManager.shared.grokAccountMetrics

        let accountPlan = AccountNotificationPlanner(decider: decider).plan(
            inputs: [
                AccountNotificationPlanInput(
                    service: .claudeCode,
                    providerEnabled: providerVisibilityStore.isEnabled(.claudeCode),
                    accounts: claudeAccounts,
                    accountMetrics: claudeAccountMetrics,
                    fallbackMetrics: currentMetrics[.claudeCode],
                    representativeAccountID: AccountNotificationPlanInput.representativeAccountID(
                        accounts: claudeAccounts,
                        accountMetrics: claudeAccountMetrics,
                        defaultID: ClaudeCodeAccount.defaultID
                    )
                ),
                AccountNotificationPlanInput(
                    service: .codexCli,
                    providerEnabled: providerVisibilityStore.isEnabled(.codexCli),
                    accounts: codexAccounts,
                    accountMetrics: codexAccountMetrics,
                    fallbackMetrics: currentMetrics[.codexCli],
                    representativeAccountID: AccountNotificationPlanInput.representativeAccountID(
                        accounts: codexAccounts,
                        accountMetrics: codexAccountMetrics,
                        defaultID: CodexAccount.defaultID
                    )
                ),
                AccountNotificationPlanInput(
                    service: .grok,
                    providerEnabled: providerVisibilityStore.isEnabled(.grok),
                    accounts: grokAccounts,
                    accountMetrics: grokAccountMetrics,
                    fallbackMetrics: currentMetrics[.grok],
                    representativeAccountID: AccountNotificationPlanInput.representativeAccountID(
                        accounts: grokAccounts,
                        accountMetrics: grokAccountMetrics,
                        defaultID: GrokAccount.defaultID
                    )
                )
            ],
            alreadyNotified: keys,
            now: now
        )
        keys = accountPlan.notifiedKeys
        accountPlan.notifications.forEach(postNotification)

        notifiedLimitKeys = keys
    }

    private func postNotification(_ fired: FiredNotification) {
        sendNotification(identifier: fired.key, title: fired.title, body: fired.body)
    }

    /// Observes the shared Session Wake status and posts a completion banner each
    /// time a run settles. The decision (gates + copy) lives in the pure,
    /// unit-tested `SessionWakeNotificationDecider`; this only turns a fired
    /// decision into a banner, mirroring `checkAndNotify`.
    @MainActor
    func observeSessionWakeCompletion() {
        SessionWakeStatus.shared.$watcherState
            .sink { [weak self] state in
                guard case let .completed(summary) = state else { return }
                self?.postSessionWakeCompletion(summary: summary)
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func postSessionWakeCompletion(summary: WakeRunSummary) {
        let provider = SessionWakeSettingsStore.shared.wakeProvider
        let providerService: ServiceType = provider == .codex ? .codexCli : .claudeCode
        let context = SessionWakeNotificationContext(
            globalNotificationsEnabled: notificationPreferences.isEnabled,
            providerEnabled: providerVisibilityStore.isEnabled(providerService),
            providerDisplayName: provider.displayName,
            notifyOnCompletion: SessionWakeSettingsStore.shared.notifyOnCompletion
        )
        guard let fired = SessionWakeNotificationDecider.completionNotification(
            summary: summary,
            context: context
        ) else { return }
        sendNotification(identifier: fired.key, title: fired.title, body: fired.body)
    }

    private func sendNotification(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Stable identifier: re-posting the same id replaces the pending request
        // rather than stacking a new banner every check.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
