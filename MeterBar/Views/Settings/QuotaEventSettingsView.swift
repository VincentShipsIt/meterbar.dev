import MeterBarShared
import SwiftUI

/// General-settings surface for the app-wide local hook and webhook service.
/// Every outbound lane, event, provider, and account starts disabled.
struct QuotaEventSettingsView: View {
    @StateObject private var store = QuotaEventSettingsStore.shared
    @StateObject private var diagnostics = QuotaEventDiagnosticStore.shared
    @StateObject private var claudeAccounts = ClaudeCodeAccountStore.shared
    @StateObject private var codexAccounts = CodexAccountStore.shared
    @StateObject private var grokAccounts = GrokAccountStore.shared

    @State private var isTestingLocalHook = false
    @State private var testMessage: String?

    var body: some View {
        SettingsPanelSection(
            title: "Event Integrations",
            systemImage: "point.3.connected.trianglepath.dotted",
            color: MeterBarTheme.appAccent
        ) {
            SettingsNotice(
                text: "All outbound delivery is opt-in. Events contain only provider, account id/name, "
                    + "quota window, percentage, band, event, and timestamp—never credentials or config paths.",
                color: .secondary
            )

            eventRows
            SettingsDivider()
            providerRows
            SettingsDivider()
            accountRows
            SettingsDivider()
            localDeliveryRows
            SettingsDivider()
            webhookRows
            SettingsDivider()
            sessionWakeRows
            diagnosticsRows
        }
    }

    @ViewBuilder private var eventRows: some View {
        ForEach(QuotaEventKind.allCases, id: \.self) { event in
            SettingsRowView(
                title: "\(event.displayName) event",
                detail: eventDetail(event)
            ) {
                Toggle(event.displayName, isOn: Binding(
                    get: { store.configuration.enabledQuotaEvents.contains(event) },
                    set: { store.setQuotaEventEnabled($0, for: event) }
                ))
                .labelsHidden()
                .meterBarSwitch()
            }
        }
    }

    @ViewBuilder private var providerRows: some View {
        ForEach(ServiceType.allCases) { provider in
            SettingsRowView(
                title: provider.displayName,
                detail: "Allow quota events from this provider."
            ) {
                Toggle(provider.displayName, isOn: Binding(
                    get: { store.configuration.enabledProviders.contains(provider) },
                    set: { store.setProviderEnabled($0, for: provider) }
                ))
                .labelsHidden()
                .meterBarSwitch()
            }
        }
    }

    @ViewBuilder private var accountRows: some View {
        ForEach(integrationAccounts) { account in
            SettingsRowView(
                title: account.name,
                detail: "\(account.provider.displayName) account"
            ) {
                Toggle(account.name, isOn: Binding(
                    get: { store.configuration.enabledAccounts.contains(account.selection) },
                    set: { store.setAccountEnabled($0, for: account.selection) }
                ))
                .labelsHidden()
                .meterBarSwitch()
            }
        }
    }

    @ViewBuilder private var localDeliveryRows: some View {
        SettingsRowView(
            title: "Local command",
            detail: "Run an executable directly, without a shell. Every argument is one literal argv entry."
        ) {
            Toggle("Local command", isOn: Binding(
                get: { store.configuration.localDeliveryEnabled },
                set: { store.setLocalDeliveryEnabled($0) }
            ))
            .labelsHidden()
            .meterBarSwitch()
            .disabled(!store.configuration.localIsConfigured)
        }

        SettingsRowView(title: "Executable", detail: "Absolute executable path.") {
            TextField("/usr/local/bin/my-hook", text: Binding(
                get: { store.configuration.localExecutablePath },
                set: { store.setLocalExecutablePath($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 300)
        }

        ForEach(store.configuration.localArguments.indices, id: \.self) { index in
            SettingsRowView(title: "Argument \(index + 1)") {
                HStack(spacing: 6) {
                    TextField("Literal argument", text: Binding(
                        get: {
                            guard store.configuration.localArguments.indices.contains(index) else { return "" }
                            return store.configuration.localArguments[index]
                        },
                        set: { store.setLocalArgument($0, at: index) }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button {
                        store.removeLocalArgument(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove argument \(index + 1)")
                }
            }
        }

        SettingsRowView(title: "Arguments") {
            Button("Add Argument") { store.addLocalArgument() }
                .buttonStyle(.bordered)
        }

        SettingsRowView(
            title: "Test local command",
            detail: "Runs once with METERBAR_WAKE_EVENT=test and the exact literal argv."
        ) {
            Button(isTestingLocalHook ? "Running…" : "Run Test") {
                testLocalHook()
            }
            .buttonStyle(.bordered)
            .disabled(!store.configuration.localIsConfigured || isTestingLocalHook)
        }

        if let testMessage {
            SettingsNotice(
                text: testMessage,
                color: testMessage == "Hook completed successfully."
                    ? MeterBarTheme.success
                    : MeterBarTheme.warning
            )
        }
    }

    @ViewBuilder private var webhookRows: some View {
        SettingsRowView(
            title: "Webhook",
            detail: "POST the documented versioned JSON contract to one public HTTPS endpoint."
        ) {
            Toggle("Webhook", isOn: Binding(
                get: { store.configuration.webhookDeliveryEnabled },
                set: { store.setWebhookDeliveryEnabled($0) }
            ))
            .labelsHidden()
            .meterBarSwitch()
            .disabled(store.configuration.validatedWebhookURL == nil)
        }

        SettingsRowView(
            title: "Webhook URL",
            detail: "HTTPS on port 443 only; redirects, credentials, loopback, and private IP targets are rejected."
        ) {
            TextField("https://hooks.example.com/meterbar", text: Binding(
                get: { store.configuration.webhookURLString },
                set: { store.setWebhookURLString($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 300)
        }

        if !store.configuration.webhookURLString.isEmpty,
           store.configuration.validatedWebhookURL == nil {
            SettingsNotice(
                text: "Enter a public HTTPS URL on the default port. "
                    + "Local-network and credential-bearing URLs are blocked.",
                color: MeterBarTheme.warning
            )
        }
    }

    @ViewBuilder private var sessionWakeRows: some View {
        SettingsNotice(
            text: "Session Wake compatibility events keep their existing METERBAR_WAKE_* environment contract "
                + "and use the same local executable and literal arguments.",
            color: .secondary
        )
        ForEach(WakeEventHookEvent.allCases, id: \.self) { event in
            SettingsRowView(title: "Session Wake · \(event.displayName)") {
                Toggle(event.displayName, isOn: Binding(
                    get: { store.configuration.enabledWakeEvents.contains(event) },
                    set: { store.setWakeEventEnabled($0, for: event) }
                ))
                .labelsHidden()
                .meterBarSwitch()
                .disabled(!store.configuration.localIsConfigured)
            }
        }
    }

    @ViewBuilder private var diagnosticsRows: some View {
        if let last = diagnostics.records.last {
            SettingsDivider()
            SettingsRowView(
                title: "Last delivery",
                detail: "\(last.provider) · \(last.event.displayName) · \(last.channel.rawValue)"
            ) {
                Text(last.succeeded ? "Delivered" : last.message)
                    .foregroundStyle(last.succeeded ? MeterBarTheme.success : MeterBarTheme.warning)
            }
        }
    }

    private var integrationAccounts: [QuotaEventSelectableAccount] {
        QuotaEventSnapshotCatalog.selectableAccounts(
            claudeAccounts: claudeAccounts.accounts,
            codexAccounts: codexAccounts.accounts,
            grokAccounts: grokAccounts.accounts
        )
    }

    private func eventDetail(_ event: QuotaEventKind) -> String {
        switch event {
        case .warning: return "Quota entered the shared Tight band."
        case .critical: return "Quota entered the shared Critical band."
        case .exhausted: return "Quota reached 100% used."
        case .recovered: return "Quota returned to the shared Healthy band."
        }
    }

    private func testLocalHook() {
        let configuration = store.configuration
        isTestingLocalHook = true
        testMessage = nil
        Task {
            let result = await WakeEventHookRunner().run(
                configuration: WakeEventHookConfiguration(
                    executablePath: configuration.localExecutablePath,
                    arguments: configuration.localArguments,
                    enabledEvents: []
                ),
                context: .test
            )
            testMessage = result.userMessage
            isTestingLocalHook = false
        }
    }
}
