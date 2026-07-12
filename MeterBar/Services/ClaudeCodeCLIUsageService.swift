import Foundation
import MeterBarShared

/// `nonisolated`: opts the whole class out of the app target's default
/// MainActor isolation — it owns no UI state and does blocking process I/O
/// that must stay off the main actor (bridged via `processQueue`).
nonisolated final class ClaudeCodeCLIUsageService: Sendable {
    static let shared = ClaudeCodeCLIUsageService()

    private let commandTimeout: TimeInterval = 12

    /// Dedicated queue for the blocking process run so the semaphore wait happens
    /// on a GCD thread rather than blocking a Swift-concurrency cooperative thread.
    private let processQueue = DispatchQueue(
        label: "dev.meterbar.app.ClaudeCLI.process",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    func isAvailable() -> Bool {
        resolveClaudeBinaryPath() != nil
    }

    func fetchUsageMetrics(account: ClaudeCodeAccount = .defaultAccount) async throws -> UsageMetrics {
        guard let binaryPath = resolveClaudeBinaryPath() else {
            throw ClaudeCodeCLIUsageError.cliNotFound
        }

        let output = try await runClaudeUsage(binaryPath: binaryPath, account: account)
        return try ClaudeCodeCLIUsageParser.parseMetrics(from: output)
    }

    private func resolveClaudeBinaryPath() -> String? {
        CLIBinaryLocator.resolve(command: "claude", overrideEnvVar: "CLAUDE_CLI_PATH")
    }

    /// Async wrapper that runs the blocking process invocation on `processQueue`
    /// and bridges the result back via a continuation, so the calling task
    /// suspends instead of blocking a cooperative thread on the semaphore.
    private func runClaudeUsage(binaryPath: String, account: ClaudeCodeAccount) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            processQueue.async {
                do {
                    let output = try self.runClaudeUsageBlocking(binaryPath: binaryPath, account: account)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runClaudeUsageBlocking(binaryPath: String, account: ClaudeCodeAccount) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["/usage"]
        process.environment = processEnvironment(account: account)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            throw ClaudeCodeCLIUsageError.launchFailed(error.localizedDescription)
        }

        if semaphore.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
            throw ClaudeCodeCLIUsageError.timedOut
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ClaudeCodeCLIUsageError.commandFailed(errorOutput.isEmpty ? output : errorOutput)
        }

        return output
    }

    /// Internal (not private) so tests can verify the spawned environment.
    func processEnvironment(
        account: ClaudeCodeAccount,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        // launchd's bare GUI PATH lacks the dirs the CLI's own runtime lives in
        // (e.g. node under /opt/homebrew/bin); without this the CLI prints a
        // cost summary instead of the usage screen and parsing fails.
        environment["PATH"] = CLIBinaryLocator.augmentedPATH(environment: base)
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = "dumb"
        if let configDirectory = account.configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configDirectory.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
        }
        return environment
    }
}

nonisolated enum ClaudeCodeCLIUsageParser {
    static func parseMetrics(from text: String, now: Date = Date()) throws -> UsageMetrics {
        let sanitized = stripANSICodes(from: text)
        let lines = sanitized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let sessionLimit = parseLimit(
            from: lines,
            labelPrefixes: ["current session"],
            windowMinutes: 5 * 60,
            now: now)
        let weeklyLimit = parseLimit(
            from: lines,
            labelPrefixes: ["current week (all models)", "current week"],
            windowMinutes: 7 * 24 * 60,
            now: now)
        // The CLI's model-specific window label has changed over time
        // ("Sonnet only" → "Fable", observed claude 2.1.205); match all knowns.
        let sonnetLimit = parseLimit(
            from: lines,
            labelPrefixes: ["current week (sonnet only)", "current week (fable)", "sonnet", "fable"],
            windowMinutes: 7 * 24 * 60,
            now: now)

        guard sessionLimit != nil || weeklyLimit != nil || sonnetLimit != nil else {
            throw ClaudeCodeCLIUsageError.parsingFailed("No Claude usage windows found.")
        }

        return UsageMetrics(
            service: .claudeCode,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            codeReviewLimit: sonnetLimit)
    }

    private static func parseLimit(
        from lines: [String],
        labelPrefixes: [String],
        windowMinutes: Int,
        now: Date) -> UsageLimit? {
        guard let line = lines.first(where: { line in
            let normalized = line.lowercased()
            return labelPrefixes.contains { normalized.hasPrefix($0) }
        }) else {
            return nil
        }

        guard let usage = parseUsagePercent(from: line) else {
            return nil
        }

        return UsageLimit(
            used: usage.usedPercent,
            total: 100,
            resetTime: parseResetDate(from: line, now: now),
            windowSeconds: TimeInterval(windowMinutes * 60))
    }

    private static func parseUsagePercent(from line: String) -> (usedPercent: Double, mode: String)? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*%\s*(used|remaining|left)?"#
        guard let match = firstMatch(pattern: pattern, in: line),
              let value = Double(match[1]) else {
            return nil
        }

        let mode = match[safe: 2]?.lowercased() ?? "used"
        let usedPercent = mode == "remaining" || mode == "left" ? 100 - value : value
        return (max(0, min(100, usedPercent)), mode)
    }

    private static func parseResetDate(from line: String, now: Date) -> Date? {
        let pattern = #"(?i)\breset(?:s)?\s+(.+)$"#
        guard let match = firstMatch(pattern: pattern, in: line),
              let rawReset = match[safe: 1] else {
            return nil
        }

        let cleaned = rawReset
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "am", with: "AM")
            .replacingOccurrences(of: "pm", with: "PM")

        guard !cleaned.isEmpty else {
            return nil
        }

        let year = Calendar.current.component(.year, from: now)
        let dateText = "\(year) \(cleaned)"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        for format in ["yyyy MMM d 'at' h:mma", "yyyy MMM d 'at' ha"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: dateText) {
                if parsed < now.addingTimeInterval(-24 * 60 * 60),
                   let adjusted = Calendar.current.date(byAdding: .year, value: 1, to: parsed) {
                    return adjusted
                }
                return parsed
            }
        }

        return nil
    }

    private static func stripANSICodes(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression)
    }

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }

        return (0..<match.numberOfRanges).map { index in
            let matchRange = match.range(at: index)
            guard let range = Range(matchRange, in: text) else {
                return ""
            }
            return String(text[range])
        }
    }
}

enum ClaudeCodeCLIUsageError: LocalizedError {
    case cliNotFound
    case launchFailed(String)
    case timedOut
    case commandFailed(String)
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Claude CLI is not installed or not on PATH."
        case let .launchFailed(message):
            return "Failed to launch Claude CLI: \(message)"
        case .timedOut:
            return "Claude CLI usage command timed out."
        case let .commandFailed(message):
            let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "Claude CLI usage command failed." : cleaned
        case let .parsingFailed(message):
            return "Could not parse Claude CLI usage: \(message)"
        }
    }
}

nonisolated private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
