import ArgumentParser
import Darwin
import Foundation
import MeterBar
import MeterBarShared

@main
struct MeterBarCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meterbar",
        abstract: "Track AI coding assistant usage from the command line",
        version: MeterBarCLIVersion.current,
        subcommands: [Usage.self, Cost.self, Doctor.self, Wake.self],
        defaultSubcommand: Usage.self
    )
}

private enum MeterBarCLIVersion {
    static var current: String {
        appBundleVersion ?? "development"
    }

    private static var appBundleVersion: String? {
        guard let executableURL = processExecutableURL else {
            return nil
        }

        let contentsURL = executableURL
            .deletingLastPathComponent() // meterbar
            .deletingLastPathComponent() // Helpers

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return version
    }

    private static var processExecutableURL: URL? {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))

        if _NSGetExecutablePath(&buffer, &size) == -1 {
            buffer = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else {
                return nil
            }
        }

        return URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath()
    }
}

struct Usage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show current usage metrics"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Filter by provider (claude, codex, cursor)")
    var provider: String?

    func run() throws {
        // Same app-group file, codec, and models as the app and widget.
        let metrics = SharedDataStore.shared.loadMetrics()

        if metrics.isEmpty {
            if json {
                print("{\"error\": \"No cached metrics found. Open MeterBar app to fetch data.\"}")
            } else {
                print("No cached metrics found.")
                print("Open MeterBar app to fetch usage data first.")
            }
            return
        }

        let filtered: [ServiceType: UsageMetrics]
        if let provider = provider?.lowercased() {
            filtered = metrics.filter {
                $0.key.rawValue.lowercased().contains(provider)
                    || $0.key.displayName.lowercased().contains(provider)
            }
        } else {
            filtered = metrics
        }

        if json {
            printJSON(filtered)
        } else {
            printText(filtered)
        }
    }

    private func printJSON(_ metrics: [ServiceType: UsageMetrics]) {
        let keyed = metrics.reduce(into: [String: UsageMetrics]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(keyed),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private func printText(_ metrics: [ServiceType: UsageMetrics]) {
        print("╭─────────────────────────────────────────╮")
        print("│             MeterBar Usage              │")
        print("╰─────────────────────────────────────────╯")
        print()

        for (service, metric) in metrics.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("▸ \(service.displayName)")

            if let session = metric.sessionLimit {
                printLimit("  Session", session)
            }
            if let weekly = metric.weeklyLimit {
                printLimit("  Weekly", weekly)
            }
            if let codeReview = metric.codeReviewLimit {
                printLimit(service == .claudeCode ? "  Sonnet" : "  Code Review", codeReview)
            }
            print()
        }
    }

    private func printLimit(_ label: String, _ limit: UsageLimit) {
        let percent = limit.percentage
        let bar = progressBar(percent: percent, width: 20)
        let status = statusEmoji(for: limit)

        print("\(label): \(bar) \(String(format: "%.0f%%", percent)) \(status)")
        print("    \(Int(limit.used))/\(Int(limit.total)) used")
        if let reset = limit.resetTime {
            print("    Resets: \(UsageFormat.relative(reset))")
        }
    }

    private func progressBar(percent: Double, width: Int) -> String {
        let filled = Int((percent / 100) * Double(width))
        let empty = width - filled
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    /// Same severity bands as the app (previously the CLI warned at 50% used
    /// while the app warned at 75%).
    private func statusEmoji(for limit: UsageLimit) -> String {
        switch QuotaBand.forLimit(limit) {
        case .healthy: return "✓"
        case .tight: return "⚠"
        case .critical, .exhausted: return "✗"
        }
    }
}

struct Cost: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show token costs from the MeterBar app's last local scan"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    @Option(
        name: .shortAndLong,
        help: "Limit to the last N days using the cached daily breakdown (no rescan)."
    )
    var days: Int?

    func validate() throws {
        if let days, days < 1 {
            throw ValidationError("--days must be 1 or greater.")
        }
    }

    func run() throws {
        // Reports the app's cached scan instead of re-implementing it. The old
        // CLI scanner diverged from the app (no event dedup, one scan root,
        // file-mtime-only cutoff, hardcoded Sonnet pricing) so `meterbar cost`
        // and the app's Costs tab showed different numbers for the same logs.
        guard let cache = CostSummaryStore.load() else {
            if json {
                print("{\"error\": \"No cost data cached. Open MeterBar and run a scan (Costs tab).\"}")
            } else {
                print("No cost data cached.")
                print("Open MeterBar and run a scan (Costs tab), then try again.")
            }
            return
        }

        // `--days N` reports a windowed view derived purely from the cached daily
        // rows — no rescan. Falls through to the full cached summary otherwise.
        if let days {
            let window = cache.summary.dailyCostWindow(lastDays: days)
            if json {
                printJSON(window)
            } else {
                printWindow(window, cache: cache)
            }
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(cache),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            printCosts(cache)
        }
    }

    private func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private func printWindow(_ window: DailyCostWindow, cache: CostSummaryCache) {
        print("╭─────────────────────────────────────────╮")
        print("│          MeterBar Cost Tracker          │")
        print("╰─────────────────────────────────────────╯")
        print()
        print("Period: Last \(window.requestedDays) days (from cached daily data)")
        print("Scanned: \(UsageFormat.relative(cache.lastScanDate))")
        print("Pricing: \(ModelPricing.revisionLabel)")

        // The cache holds fewer days than asked for — don't imply full coverage.
        if window.isTruncated {
            print()
            print("⚠ Cache only covers \(window.coveredDays) day(s); "
                + "showing what's available. Open MeterBar and rescan for a longer window.")
        }
        print()

        if window.providers.isEmpty {
            if cache.summary.costs.isEmpty {
                print("No usage in the last \(window.requestedDays) days.")
            } else {
                // Legacy caches carry totals but no per-day rows.
                print("No cached daily breakdown for this window.")
                print("Open MeterBar and rescan (Costs tab) to record per-day usage.")
            }
            return
        }

        for provider in window.providers {
            print("▸ \(provider.provider.displayName)")
            print("  Input:          \(UsageFormat.groupedTokens(provider.inputTokens))")
            print("  Output:         \(UsageFormat.groupedTokens(provider.outputTokens))")
            print("  Cache Read:     \(UsageFormat.groupedTokens(provider.cacheReadTokens))")
            print("  Estimated Cost: \(provider.formattedCost)")
            print()
        }

        print("Total:          \(window.formattedTotalCost)")
        print("Tokens:         \(UsageFormat.groupedTokens(window.totalTokens))")
    }

    private func printCosts(_ cache: CostSummaryCache) {
        let summary = cache.summary

        print("╭─────────────────────────────────────────╮")
        print("│          MeterBar Cost Tracker          │")
        print("╰─────────────────────────────────────────╯")
        print()
        print("Period: Last \(summary.periodDays) days")
        print("Scanned: \(UsageFormat.relative(cache.lastScanDate))")
        print("Pricing: \(ModelPricing.revisionLabel)")
        print()

        for cost in summary.costs {
            print("▸ \(cost.provider.displayName)")
            print("  Sessions:       \(cost.sessionCount)")
            print("  Input:          \(UsageFormat.groupedTokens(cost.inputTokens))")
            print("  Output:         \(UsageFormat.groupedTokens(cost.outputTokens))")
            print("  Cache Creation: \(UsageFormat.groupedTokens(cost.cacheCreationTokens))")
            print("  Cache Read:     \(UsageFormat.groupedTokens(cost.cacheReadTokens))")
            print("  Estimated Cost: \(cost.formattedCost)")
            print()
        }

        print("Total:          \(summary.formattedTotalCost)")
        print("Daily Average:  \(summary.formattedDailyCost)")
        print("Tokens:         \(UsageFormat.groupedTokens(summary.totalTokens))")
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose provider setup (installed, signed in, data readable)"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Filter by provider (claude, codex, cursor)")
    var provider: String?

    func run() throws {
        // Same readiness core the app's Diagnostics view uses. No live refresh in
        // a one-shot CLI run, so last-refresh checks report "no recent errors".
        // Every string below is redacted by the inspector — safe to paste into an issue.
        // Resolve the filter before gathering so `meterbar doctor --provider`
        // never probes another provider's filesystem, database, or Keychain.
        let requestedProviders = matchingProviders()
        let reports = filtered(ProviderReadinessInspector.reports(providers: requestedProviders))

        if json {
            try printJSON(reports)
        } else {
            printText(reports)
        }
    }

    private func filtered(_ reports: [ProviderReadiness]) -> [ProviderReadiness] {
        reports.sorted { $0.provider.sortOrder < $1.provider.sortOrder }
    }

    private func matchingProviders() -> Set<ServiceType> {
        guard let needle = provider?.lowercased() else {
            return Set(ServiceType.allCases)
        }
        return Set(ServiceType.allCases.filter {
            $0.rawValue.lowercased().contains(needle)
                || $0.displayName.lowercased().contains(needle)
        })
    }

    private func printJSON(_ reports: [ProviderReadiness]) throws {
        let dtos = reports.map(DoctorReportDTO.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(dtos)
        } catch {
            throw ValidationError("Failed to encode doctor JSON: \(error.localizedDescription)")
        }

        guard let str = String(data: data, encoding: .utf8) else {
            throw ValidationError("Failed to encode doctor JSON as UTF-8.")
        }

        print(str)
    }

    private func printText(_ reports: [ProviderReadiness]) {
        print("╭─────────────────────────────────────────╮")
        print("│             MeterBar Doctor             │")
        print("╰─────────────────────────────────────────╯")
        print()

        if reports.isEmpty {
            print("No matching providers.")
            return
        }

        for report in reports {
            print("▸ \(report.provider.displayName)  [\(report.overall.rawValue.uppercased())]")
            for check in report.checks {
                print("  \(symbol(for: check.level)) \(check.title): \(check.detail)")
                if let recovery = check.recovery {
                    print("      → \(recovery)")
                }
            }
            print()
        }

        let healthy = reports.filter { $0.isHealthy }.count
        let failing = reports.filter { $0.overall == .fail }.count
        let warning = reports.filter { $0.overall == .warn }.count
        print("Summary: \(healthy) healthy, \(failing) need attention, \(warning) with warnings.")
    }

    private func symbol(for level: ReadinessLevel) -> String {
        switch level {
        case .pass: return "✓"
        case .warn: return "⚠"
        case .fail: return "✗"
        }
    }
}

/// JSON shape for `meterbar doctor --json`: the report plus its rolled-up
/// `overall`/`healthy` (which are computed, so not part of the core's own
/// Codable form). Redacted upstream by `ProviderReadinessInspector`.
private struct DoctorReportDTO: Encodable {
    let provider: String
    let overall: String
    let healthy: Bool
    let checks: [ReadinessCheck]

    init(_ report: ProviderReadiness) {
        provider = report.provider.rawValue
        overall = report.overall.rawValue
        healthy = report.isHealthy
        checks = report.checks
    }
}
