import Foundation
import MeterBarShared

/// `nonisolated`: opts the whole class out of the app target's default
/// MainActor isolation — it owns no UI state and does blocking process I/O
/// that must stay off the main actor (bridged via `processQueue`).
nonisolated final class ClaudeCodeCLIUsageService: Sendable {
    static let shared = ClaudeCodeCLIUsageService()

    static let commandTimeout: TimeInterval = 12

    /// The usage screen is a few KB. This cap only bounds a pathological child;
    /// truncation keeps the leading bytes, which is exactly where the windows are.
    private static let maxCaptureBytes = 256 * 1024

    /// Dedicated queue for the blocking process run so the wait happens on a GCD
    /// thread rather than blocking a Swift-concurrency cooperative thread.
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

    func resolveClaudeBinaryPath() -> String? {
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

    /// Runs through `ManagedProcess` rather than Foundation `Process`: both
    /// streams are drained while the child runs, so a chatty CLI cannot fill a
    /// pipe buffer and hang, and the child is spawned into its own process group
    /// so a timeout kills the tree instead of orphaning `node` grandchildren.
    ///
    /// Internal (not private) so tests can drive the launch path with a fake
    /// binary and a short timeout.
    func runClaudeUsageBlocking(
        binaryPath: String,
        account: ClaudeCodeAccount,
        timeout: TimeInterval = ClaudeCodeCLIUsageService.commandTimeout
    ) throws -> String {
        let result = ManagedProcess.run(
            executable: binaryPath,
            arguments: ["/usage"],
            environment: processEnvironment(account: account),
            workingDirectory: ServiceSupport.realHomeDirectory(),
            timeout: timeout,
            maxCaptureBytes: Self.maxCaptureBytes
        )

        // Lossy decode (same rationale as WakeProcessRunner): a capture truncated
        // at the byte cap can split a multibyte character, and strict decoding
        // would drop the WHOLE capture — losing the leading usage screen that is
        // the only part we parse.
        // swiftlint:disable optional_data_string_conversion
        let output = String(decoding: result.stdoutCapture, as: UTF8.self)
        let errorOutput = String(decoding: result.stderrCapture, as: UTF8.self)
        // swiftlint:enable optional_data_string_conversion

        switch result.termination {
        case .exited(0):
            return output
        case let .exited(code):
            let detail = errorOutput.isEmpty ? output : errorOutput
            throw ClaudeCodeCLIUsageError.commandFailed(
                detail.isEmpty ? "Claude CLI exited with status \(code)." : detail
            )
        case let .signalled(signal):
            throw ClaudeCodeCLIUsageError.commandFailed("Claude CLI was terminated by signal \(signal).")
        case .timedOut:
            throw ClaudeCodeCLIUsageError.timedOut
        case .cancelled:
            // No cancellation handle is passed, so this is unreachable today;
            // an aborted run is indistinguishable from a timeout to the caller.
            throw ClaudeCodeCLIUsageError.timedOut
        case let .launchFailed(message):
            throw ClaudeCodeCLIUsageError.launchFailed(message)
        }
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
            // Expanded, not raw: the CLI gets this as a plain env var with no
            // shell to resolve `~`, and the credential resolver hashes the same
            // expanded path to find the profile's Keychain item.
            environment["CLAUDE_CONFIG_DIR"] = ClaudeCodeAccount.expandConfigDirectory(configDirectory)
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
        let modelWindow = parseModelLimit(from: lines, now: now)

        guard sessionLimit != nil || weeklyLimit != nil || modelWindow != nil else {
            // A headless (non-TTY) spawn of `claude /usage` renders a session
            // cost summary instead of the usage screen, so no windows parse.
            // Surface that specifically — the OAuth endpoint is the fix.
            if looksLikeCostSummary(sanitized) {
                throw ClaudeCodeCLIUsageError.parsingFailed(
                    "Claude CLI returned a session cost summary instead of the usage screen; "
                        + "`claude /usage` no longer renders headlessly. "
                        + "Connect Claude Code via its OAuth login in Settings.")
            }
            throw ClaudeCodeCLIUsageError.parsingFailed("No Claude usage windows found.")
        }

        return UsageMetrics(
            service: .claudeCode,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            codeReviewLimit: modelWindow?.limit,
            modelLimitLabel: modelWindow?.label)
    }

    private static func parseModelLimit(
        from lines: [String],
        now: Date
    ) -> (limit: UsageLimit, label: String)? {
        let definitions = [
            (label: "Fable", prefixes: ["current week (fable)", "fable"]),
            (label: "Sonnet", prefixes: ["current week (sonnet only)", "sonnet"]),
        ]
        for definition in definitions {
            if let limit = parseLimit(
                from: lines,
                labelPrefixes: definition.prefixes,
                windowMinutes: 7 * 24 * 60,
                now: now
            ) {
                return (limit, definition.label)
            }
        }
        return nil
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

    /// The session cost summary a headless `claude /usage` prints leads with a
    /// "Total cost:" line — a reliable, version-stable marker distinct from the
    /// usage screen's window labels.
    private static func looksLikeCostSummary(_ text: String) -> Bool {
        text.range(of: "total cost", options: .caseInsensitive) != nil
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
