import ArgumentParser
import Foundation
import MeterBar

/// `meterbar reset-credit` — explicit CLI parity for the finite Codex action
/// shown on an exhausted popover card.
struct ResetCredit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset-credit",
        abstract: "Consume one banked Codex or Grok rate-limit reset credit"
    )

    @Option(name: .shortAndLong, help: "Provider to reset ('codex' or 'grok').")
    var provider: String = "codex"

    @Option(name: .long, help: "CODEX_HOME or GROK_HOME for a non-default account.")
    var configDir: String?

    @Flag(name: .long, help: "Confirm spending one finite reset credit.")
    var yes: Bool = false

    func validate() throws {
        let token = provider.lowercased()
        guard token == "codex" || token == "grok" else {
            throw ValidationError("--provider must be 'codex' or 'grok'.")
        }
        guard yes else {
            throw ValidationError("Reset credits are finite. Re-run with --yes to confirm consumption.")
        }
    }

    func run() async throws {
        if provider.lowercased() == "grok" {
            let result = try await GrokResetCreditAPI.consume(grokHome: configDir)
            print("Used one Grok usage reset.")
            if let refreshError = result.usageRefreshErrorDescription {
                var stderr = ResetCreditStandardError()
                Swift.print(
                    "The credit was used, but usage refresh failed (\(refreshError)). Do not retry; refresh later.",
                    to: &stderr
                )
            }
            return
        }

        let result = try await CodexResetCreditAPI.consume(codexHome: configDir)
        print("Used one Codex reset credit; reset \(result.windowsReset) usage window(s).")
        if let refreshError = result.usageRefreshErrorDescription {
            var stderr = ResetCreditStandardError()
            Swift.print(
                "The credit was used, but usage refresh failed (\(refreshError)). Do not retry; refresh later.",
                to: &stderr
            )
        }
    }
}

private struct ResetCreditStandardError: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
