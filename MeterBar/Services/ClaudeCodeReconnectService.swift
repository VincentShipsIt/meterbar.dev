import Foundation

// MARK: - ClaudeCodeReconnectService

enum ClaudeCodeReconnectService {
    /// How long a generated script may sit in the temporary directory before it
    /// is swept. Long enough that a Terminal window still working through a
    /// login flow keeps the file it is executing; short enough that scripts do
    /// not accumulate for the life of the machine.
    static let scriptRetention: TimeInterval = 24 * 60 * 60

    static func openReconnectTerminal(for account: ClaudeCodeAccount) throws {
        let scriptURL = try writeReconnectScript(for: account)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", scriptURL.path]

        do {
            try process.run()
        } catch {
            throw ClaudeCodeReconnectError.launchFailed(error.localizedDescription)
        }
    }

    static func reconnectScript(
        for account: ClaudeCodeAccount,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        let homeDirectory = shellQuoted(realHomeDirectory)
        let profileName = shellQuoted(account.name)
        let effectiveConfigDirectory = account.configDirectory ?? (account.isDefault
            ? ClaudeCodeAccount.defaultConfigDirectory(
                environment: environment,
                realHomeDirectory: realHomeDirectory
            )
            : nil)
        let configExport = if let configDirectory = effectiveConfigDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configDirectory.isEmpty {
            "export CLAUDE_CONFIG_DIR=\(shellQuoted(configDirectory))"
        } else {
            "unset CLAUDE_CONFIG_DIR"
        }

        return """
        #!/bin/zsh
        set -u

        export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin"
        export PATH="$PATH:$HOME/.yarn/bin:$HOME/.bun/bin:$HOME/.volta/bin"
        export HOME=\(homeDirectory)
        PROFILE_NAME=\(profileName)
        \(configExport)

        echo "Reconnect Claude Code profile: $PROFILE_NAME"
        if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
          echo "Using CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
        else
          echo "Using default Claude CLI profile"
        fi
        echo

        if ! command -v claude >/dev/null 2>&1; then
          echo "Claude CLI was not found on PATH."
          echo "Install it with: npm install -g @anthropic-ai/claude-code"
          echo
          read -r "?Press Return to close this window."
          exit 127
        fi

        echo "Logging out existing auth for this profile..."
        claude auth logout || true
        echo
        echo "Starting Claude login. Complete the browser flow when prompted."
        claude auth login
        status=$?
        echo

        if [ $status -eq 0 ]; then
          echo "Reconnect complete. Return to MeterBar and refresh Claude Code."
        else
          echo "Reconnect failed with exit code $status."
        fi

        echo
        read -r "?Press Return to close this window."
        exit $status
        """
    }

    /// The directory generated reconnect scripts are staged in.
    static func scriptsDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MeterBarClaudeReconnect", isDirectory: true)
    }

    /// Deletes reconnect scripts older than `retention`.
    ///
    /// The scripts are executable and carry the user's profile paths, so they
    /// should not outlive the reconnect they were generated for. Best-effort by
    /// design: a sweep that cannot read the directory is not a reason to fail
    /// the reconnect the user actually asked for.
    static func purgeReconnectScripts(
        in directory: URL = scriptsDirectory(),
        olderThan retention: TimeInterval = scriptRetention,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where entry.pathExtension == "command" {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > retention else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    static func writeReconnectScript(
        for account: ClaudeCodeAccount,
        in directory: URL = scriptsDirectory()
    ) throws -> URL {
        // Owner-only, and tightened even when an older build already created it
        // at the default 0755.
        try SecureFileWriter.ensurePrivateDirectory(directory)
        purgeReconnectScripts(in: directory)

        let scriptURL = directory.appendingPathComponent("reconnect-\(account.id.uuidString).command")
        // The script is executed by Terminal, so it must never be writable by
        // anyone else — not even for the instant a write-then-chmod would leave
        // it at the umask default.
        try SecureFileWriter.write(
            reconnectScript(for: account),
            to: scriptURL,
            permissions: SecureFileWriter.privateExecutable
        )
        return scriptURL
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

// MARK: - ClaudeCodeReconnectError

enum ClaudeCodeReconnectError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            "Could not open Terminal for Claude reconnect: \(message)"
        }
    }
}
