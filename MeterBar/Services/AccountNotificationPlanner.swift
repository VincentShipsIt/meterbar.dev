import Foundation
import MeterBarShared

/// Account metadata required to plan quota notifications without reading stores.
struct AccountNotificationIdentity: Equatable, Sendable {
    let id: UUID
    let name: String
    let isEnabled: Bool
}

/// One account-aware provider snapshot for the pure notification planner.
struct AccountNotificationPlanInput {
    let service: ServiceType
    let providerEnabled: Bool
    let accounts: [AccountNotificationIdentity]
    let accountMetrics: [UUID: UsageMetrics]
    let fallbackMetrics: UsageMetrics?
    /// Account whose metrics the provider-wide fallback snapshot represents.
    /// Legacy fallback keys migrate only into this namespace so a secondary
    /// profile cannot inherit another home's already-notified band.
    let representativeAccountID: UUID?

    /// Same selection `UsageDataManager` uses when publishing the provider-wide
    /// snapshot: the enabled default when it has data, otherwise the first
    /// enabled account with metrics.
    static func representativeAccountID(
        accounts: [AccountNotificationIdentity],
        accountMetrics: [UUID: UsageMetrics],
        defaultID: UUID
    ) -> UUID? {
        let enabled = accounts.filter(\.isEnabled)
        if enabled.contains(where: { $0.id == defaultID }),
           accountMetrics[defaultID] != nil {
            return defaultID
        }
        return enabled.first { accountMetrics[$0.id] != nil }?.id
    }
}

/// Fired notifications and the dedup state to thread into the next planning pass.
struct AccountNotificationPlan: Equatable, Sendable {
    let notifications: [FiredNotification]
    let notifiedKeys: Set<String>
}

/// Pure account/fallback orchestration shared by Claude Code, Codex, and Grok.
///
/// Account metrics take precedence whenever at least one enabled account has
/// data. Provider fallback is used only when every enabled account is
/// unavailable. Switching from fallback primes only the representative
/// account's namespace, so a secondary profile cannot inherit another home's
/// already-notified band.
struct AccountNotificationPlanner {
    private typealias AvailableAccount = (
        identity: AccountNotificationIdentity,
        metrics: UsageMetrics
    )

    private let decider: NotificationDecider

    init(
        preferences: NotificationPreferences,
        stalenessThreshold: TimeInterval = NotificationDecider.defaultStalenessThreshold
    ) {
        decider = NotificationDecider(
            preferences: preferences,
            stalenessThreshold: stalenessThreshold
        )
    }

    init(decider: NotificationDecider) {
        self.decider = decider
    }

    func plan(
        inputs: [AccountNotificationPlanInput],
        alreadyNotified: Set<String>,
        now: Date = Date()
    ) -> AccountNotificationPlan {
        var keys = alreadyNotified
        var notifications: [FiredNotification] = []

        for input in inputs {
            plan(
                input: input,
                keys: &keys,
                notifications: &notifications,
                now: now
            )
        }

        return AccountNotificationPlan(
            notifications: notifications,
            notifiedKeys: keys
        )
    }

    private func plan(
        input: AccountNotificationPlanInput,
        keys: inout Set<String>,
        notifications: inout [FiredNotification],
        now: Date
    ) {
        let enabledAccounts = input.accounts.filter(\.isEnabled)
        guard input.providerEnabled else {
            clearProviderState(service: input.service, keys: &keys)
            return
        }

        if enabledAccounts.isEmpty {
            clearAccountState(service: input.service, keys: &keys)
        }

        for account in input.accounts where !account.isEnabled {
            keys.subtract(
                NotificationDecider.notificationKeys(
                    service: input.service,
                    accountKey: account.id.uuidString,
                    includingExisting: keys
                )
            )
            keys.remove(
                observedAccountKey(
                    service: input.service,
                    accountKey: account.id.uuidString
                )
            )
        }

        let availableAccounts = enabledAccounts.compactMap { account -> AvailableAccount? in
            guard let metrics = input.accountMetrics[account.id] else { return nil }
            return (account, metrics)
        }

        guard !availableAccounts.isEmpty else {
            guard let fallbackMetrics = input.fallbackMetrics else {
                clearFallbackState(service: input.service, keys: &keys)
                return
            }
            if !hasObservedFallbackState(service: input.service, keys: keys) {
                for account in enabledAccounts {
                    keys.formUnion(translatedKeys(
                        notificationState(
                            service: input.service,
                            accountKey: account.id.uuidString,
                            keys: keys
                        ),
                        service: input.service,
                        fromAccountKey: account.id.uuidString,
                        toAccountKey: nil
                    ))
                }
            }

            let evaluation = decider.evaluate(
                metrics: fallbackMetrics,
                providerEnabled: true,
                alreadyNotified: keys,
                now: now
            )
            keys = evaluation.notifiedKeys
            recordObservedFallbackState(service: input.service, keys: &keys)
            notifications.append(contentsOf: evaluation.notifications)
            return
        }

        let fallbackState = clearFallbackState(service: input.service, keys: &keys)
        let migrationAccountIDs = Self.fallbackMigrationAccountIDs(
            representativeAccountID: input.representativeAccountID,
            availableAccounts: availableAccounts
        )
        for available in availableAccounts {
            let accountID = available.identity.id
            let accountKey = accountID.uuidString
            guard migrationAccountIDs.contains(accountID) else { continue }
            guard !hasObservedAccountState(
                service: input.service,
                accountKey: accountKey,
                keys: keys
            ) else { continue }
            keys.formUnion(
                translatedKeys(
                    fallbackState,
                    service: input.service,
                    fromAccountKey: nil,
                    toAccountKey: accountKey
                )
            )
        }
        for available in availableAccounts {
            let accountKey = available.identity.id.uuidString
            let evaluation = decider.evaluate(
                metrics: available.metrics,
                providerEnabled: true,
                alreadyNotified: keys,
                accountKey: accountKey,
                serviceDisplayName: "\(available.identity.name) (\(input.service.displayName))",
                now: now
            )
            keys = evaluation.notifiedKeys
            recordObservedAccountState(
                service: input.service,
                accountKey: accountKey,
                keys: &keys
            )
            notifications.append(contentsOf: evaluation.notifications)
        }
    }

    private static func fallbackMigrationAccountIDs(
        representativeAccountID: UUID?,
        availableAccounts: [AvailableAccount]
    ) -> Set<UUID> {
        if let representativeAccountID {
            return [representativeAccountID]
        }
        return Set(availableAccounts.map(\.identity.id))
    }

    @discardableResult
    private func clearFallbackState(
        service: ServiceType,
        keys: inout Set<String>
    ) -> Set<String> {
        let fallbackKeys = NotificationDecider.notificationKeys(
            service: service,
            includingExisting: keys
        )
        let removedState = keys.intersection(fallbackKeys)
        keys.subtract(fallbackKeys)
        keys.remove(observedFallbackKey(service: service))
        return removedState
    }

    @discardableResult
    private func clearAccountState(
        service: ServiceType,
        keys: inout Set<String>
    ) -> Set<String> {
        let fallbackKeys = NotificationDecider.notificationKeys(
            service: service,
            includingExisting: keys
        )
        let fallbackStateKeys = fallbackKeys.union([observedFallbackKey(service: service)])
        let servicePrefix = "\(service.rawValue)-"
        let accountKeys = Set(keys.filter {
            $0.hasPrefix(servicePrefix) && !fallbackStateKeys.contains($0)
        })
        keys.subtract(accountKeys)
        return accountKeys
    }

    private func notificationState(
        service: ServiceType,
        accountKey: String,
        keys: Set<String>
    ) -> Set<String> {
        keys.intersection(
            NotificationDecider.notificationKeys(
                service: service,
                accountKey: accountKey,
                includingExisting: keys
            )
        )
    }

    private func hasObservedAccountState(
        service: ServiceType,
        accountKey: String,
        keys: Set<String>
    ) -> Bool {
        keys.contains(observedAccountKey(service: service, accountKey: accountKey))
            || !notificationState(service: service, accountKey: accountKey, keys: keys).isEmpty
    }

    private func recordObservedAccountState(
        service: ServiceType,
        accountKey: String,
        keys: inout Set<String>
    ) {
        let observedKey = observedAccountKey(service: service, accountKey: accountKey)
        if notificationState(service: service, accountKey: accountKey, keys: keys).isEmpty {
            keys.insert(observedKey)
        } else {
            keys.remove(observedKey)
        }
    }

    private func observedAccountKey(service: ServiceType, accountKey: String) -> String {
        "\(service.rawValue)-\(accountKey)-namespace-observed"
    }

    private func hasObservedFallbackState(
        service: ServiceType,
        keys: Set<String>
    ) -> Bool {
        keys.contains(observedFallbackKey(service: service))
            || !keys.isDisjoint(with: NotificationDecider.notificationKeys(
                service: service,
                includingExisting: keys
            ))
    }

    private func recordObservedFallbackState(
        service: ServiceType,
        keys: inout Set<String>
    ) {
        let observedKey = observedFallbackKey(service: service)
        if keys.isDisjoint(with: NotificationDecider.notificationKeys(
            service: service,
            includingExisting: keys
        )) {
            keys.insert(observedKey)
        } else {
            keys.remove(observedKey)
        }
    }

    private func observedFallbackKey(service: ServiceType) -> String {
        "\(service.rawValue)-namespace-observed"
    }

    private func translatedKeys(
        _ keys: Set<String>,
        service: ServiceType,
        fromAccountKey: String?,
        toAccountKey: String?
    ) -> Set<String> {
        let sourcePrefix = [service.rawValue, fromAccountKey]
            .compactMap { $0 }
            .joined(separator: "-") + "-"
        let destinationPrefix = [service.rawValue, toAccountKey]
            .compactMap { $0 }
            .joined(separator: "-") + "-"
        return Set(keys.compactMap { key in
            guard key.hasPrefix(sourcePrefix) else { return nil }
            return destinationPrefix + String(key.dropFirst(sourcePrefix.count))
        })
    }

    private func clearProviderState(
        service: ServiceType,
        keys: inout Set<String>
    ) {
        clearFallbackState(service: service, keys: &keys)
        clearAccountState(service: service, keys: &keys)
    }
}
