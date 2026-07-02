import ArgumentParser
import Darwin
import Foundation
import MeterBarShared

@main
struct MeterBarCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meterbar",
        abstract: "Track AI coding assistant usage from the command line",
        version: MeterBarCLIVersion.current,
        subcommands: [Usage.self, Cost.self],
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

    @Option(name: .shortAndLong, help: "Filter by provider (claude, openai, cursor, codex)")
    var provider: String?

    func run() throws {
        let metrics = loadCachedMetrics()

        if metrics.isEmpty {
            if json {
                print("{\"error\": \"No cached metrics found. Open MeterBar app to fetch data.\"}")
            } else {
                print("No cached metrics found.")
                print("Open MeterBar app to fetch usage data first.")
            }
            return
        }

        let filtered: [String: UsageMetrics]
        if let provider = provider?.lowercased() {
            filtered = metrics.filter { $0.key.lowercased().contains(provider) }
        } else {
            filtered = metrics
        }

        if json {
            printJSON(filtered)
        } else {
            printText(filtered)
        }
    }

    private func loadCachedMetrics() -> [String: UsageMetrics] {
        // Try app group container first
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.shipshit.meterbar"
        )

        var metricsPath: URL?

        if let containerURL = containerURL {
            metricsPath = containerURL.appendingPathComponent("cached_usage_metrics.json")
        }

        // Fallback to UserDefaults cache
        if metricsPath == nil || !FileManager.default.fileExists(atPath: metricsPath!.path) {
            if let data = UserDefaults.standard.data(forKey: "cached_usage_metrics"),
               let decoded = try? JSONDecoder().decode([String: UsageMetrics].self, from: data) {
                return decoded
            }
            return [:]
        }

        guard let path = metricsPath,
              let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode([String: UsageMetrics].self, from: data) else {
            return [:]
        }

        return decoded
    }

    private func printJSON(_ metrics: [String: UsageMetrics]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(metrics),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private func printText(_ metrics: [String: UsageMetrics]) {
        print("╭─────────────────────────────────────────╮")
        print("│             MeterBar Usage              │")
        print("╰─────────────────────────────────────────╯")
        print()

        for (service, metric) in metrics.sorted(by: { $0.key < $1.key }) {
            let displayName = ServiceType(rawValue: service)?.displayName
                ?? service.replacingOccurrences(of: "_", with: " ").capitalized
            print("▸ \(displayName)")

            if let session = metric.sessionLimit {
                printLimit("  Session", session)
            }
            if let weekly = metric.weeklyLimit {
                printLimit("  Weekly", weekly)
            }
            if let codeReview = metric.codeReviewLimit {
                printLimit("  Code Review", codeReview)
            }
            print()
        }
    }

    private func printLimit(_ label: String, _ limit: UsageLimit) {
        let percent = limit.percentage
        let bar = progressBar(percent: percent, width: 20)
        let status = statusEmoji(percent: percent)

        print("\(label): \(bar) \(String(format: "%.0f%%", percent)) \(status)")
        print("    \(Int(limit.used))/\(Int(limit.total)) used")
        if let reset = limit.resetTime {
            print("    Resets: \(formatDate(reset))")
        }
    }

    private func progressBar(percent: Double, width: Int) -> String {
        let filled = Int((percent / 100) * Double(width))
        let empty = width - filled
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    private func statusEmoji(percent: Double) -> String {
        if percent < 50 { return "✓" }
        if percent < 80 { return "⚠" }
        return "✗"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct Cost: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show token costs from local sessions"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Number of days to scan (default: 30)")
    var days: Int = 30

    func run() throws {
        let costs = scanClaudeCosts(days: days)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(costs),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            printCosts(costs)
        }
    }

    private func scanClaudeCosts(days: Int) -> CostResult {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var sessionCount = 0

        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            return CostResult(provider: "claude_code", inputTokens: 0, outputTokens: 0,
                            cacheCreationTokens: 0, cacheReadTokens: 0, estimatedCostUSD: 0,
                            sessionCount: 0, periodDays: days)
        }

        do {
            let projectDirs = try FileManager.default.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil)

            for projectDir in projectDirs {
                let jsonlFiles = (try? FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)) ?? []

                for jsonlFile in jsonlFiles where jsonlFile.pathExtension == "jsonl" {
                    let attrs = try? jsonlFile.resourceValues(forKeys: [.contentModificationDateKey])
                    guard let modDate = attrs?.contentModificationDate, modDate >= cutoffDate else { continue }

                    if let data = try? Data(contentsOf: jsonlFile),
                       let content = String(data: data, encoding: .utf8) {
                        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
                            if let lineData = line.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                               let message = json["message"] as? [String: Any],
                               let usage = message["usage"] as? [String: Any] {
                                totalInput += usage["input_tokens"] as? Int ?? 0
                                totalOutput += usage["output_tokens"] as? Int ?? 0
                                totalCacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
                                totalCacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
                            }
                        }
                        sessionCount += 1
                    }
                }
            }
        } catch {
            // Ignore errors
        }

        // Calculate cost (Sonnet pricing)
        let inputCost = Double(totalInput) / 1_000_000 * 3.0
        let outputCost = Double(totalOutput) / 1_000_000 * 15.0
        let cacheCreationCost = Double(totalCacheCreation) / 1_000_000 * 3.75
        let cacheReadCost = Double(totalCacheRead) / 1_000_000 * 0.30
        let totalCost = inputCost + outputCost + cacheCreationCost + cacheReadCost

        return CostResult(
            provider: "claude_code",
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: totalCacheCreation,
            cacheReadTokens: totalCacheRead,
            estimatedCostUSD: totalCost,
            sessionCount: sessionCount,
            periodDays: days
        )
    }

    private func printCosts(_ costs: CostResult) {
        print("╭─────────────────────────────────────────╮")
        print("│          MeterBar Cost Tracker          │")
        print("╰─────────────────────────────────────────╯")
        print()
        print("Provider: Claude Code")
        print("Period: Last \(costs.periodDays) days")
        print("Files scanned: \(costs.sessionCount)")
        print()
        print("Tokens:")
        print("  Input:          \(formatNumber(costs.inputTokens))")
        print("  Output:         \(formatNumber(costs.outputTokens))")
        print("  Cache Creation: \(formatNumber(costs.cacheCreationTokens))")
        print("  Cache Read:     \(formatNumber(costs.cacheReadTokens))")
        print()
        print("Estimated Cost: $\(String(format: "%.2f", costs.estimatedCostUSD))")
        print("Daily Average:  $\(String(format: "%.2f", costs.estimatedCostUSD / Double(costs.periodDays)))/day")
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formatNumber(_ num: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}

// MARK: - Models

struct CostResult: Codable {
    let provider: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
    let sessionCount: Int
    let periodDays: Int
}
