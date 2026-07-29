import Combine
import Foundation
import MeterBarShared

nonisolated enum QuotaEventDeliveryChannel: String, Equatable, Sendable {
    case local
    case webhook
}

nonisolated enum QuotaEventDeliveryOutcome: Equatable, Sendable {
    case succeeded
    case failed(String)

    var succeeded: Bool {
        if case .succeeded = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .succeeded: return "Delivered."
        case let .failed(message): return message
        }
    }
}

nonisolated struct QuotaEventDeliveryDiagnostic: Equatable, Sendable {
    let channel: QuotaEventDeliveryChannel
    let provider: String
    let accountID: String
    let event: QuotaEventKind
    let window: QuotaEventWindow
    let timestamp: Date
    let succeeded: Bool
    let message: String
}

nonisolated struct QuotaEventLocalHookRunner: Sendable {
    private let runner: WakeEventHookRunner

    init(runner: WakeEventHookRunner = WakeEventHookRunner()) {
        self.runner = runner
    }

    func run(
        configuration: QuotaEventIntegrationConfiguration,
        payload: QuotaEventPayload
    ) async -> WakeEventHookResult {
        await runner.run(
            configuration: WakeEventHookConfiguration(
                executablePath: configuration.localExecutablePath,
                arguments: configuration.localArguments,
                enabledEvents: []
            ),
            context: .quota(payload)
        )
    }
}

nonisolated struct QuotaEventDeliveryHandlers: Sendable {
    let local: @Sendable (
        QuotaEventPayload,
        QuotaEventIntegrationConfiguration
    ) async -> QuotaEventDeliveryOutcome
    let webhook: @Sendable (
        QuotaEventPayload,
        QuotaEventIntegrationConfiguration
    ) async -> QuotaEventDeliveryOutcome

    static func live(
        localRunner: QuotaEventLocalHookRunner = QuotaEventLocalHookRunner(),
        webhookClient: QuotaWebhookClient = QuotaWebhookClient()
    ) -> Self {
        Self(
            local: { payload, configuration in
                let result = await localRunner.run(configuration: configuration, payload: payload)
                return result.succeeded ? .succeeded : .failed(result.userMessage)
            },
            webhook: { payload, configuration in
                guard let url = configuration.validatedWebhookURL else {
                    return .failed("Webhook URL is not allowed.")
                }
                switch await webhookClient.post(payload: payload, to: url) {
                case .succeeded: return .succeeded
                case let .failed(message): return .failed(message)
                }
            }
        )
    }
}

/// Stateless, failure-isolating delivery pass. Every matching payload reaches
/// every enabled lane even when an earlier lane or event fails.
nonisolated struct QuotaEventDeliveryEngine: Sendable {
    private let handlers: QuotaEventDeliveryHandlers

    init(handlers: QuotaEventDeliveryHandlers = .live()) {
        self.handlers = handlers
    }

    func deliver(
        payloads: [QuotaEventPayload],
        configuration: QuotaEventIntegrationConfiguration
    ) async -> [QuotaEventDeliveryDiagnostic] {
        var diagnostics: [QuotaEventDeliveryDiagnostic] = []
        for payload in payloads where configuration.includes(payload) {
            if configuration.localDeliveryEnabled {
                let outcome = await handlers.local(payload, configuration)
                diagnostics.append(diagnostic(.local, outcome: outcome, payload: payload))
            }
            if configuration.webhookDeliveryEnabled {
                let outcome = await handlers.webhook(payload, configuration)
                diagnostics.append(diagnostic(.webhook, outcome: outcome, payload: payload))
            }
        }
        return diagnostics
    }

    private func diagnostic(
        _ channel: QuotaEventDeliveryChannel,
        outcome: QuotaEventDeliveryOutcome,
        payload: QuotaEventPayload
    ) -> QuotaEventDeliveryDiagnostic {
        QuotaEventDeliveryDiagnostic(
            channel: channel,
            provider: payload.provider.rawValue,
            accountID: payload.account.id,
            event: payload.event,
            window: payload.window,
            timestamp: payload.timestamp,
            succeeded: outcome.succeeded,
            message: outcome.message
        )
    }
}

/// In-memory, bounded, non-secret diagnostic state surfaced in Settings.
final class QuotaEventDiagnosticStore: ObservableObject {
    static let shared = QuotaEventDiagnosticStore()

    @Published private(set) var records: [QuotaEventDeliveryDiagnostic] = []

    private let capacity: Int

    init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    func record(_ newRecords: [QuotaEventDeliveryDiagnostic]) {
        guard !newRecords.isEmpty else { return }
        records = Array((records + newRecords).suffix(capacity))
    }
}
