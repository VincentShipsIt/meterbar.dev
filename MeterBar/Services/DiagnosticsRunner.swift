import Foundation
import MeterBarShared

/// Owns diagnostics input mapping, readiness inspection, and report formatting.
enum DiagnosticsRunner {
    struct InputKey: Equatable {
        let providers: [ServiceType]
        let defaultClaudeAccountEnabled: Bool
        let enabledClaudeCustomAccountIDs: [UUID]
    }

    static func refreshErrors(
        claudeDefaultAccountEnabled: Bool,
        claudeError: ServiceError?,
        codexError: ServiceError?,
        cursorError: ServiceError?,
        openRouterError: ServiceError?,
        grokError: ServiceError?
    ) -> [ServiceType: ServiceError] {
        var result: [ServiceType: ServiceError] = [:]
        if claudeDefaultAccountEnabled, let claudeError {
            result[.claudeCode] = claudeError
        }
        if let codexError {
            result[.codexCli] = codexError
        }
        if let cursorError {
            result[.cursor] = cursorError
        }
        if let openRouterError {
            result[.openRouter] = openRouterError
        }
        if let grokError {
            result[.grok] = grokError
        }
        return result
    }

    static func inspect(
        enabledProviders: Set<ServiceType>,
        refreshErrors: [ServiceType: ServiceError],
        claudeDefaultAccountEnabled: Bool,
        claudeEnabledAccountMetrics: [UsageMetrics]
    ) async -> [ProviderReadiness] {
        await Task.detached(priority: .userInitiated) {
            ProviderReadinessInspector.reports(
                providers: enabledProviders,
                refreshErrors: refreshErrors,
                claudeDefaultAccountEnabled: claudeDefaultAccountEnabled,
                claudeEnabledAccountMetrics: claudeEnabledAccountMetrics
            )
        }.value
    }

    static func summary(for reports: [ProviderReadiness]) -> String? {
        guard !reports.isEmpty else { return nil }
        return ProviderReadinessSummary(reports: reports).displayText
    }

    static func reportText(for reports: [ProviderReadiness]) -> String {
        DiagnosticsReportText.plainText(reports)
    }
}
