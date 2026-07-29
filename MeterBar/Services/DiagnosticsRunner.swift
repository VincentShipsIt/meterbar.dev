import Foundation
import MeterBarShared

/// Owns diagnostics input mapping, readiness inspection, and report formatting.
enum DiagnosticsRunner {
    struct RefreshCadence: Equatable {
        let selection: String
        let effectiveInterval: String
        let reason: String
    }

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

    static func refreshCadence(
        selection: RefreshInterval,
        effectiveInterval: TimeInterval?,
        reason: String
    ) -> RefreshCadence {
        RefreshCadence(
            selection: selection.displayName,
            effectiveInterval: effectiveInterval.map(intervalText) ?? "Not scheduled",
            reason: reason
        )
    }

    static func reportText(
        for reports: [ProviderReadiness],
        refreshCadence: RefreshCadence? = nil
    ) -> String {
        let providerReport = DiagnosticsReportText.plainText(reports)
        guard let refreshCadence else { return providerReport }
        let cadenceReport = """
        Refresh cadence: \(refreshCadence.selection) · \(refreshCadence.effectiveInterval)
        Reason: \(refreshCadence.reason)
        """
        return providerReport.isEmpty ? cadenceReport : "\(cadenceReport)\n\n\(providerReport)"
    }

    private static func intervalText(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
