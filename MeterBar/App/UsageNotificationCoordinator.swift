import Combine
import Foundation
import MeterBarShared
import os
@preconcurrency import UserNotifications

@MainActor
protocol UserNotificationPosting {
    func requestAuthorizationIfNeeded()
    func ensureAuthorization() async -> Bool
    @discardableResult
    func post(identifier: String, title: String, body: String) async -> Bool
}

/// Shared permission-aware notification boundary for quota, Session Wake, and
/// account-failover banners.
@MainActor
final class LiveUserNotificationPoster: UserNotificationPosting {
    static let shared = LiveUserNotificationPoster()

    private let injectedCenter: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter? = nil) {
        injectedCenter = center
    }

    func requestAuthorizationIfNeeded() {
        let center = injectedCenter ?? .current()
        center.getNotificationSettings { [center] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
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
                break
            @unknown default:
                break
            }
        }
    }

    func post(identifier: String, title: String, body: String) async -> Bool {
        let center = injectedCenter ?? .current()
        guard await ensureAuthorization(using: center) else { return false }
        let delivered = await center.deliveredNotifications()
        if delivered.contains(where: { $0.request.identifier == identifier }) { return true }
        let pending = await center.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == identifier }) { return true }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            AppLog.app.error("Notification delivery failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func ensureAuthorization() async -> Bool {
        await ensureAuthorization(using: injectedCenter ?? .current())
    }

    private func ensureAuthorization(using center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        let allowed: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            allowed = true
        case .notDetermined:
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .denied:
            allowed = false
        @unknown default:
            allowed = false
        }
        return allowed
    }
}

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
extension OpenRouterAccount: NotificationAccountIdentity {}

extension AccountNotificationIdentity {
    nonisolated init(account: some NotificationAccountIdentity) {
        self.init(id: account.id, name: account.name, isEnabled: account.isEnabled)
    }
}

/// One provider's live accounts for exhaustive notification routing.
struct NotificationAccountBundle {
    let accounts: [AccountNotificationIdentity]
    let metrics: [UUID: UsageMetrics]
    let defaultID: UUID
}

/// Owns quota-threshold and Session Wake banners, extracted from
/// `MeterBarApp.swift` (C1 split).
///
/// Pure move apart from the account mapping above: authorization, the trigger
/// fan-in, the threshold sweep, and the two notification posts keep their exact
/// bodies. It holds its own `cancellables` and launch task so `AppDelegate` no
/// longer has to.
@MainActor
final class UsageNotificationCoordinator {
    private let notificationPreferences = NotificationPreferencesStore.shared
    private let providerVisibilityStore = ProviderVisibilityStore.shared
    private var cancellables = Set<AnyCancellable>()
    private let notificationPoster: UserNotificationPosting

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

    init(notificationPoster: UserNotificationPosting? = nil) {
        self.notificationPoster = notificationPoster ?? LiveUserNotificationPoster.shared
    }

    /// Exhaustive account-scoped notification inputs. A new `ServiceType` with
    /// `hasAccountScopedNotifications` is a compile error in the switch until
    /// its account bundle is wired here.
    static func accountScopedPlanInputs(
        metrics: [ServiceType: UsageMetrics],
        isEnabled: (ServiceType) -> Bool,
        claude: NotificationAccountBundle,
        codex: NotificationAccountBundle,
        grok: NotificationAccountBundle,
        openRouter: NotificationAccountBundle
    ) -> [AccountNotificationPlanInput] {
        ServiceType.allCases.filter(\.hasAccountScopedNotifications).compactMap { service in
            switch service {
            case .claudeCode:
                return planInput(
                    service: .claudeCode,
                    providerEnabled: isEnabled(.claudeCode),
                    bundle: claude,
                    fallbackMetrics: metrics[.claudeCode]
                )
            case .codexCli:
                return planInput(
                    service: .codexCli,
                    providerEnabled: isEnabled(.codexCli),
                    bundle: codex,
                    fallbackMetrics: metrics[.codexCli]
                )
            case .grok:
                return planInput(
                    service: .grok,
                    providerEnabled: isEnabled(.grok),
                    bundle: grok,
                    fallbackMetrics: metrics[.grok]
                )
            case .openRouter:
                return planInput(
                    service: .openRouter,
                    providerEnabled: isEnabled(.openRouter),
                    bundle: openRouter,
                    fallbackMetrics: metrics[.openRouter]
                )
            case .cursor:
                assertionFailure(
                    "account-scoped notifications for \(service.rawValue) have no routing"
                )
                return nil
            }
        }
    }

    private static func planInput(
        service: ServiceType,
        providerEnabled: Bool,
        bundle: NotificationAccountBundle,
        fallbackMetrics: UsageMetrics?
    ) -> AccountNotificationPlanInput {
        AccountNotificationPlanInput(
            service: service,
            providerEnabled: providerEnabled,
            accounts: bundle.accounts,
            accountMetrics: bundle.metrics,
            fallbackMetrics: fallbackMetrics,
            representativeAccountID: AccountNotificationPlanInput.representativeAccountID(
                accounts: bundle.accounts,
                accountMetrics: bundle.metrics,
                defaultID: bundle.defaultID
            )
        )
    }

    func start() {
        notificationPoster.requestAuthorizationIfNeeded()

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
        let openRouterKeyChanges = Publishers.Merge3(
            OpenRouterAccountStore.shared.$customAccounts.map { _ in () },
            OpenRouterAccountStore.shared.$defaultAccountName.map { _ in () },
            OpenRouterAccountStore.shared.$defaultAccountIsEnabled.map { _ in () }
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
            openRouterKeyChanges.eraseToAnyPublisher(),
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

        let accountPlan = AccountNotificationPlanner(decider: decider).plan(
            inputs: Self.accountScopedPlanInputs(
                metrics: currentMetrics,
                isEnabled: providerVisibilityStore.isEnabled,
                claude: NotificationAccountBundle(
                    accounts: ClaudeCodeAccountStore.shared.accounts.map(
                        AccountNotificationIdentity.init(account:)
                    ),
                    metrics: UsageDataManager.shared.claudeCodeAccountMetrics,
                    defaultID: ClaudeCodeAccount.defaultID
                ),
                codex: NotificationAccountBundle(
                    accounts: CodexAccountStore.shared.accounts.map(
                        AccountNotificationIdentity.init(account:)
                    ),
                    metrics: UsageDataManager.shared.codexAccountMetrics,
                    defaultID: CodexAccount.defaultID
                ),
                grok: NotificationAccountBundle(
                    accounts: GrokAccountStore.shared.accounts.map(
                        AccountNotificationIdentity.init(account:)
                    ),
                    metrics: UsageDataManager.shared.grokAccountMetrics,
                    defaultID: GrokAccount.defaultID
                ),
                openRouter: NotificationAccountBundle(
                    accounts: OpenRouterAccountStore.shared.accounts.map(
                        AccountNotificationIdentity.init(account:)
                    ),
                    metrics: UsageDataManager.shared.openRouterAccountMetrics,
                    defaultID: OpenRouterAccount.defaultID
                )
            ),
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
        Task {
            await notificationPoster.post(identifier: identifier, title: title, body: body)
        }
    }
}
