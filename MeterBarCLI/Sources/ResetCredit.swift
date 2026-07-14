import ArgumentParser
import Foundation
import MeterBar

/// `meterbar reset-credit` — explicit CLI parity for the finite Codex action
/// shown on an exhausted popover card.
struct ResetCredit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset-credit",
        abstract: "Consume one banked Codex rate-limit reset credit"
    )

    @Option(name: .shortAndLong, help: "Provider to reset (currently only 'codex').")
    var provider: String = "codex"

    @Option(name: .long, help: "CODEX_HOME for a non-default Codex account.")
    var configDir: String?

    @Flag(name: .long, help: "Confirm spending one finite reset credit.")
    var yes: Bool = false

    func validate() throws {
        guard provider.lowercased() == "codex" else {
            throw ValidationError("--provider must be 'codex'.")
        }
        guard yes else {
            throw ValidationError("Reset credits are finite. Re-run with --yes to confirm consumption.")
        }
    }

    func run() async throws {
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
