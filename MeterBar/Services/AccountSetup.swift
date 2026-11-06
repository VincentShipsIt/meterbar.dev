import Foundation

// MARK: - AccountLoginProvider

/// The three CLIs that isolate accounts by directory. Each reads its profile
/// folder from its own environment variable and has its own login command.
nonisolated enum AccountLoginProvider: CaseIterable, Sendable {
    case claude
    case codex
    case grok

    var environmentVariable: String {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .grok: "GROK_HOME"
        }
    }

    /// The executable the generated script looks up on PATH.
    var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .grok: "grok"
        }
    }

    /// The vendor's own login invocation. Claude is intentionally absent from
    /// the generated scripts: it goes through `ClaudeCodeReconnectService`.
    var loginCommand: String {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        case .grok: "grok login"
        }
    }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    var installHint: String {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .grok: "see https://x.ai/cli"
        }
    }
}

// MARK: - AccountSetupError

nonisolated enum AccountSetupError: LocalizedError, Equatable {
    case notADirectory(String)
    case createFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .notADirectory(path):
            "\(path) is a file, not a folder."
        case let .createFailed(path, reason):
            "Could not create \(path): \(reason)"
        }
    }
}

// MARK: - AccountSetupOutcome

nonisolated struct AccountSetupOutcome: Equatable, Sendable {
    /// The folder the account was added with, `~` expanded.
    let directory: String
    let createdDirectory: Bool
    /// Why the login could not be started. The account is kept regardless.
    let loginFailure: String?
}

// MARK: - AccountSetup

/// "Name it and go" account setup (#680): create the profile folder, add the
/// account, then start that provider's own CLI login scoped to the folder.
///
/// MeterBar never reads or writes the login itself. The vendor CLI does, in a
/// Terminal window, exactly as it does for a hand-made profile.
enum AccountSetup {
    // MARK: Flow

    /// - Throws: `AccountSetupError` when the folder cannot be prepared. Nothing
    ///   has been added in that case.
    ///
    /// A login that cannot be started does not throw: the account is already
    /// added and stays, reported through `loginFailure`, so it shows as needing
    /// sign-in and the user retries from its row rather than re-adding it.
    static func perform(
        path: String,
        startsLogin: Bool,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory(),
        addAccount: (String) -> Void,
        launchLogin: (String) throws -> Void
    ) throws -> AccountSetupOutcome {
        let directory = ServiceSupport.expandUserPath(path, realHomeDirectory: realHomeDirectory)
        let created = try prepareDirectory(directory)
        addAccount(directory)

        var failure: String?
        if startsLogin {
            do {
                try launchLogin(directory)
            } catch {
                failure = error.localizedDescription
            }
        }
        return AccountSetupOutcome(directory: directory, createdDirectory: created, loginFailure: failure)
    }

    // MARK: Folder

    /// `~/.claude-work`, `~/.codex-work`, `~/.grok-work` for an account named
    /// "Work". Never returns a folder that already exists, so a default cannot
    /// silently adopt somebody else's profile.
    static func defaultDirectory(
        for provider: AccountLoginProvider,
        accountName: String,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String {
        let base = (realHomeDirectory as NSString)
            .appendingPathComponent(".\(provider.executable)-\(slug(accountName))")
        var candidate = base
        var suffix = 2
        while fileManager.fileExists(atPath: candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Creates `path` owner-only when it is missing and reports whether it did.
    ///
    /// An existing folder is left exactly as it is, mode included: it is a
    /// profile the user set up by hand and may be shared with other tooling.
    /// Missing parents are created owner-only too, one level at a time, so the
    /// result does not depend on how Foundation applies attributes to
    /// intermediate directories.
    @discardableResult
    static func prepareDirectory(_ path: String, fileManager: FileManager = .default) throws -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw AccountSetupError.notADirectory(path) }
            return false
        }

        var missing: [String] = []
        var cursor = path
        while !fileManager.fileExists(atPath: cursor), cursor != "/", !cursor.isEmpty {
            missing.append(cursor)
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        for directory in missing.reversed() {
            do {
                try fileManager.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: SecureFileWriter.privateDirectory]
                )
            } catch {
                throw AccountSetupError.createFailed(path: directory, reason: error.localizedDescription)
            }
        }
        return true
    }

    // MARK: Login (Codex, Grok)

    /// Claude uses `ClaudeCodeReconnectService`; this covers the two CLIs it
    /// does not. `codex login` and `grok login` read the scoped variable.
    static func loginScript(
        for provider: AccountLoginProvider,
        profileName: String,
        directory: String,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        let executable = provider.executable
        return """
        #!/bin/zsh
        set -u

        export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin"
        export PATH="$PATH:$HOME/.yarn/bin:$HOME/.bun/bin:$HOME/.volta/bin"
        export HOME=\(ClaudeCodeReconnectService.shellQuoted(realHomeDirectory))
        PROFILE_NAME=\(ClaudeCodeReconnectService.shellQuoted(profileName))
        export \(provider.environmentVariable)=\(ClaudeCodeReconnectService.shellQuoted(directory))

        echo "Sign in to \(provider.displayName) profile: $PROFILE_NAME"
        echo "Using \(provider.environmentVariable)=$\(provider.environmentVariable)"
        echo

        if ! command -v \(executable) >/dev/null 2>&1; then
          echo "\(provider.displayName) CLI was not found on PATH."
          echo "Install it: \(provider.installHint)"
          echo
          read -r "?Press Return to close this window."
          exit 127
        fi

        \(provider.loginCommand)
        status=$?
        echo

        if [ $status -eq 0 ]; then
          echo "Sign-in complete. Return to MeterBar and refresh \(provider.displayName)."
        else
          echo "Sign-in failed with exit code $status. Use Check Again in MeterBar to retry."
        fi

        echo
        read -r "?Press Return to close this window."
        exit $status
        """
    }

    /// Stages the script next to the Claude reconnect scripts so the same
    /// launch-time sweep removes it.
    static func writeLoginScript(
        for provider: AccountLoginProvider,
        profileName: String,
        directory: String,
        in scriptsDirectory: URL = ClaudeCodeReconnectService.scriptsDirectory()
    ) throws -> URL {
        try SecureFileWriter.ensurePrivateDirectory(scriptsDirectory)
        ClaudeCodeReconnectService.purgeReconnectScripts(in: scriptsDirectory)

        let scriptURL = scriptsDirectory
            .appendingPathComponent("login-\(provider.executable)-\(UUID().uuidString).command")
        try SecureFileWriter.write(
            loginScript(for: provider, profileName: profileName, directory: directory),
            to: scriptURL,
            permissions: SecureFileWriter.privateExecutable
        )
        return scriptURL
    }

    static func openLoginTerminal(
        for provider: AccountLoginProvider,
        profileName: String,
        directory: String
    ) throws {
        let scriptURL = try writeLoginScript(for: provider, profileName: profileName, directory: directory)
        try ClaudeCodeReconnectService.openInTerminal(scriptURL)
    }

    // MARK: Private

    /// Lowercase ASCII letters and digits joined by single dashes.
    private static func slug(_ name: String) -> String {
        var parts: [String] = []
        var current = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.isEmpty ? "account" : parts.joined(separator: "-")
    }
}
