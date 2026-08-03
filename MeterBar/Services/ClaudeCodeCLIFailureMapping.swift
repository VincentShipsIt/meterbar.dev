import Foundation

/// Translates `ClaudeCodeCLIUsageError` into the two app-level vocabularies the
/// UI reads: `ServiceError` (what Settings prints) and `ClaudeCodeAuthState`
/// (whether the user is told to act or to retry).
///
/// This lived as two private methods on `ClaudeCodeLocalService`, which meant
/// the only way to check that a CLI failure reached the user intact was to run
/// the CLI. Pulling the switches out keeps them assertable without a subprocess.
enum ClaudeCodeCLIFailureMapping {
    static func serviceError(from error: Error) -> ServiceError {
        if let serviceError = error as? ServiceError {
            return serviceError
        }

        guard let cliError = error as? ClaudeCodeCLIUsageError else {
            return .apiError(error.localizedDescription)
        }

        switch cliError {
        case .cliNotFound:
            return .notAuthenticated
        case let .parsingFailed(message):
            // Only messages MeterBar authored survive; anything else could be
            // CLI output and stays behind the generic string.
            return .parsingError(ClaudeCodeParseFailure(message: message)?.message)
        case .timedOut, .launchFailed, .commandFailed:
            return .apiError(cliError.localizedDescription)
        }
    }

    static func authState(from error: Error) -> ClaudeCodeAuthState {
        guard let cliError = error as? ClaudeCodeCLIUsageError else {
            return .error(error.localizedDescription)
        }

        switch cliError {
        case .cliNotFound:
            return .unavailable
        case let .commandFailed(message):
            let lowercased = message.lowercased()
            if lowercased.contains("login") || lowercased.contains("auth") || lowercased.contains("unauthorized") {
                return .needsLogin
            }
            return .error(cliError.localizedDescription)
        case let .parsingFailed(message):
            // A CLI that cannot render `/usage` headlessly will fail every
            // future refresh too, so "needs attention" understates it — the user
            // has to connect OAuth before anything changes.
            if ClaudeCodeParseFailure(message: message) == .headlessUsageUnavailable {
                return .needsLogin
            }
            return .error(cliError.localizedDescription)
        case .timedOut, .launchFailed:
            return .error(cliError.localizedDescription)
        }
    }
}
