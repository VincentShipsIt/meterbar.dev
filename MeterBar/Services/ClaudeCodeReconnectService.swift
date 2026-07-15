import Foundation

// MARK: - ClaudeCodeReconnectService

enum ClaudeCodeReconnectService {
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

    private static func writeReconnectScript(for account: ClaudeCodeAccount) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MeterBarClaudeReconnect", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scriptURL = directory.appendingPathComponent("reconnect-\(account.id.uuidString).command")
        try reconnectScript(for: account).write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
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
