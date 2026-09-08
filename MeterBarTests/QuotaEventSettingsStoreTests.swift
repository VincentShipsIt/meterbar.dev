import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class QuotaEventSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "QuotaEventSettingsStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsRequireExplicitOptInForBothDeliveryModesAndEveryScope() {
        let store = QuotaEventSettingsStore(userDefaults: defaults)

        XCTAssertFalse(store.configuration.localDeliveryEnabled)
        XCTAssertFalse(store.configuration.webhookDeliveryEnabled)
        XCTAssertTrue(store.configuration.enabledQuotaEvents.isEmpty)
        XCTAssertTrue(store.configuration.enabledProviders.isEmpty)
        XCTAssertTrue(store.configuration.enabledAccounts.isEmpty)
        XCTAssertEqual(store.configuration.wakeEventHookConfiguration, .disabled)
    }

    func testLiteralCommandWebhookAndQuotaSelectionsPersistExactly() {
        let store = QuotaEventSettingsStore(userDefaults: defaults)
        let account = QuotaEventAccountSelection(provider: .codexCli, accountID: "work-account")

        store.setLocalExecutablePath("/usr/bin/printf")
        store.addLocalArgument()
        store.setLocalArgument("$(not-expanded); echo still-literal", at: 0)
        store.setLocalDeliveryEnabled(true)
        store.setWebhookURLString("https://hooks.example.com/meterbar")
        store.setWebhookDeliveryEnabled(true)
        store.setQuotaEventEnabled(true, for: .warning)
        store.setQuotaEventEnabled(true, for: .recovered)
        store.setProviderEnabled(true, for: .codexCli)
        store.setAccountEnabled(true, for: account)

        let configuration = QuotaEventSettingsStore(userDefaults: defaults).configuration

        XCTAssertTrue(configuration.localDeliveryEnabled)
        XCTAssertEqual(configuration.localExecutablePath, "/usr/bin/printf")
        XCTAssertEqual(configuration.localArguments, ["$(not-expanded); echo still-literal"])
        XCTAssertTrue(configuration.webhookDeliveryEnabled)
        XCTAssertEqual(configuration.webhookURLString, "https://hooks.example.com/meterbar")
        XCTAssertEqual(configuration.enabledQuotaEvents, [.warning, .recovered])
        XCTAssertEqual(configuration.enabledProviders, [.codexCli])
        XCTAssertEqual(configuration.enabledAccounts, [account])
    }

    func testMigratesExistingSessionWakeHooksOnceWithoutChangingBehavior() throws {
        let legacy = WakeEventHookConfiguration(
            executablePath: "/usr/local/bin/wake-hook",
            arguments: ["--literal", "$(never-expanded)"],
            enabledEvents: [.quotaExhausted, .quotaReset, .wakeComplete]
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: StorageKeys.sessionWakeEventHooks)

        let migrated = QuotaEventSettingsStore(userDefaults: defaults)

        XCTAssertTrue(migrated.configuration.localDeliveryEnabled)
        XCTAssertEqual(migrated.configuration.localExecutablePath, legacy.executablePath)
        XCTAssertEqual(migrated.configuration.localArguments, legacy.arguments)
        XCTAssertEqual(migrated.configuration.enabledWakeEvents, legacy.enabledEvents)
        XCTAssertEqual(migrated.configuration.wakeEventHookConfiguration, legacy)
        XCTAssertTrue(migrated.configuration.enabledQuotaEvents.isEmpty)
        XCTAssertFalse(migrated.configuration.webhookDeliveryEnabled)
        XCTAssertNotNil(defaults.data(forKey: StorageKeys.quotaEventIntegrations))

        // The versioned app-wide value wins after migration; later legacy-key
        // changes cannot silently overwrite a user's new integration settings.
        defaults.set(
            try JSONEncoder().encode(WakeEventHookConfiguration.disabled),
            forKey: StorageKeys.sessionWakeEventHooks
        )
        XCTAssertEqual(
            QuotaEventSettingsStore(userDefaults: defaults).configuration.wakeEventHookConfiguration,
            legacy
        )
    }

    func testSelectionRequiresMatchingEventProviderAndAccount() {
        let store = QuotaEventSettingsStore(userDefaults: defaults)
        let selectedAccount = QuotaEventAccountSelection(provider: .cursor, accountID: "selected")
        store.setQuotaEventEnabled(true, for: .critical)
        store.setProviderEnabled(true, for: .cursor)
        store.setAccountEnabled(true, for: selectedAccount)

        let selected = payload(provider: .cursor, accountID: "selected", event: .critical)
        let wrongEvent = payload(provider: .cursor, accountID: "selected", event: .warning)
        let wrongProvider = payload(provider: .grok, accountID: "selected", event: .critical)
        let wrongAccount = payload(provider: .cursor, accountID: "other", event: .critical)

        XCTAssertTrue(store.configuration.includes(selected))
        XCTAssertFalse(store.configuration.includes(wrongEvent))
        XCTAssertFalse(store.configuration.includes(wrongProvider))
        XCTAssertFalse(store.configuration.includes(wrongAccount))
    }

    func testMigratesLegacyGrokDefaultSelectionWithoutDuplicatingTheDefaultProfile() throws {
        let legacy = QuotaEventAccountSelection(provider: .grok, accountID: "default")
        let defaultProfile = QuotaEventAccountSelection(
            provider: .grok,
            accountID: GrokAccount.defaultID.uuidString
        )
        let work = QuotaEventAccountSelection(
            provider: .grok,
            accountID: "C3D4E5F6-A7B8-4901-8234-567890ABCDEF"
        )
        let stored = QuotaEventIntegrationConfiguration(
            localDeliveryEnabled: false,
            localExecutablePath: "",
            localArguments: [],
            webhookDeliveryEnabled: true,
            webhookURLString: "https://hooks.example.com/meterbar",
            enabledQuotaEvents: [.warning, .critical],
            enabledProviders: [.grok],
            enabledAccounts: [legacy, defaultProfile, work],
            enabledWakeEvents: []
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: StorageKeys.quotaEventIntegrations)

        let store = QuotaEventSettingsStore(userDefaults: defaults)
        let reloaded = try JSONDecoder().decode(
            QuotaEventIntegrationConfiguration.self,
            from: try XCTUnwrap(defaults.data(forKey: StorageKeys.quotaEventIntegrations))
        )

        XCTAssertEqual(store.configuration.enabledAccounts, [defaultProfile, work])
        XCTAssertEqual(reloaded.enabledAccounts, [defaultProfile, work])
        XCTAssertTrue(store.configuration.includes(
            payload(provider: .grok, accountID: GrokAccount.defaultID.uuidString, event: .critical)
        ))
        XCTAssertFalse(store.configuration.includes(
            payload(provider: .grok, accountID: "default", event: .critical)
        ))
        XCTAssertTrue(store.configuration.includes(
            payload(provider: .grok, accountID: work.accountID, event: .warning)
        ))
    }

    func testLegacyGrokDefaultSelectionStillMatchesTheDefaultProfilePayload() {
        let store = QuotaEventSettingsStore(userDefaults: defaults)
        store.setQuotaEventEnabled(true, for: .exhausted)
        store.setProviderEnabled(true, for: .grok)
        store.setAccountEnabled(true, for: QuotaEventAccountSelection(provider: .grok, accountID: "default"))

        XCTAssertTrue(store.configuration.includes(
            payload(provider: .grok, accountID: GrokAccount.defaultID.uuidString, event: .exhausted)
        ))
        XCTAssertFalse(store.configuration.includes(
            payload(
                provider: .grok,
                accountID: "C3D4E5F6-A7B8-4901-8234-567890ABCDEF",
                event: .exhausted
            )
        ))
    }

    func testStaleGrokAccountSelectionIsIgnoredAfterTheProfileLeavesTheCatalog() {
        let removed = GrokAccount(
            id: UUID(uuidString: "C3D4E5F6-A7B8-4901-8234-567890ABCDEF")!,
            name: "Work",
            homeDirectory: "/secret/grok-work"
        )
        let store = QuotaEventSettingsStore(userDefaults: defaults)
        store.setQuotaEventEnabled(true, for: .critical)
        store.setProviderEnabled(true, for: .grok)
        store.setAccountEnabled(
            true,
            for: QuotaEventAccountSelection(provider: .grok, accountID: removed.id.uuidString)
        )

        let remaining = QuotaEventSnapshotCatalog.snapshots(
            metrics: [:],
            accounts: QuotaEventAccountInputs(
                grokAccounts: [.defaultAccount],
                grokAccountMetrics: [GrokAccount.defaultID: payloadMetrics()]
            ),
            enabledServices: [.grok]
        )
        let selectable = QuotaEventSnapshotCatalog.selectableAccounts(
            claudeAccounts: [],
            codexAccounts: [],
            grokAccounts: [.defaultAccount]
        )

        XCTAssertFalse(remaining.contains { $0.account.id == removed.id.uuidString })
        XCTAssertFalse(selectable.contains { $0.accountID == removed.id.uuidString })
        XCTAssertTrue(store.configuration.enabledAccounts.contains {
            $0.accountID == removed.id.uuidString
        })
        XCTAssertFalse(remaining.contains { snapshot in
            store.configuration.includes(
                payload(provider: snapshot.provider, accountID: snapshot.account.id, event: .critical)
            )
        })
    }

    /// An unknown quota-event kind or provider raw value must degrade only
    /// that one entry, never fail the whole document — and since nothing
    /// meaningful changed, the store must not rewrite the stored bytes on
    /// load either.
    ///
    /// Before this fix, `init(from:)` decoded `Set<QuotaEventKind>`,
    /// `Set<ServiceType>`, and `Set<WakeEventHookEvent>` with a plain `try`.
    /// One unknown raw value threw through the whole document, the store's
    /// `try?` fell back to `.disabled`, and `persist()` immediately wrote
    /// that fallback back over both the versioned key and the legacy
    /// `sessionWakeEventHooks` mirror — losing the webhook URL, executable
    /// path, arguments, and every explicit selection with no recovery path.
    func testUnknownEventKindAndProviderDegradeInPlaceWithoutOverwritingStorage() throws {
        let account = QuotaEventAccountSelection(provider: .codexCli, accountID: "work-account")
        let written = QuotaEventIntegrationConfiguration(
            localDeliveryEnabled: true,
            localExecutablePath: "/usr/bin/printf",
            localArguments: ["--literal"],
            webhookDeliveryEnabled: true,
            webhookURLString: "https://hooks.example.com/meterbar",
            enabledQuotaEvents: [.warning, .critical],
            enabledProviders: [.codexCli, .cursor],
            enabledAccounts: [account],
            enabledWakeEvents: [.quotaExhausted]
        )
        let data = try encoded(written) { object in
            object["enabledQuotaEvents"] = [QuotaEventKind.warning.rawValue, "futureEventKind"]
            object["enabledProviders"] = [ServiceType.codexCli.rawValue, "futureProvider"]
        }
        defaults.set(data, forKey: StorageKeys.quotaEventIntegrations)

        let store = QuotaEventSettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.configuration.enabledQuotaEvents, [.warning])
        XCTAssertEqual(store.configuration.enabledProviders, [.codexCli])
        XCTAssertEqual(store.configuration.enabledAccounts, [account])
        XCTAssertEqual(store.configuration.enabledWakeEvents, [.quotaExhausted])
        XCTAssertTrue(store.configuration.localDeliveryEnabled)
        XCTAssertEqual(store.configuration.localExecutablePath, "/usr/bin/printf")
        XCTAssertEqual(store.configuration.localArguments, ["--literal"])
        XCTAssertTrue(store.configuration.webhookDeliveryEnabled)
        XCTAssertEqual(store.configuration.webhookURLString, "https://hooks.example.com/meterbar")

        // Nothing was overwritten: neither the versioned key nor the legacy
        // mirror was touched by the load.
        XCTAssertEqual(defaults.data(forKey: StorageKeys.quotaEventIntegrations), data)
        XCTAssertNil(defaults.data(forKey: StorageKeys.sessionWakeEventHooks))
    }

    /// A document written by a newer build (`version` ahead of what this
    /// build knows) must never be rewritten on load, even when this build's
    /// own normalization (the Grok default-account migration) would otherwise
    /// change it — the unread parts of a future schema must reach a build
    /// that does understand them intact.
    func testFutureVersionedConfigurationIsNeverPersistedOnLoad() throws {
        let legacyGrokDefault = QuotaEventAccountSelection(provider: .grok, accountID: "default")
        let written = QuotaEventIntegrationConfiguration(
            version: QuotaEventIntegrationConfiguration.currentVersion + 1,
            localDeliveryEnabled: false,
            localExecutablePath: "",
            localArguments: [],
            webhookDeliveryEnabled: false,
            webhookURLString: "",
            enabledQuotaEvents: [],
            enabledProviders: [.grok],
            enabledAccounts: [legacyGrokDefault],
            enabledWakeEvents: []
        )
        let data = try JSONEncoder().encode(written)
        defaults.set(data, forKey: StorageKeys.quotaEventIntegrations)

        let store = QuotaEventSettingsStore(userDefaults: defaults)

        // In memory the normalization still runs, so matching behaves
        // correctly for the rest of this launch...
        XCTAssertTrue(store.configuration.enabledAccounts.contains {
            $0.accountID == GrokAccount.defaultID.uuidString
        })
        // ...but a build older than the document's version never rewrites it.
        XCTAssertEqual(defaults.data(forKey: StorageKeys.quotaEventIntegrations), data)
    }

    /// Re-encodes a known-good value and edits the JSON, so the fixture can
    /// never drift from the real wire format.
    private func encoded(
        _ configuration: QuotaEventIntegrationConfiguration,
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        )
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func payloadMetrics() -> UsageMetrics {
        UsageMetrics(
            service: .grok,
            sessionLimit: UsageLimit(
                used: 50,
                total: 100,
                resetTime: Date(timeIntervalSince1970: 1_800_003_600)
            ),
            lastUpdated: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func payload(
        provider: ServiceType,
        accountID: String,
        event: QuotaEventKind
    ) -> QuotaEventPayload {
        QuotaEventPayload(
            provider: provider,
            account: QuotaEventAccount(id: accountID, name: "Account"),
            event: event,
            window: .session,
            percentage: 91,
            band: .critical,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
