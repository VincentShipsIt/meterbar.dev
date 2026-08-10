import Foundation

/// A caller-supplied `meterbar refresh` input that could not be used, shaped
/// like the guard failures in `docs/cli-json-schema.md` so both commands report
/// bad input the same machine-readable way.
nonisolated struct RefreshCLIFailure: Error, Equatable, Sendable {
    let code: String
    let message: String
    let flag: String?
    let value: String?
}

/// Resolves the raw `--timeout` text.
///
/// ArgumentParser's own `Double` conversion runs before `validate()` and before
/// `run()`, so typing the option as `Double` would answer a malformed value
/// with a usage message and `EX_USAGE` (64) — neither of which is in the
/// documented refresh contract, and neither of which is JSON. Parsing here
/// keeps every failure inside the versioned document and the stable exit codes.
/// `meterbar guard` resolves `--min-remaining` and `--refresh-timeout` the same
/// way for the same reason.
nonisolated enum RefreshTimeout {
    static func resolve(_ raw: String?) -> Result<TimeInterval, RefreshCLIFailure> {
        guard let raw else { return .success(UsageRefreshCLI.defaultTimeout) }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed),
              parsed.isFinite,
              (UsageRefreshCLI.minimumTimeout...UsageRefreshCLI.maximumTimeout).contains(parsed) else {
            return .failure(RefreshCLIFailure(
                code: "invalid_timeout",
                message: "Invalid --timeout value '\(trimmed)'. "
                    + "Expected \(QuotaGuardNumber.text(UsageRefreshCLI.minimumTimeout))"
                    + "...\(QuotaGuardNumber.text(UsageRefreshCLI.maximumTimeout)) seconds.",
                flag: "--timeout",
                value: trimmed
            ))
        }
        return .success(parsed)
    }
}
