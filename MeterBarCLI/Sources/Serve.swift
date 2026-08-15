import ArgumentParser
import Foundation
import MeterBar

/// `meterbar serve` — a local, token-gated, read-only HTTP view of the same
/// cached usage/cost data `meterbar usage --json` / `cost --json` emit. Never
/// triggers a provider refresh and never mutates state (docs/cli-json-schema.md).
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve usage and cost data over a local, token-gated, read-only HTTP endpoint"
    )

    static let defaultPort: UInt16 = 47_663
    static let defaultMaxRequestsPerSecond = 5

    @Option(help: "Port to listen on.")
    var port: UInt16 = Serve.defaultPort

    @Option(
        help: ArgumentHelp(
            "Bearer token required on every request. Visible via ps and shell history; "
                + "prefer --token-file or METERBAR_SERVE_TOKEN."
        )
    )
    var token: String?

    @Option(help: "Read the bearer token from this file, trimming trailing whitespace and newlines.")
    var tokenFile: String?

    @Flag(help: "Bind to all network interfaces instead of loopback only. Exposes usage/cost data to other devices.")
    var allowRemote: Bool = false

    @Option(help: "Maximum requests served per second before responding 429 Too Many Requests.")
    var maxRequestsPerSecond: Int = Serve.defaultMaxRequestsPerSecond

    func validate() throws {
        if maxRequestsPerSecond < 1 {
            throw ValidationError("--max-requests-per-second must be 1 or greater.")
        }
        if token != nil, tokenFile != nil {
            throw ValidationError("--token and --token-file cannot be used together.")
        }
        // `--token ""` survives the `??` below, so reject it here rather than
        // starting a server whose auth check can never reject anything. Omit
        // the flag entirely to get a generated token.
        if let token, !ServeToken.isUsable(token) {
            throw ValidationError("--token must not be blank. Omit it to have one generated.")
        }

        // Validate every external source before `run()` starts installing
        // signal handlers or constructing a server. The resolver is repeated
        // in `run()` because a token file can change between argument parsing
        // and startup; either pass reports a safe ArgumentParser error.
        do {
            _ = try resolveToken(generate: { "validation-placeholder" })
        } catch let error as ServeTokenResolutionError {
            throw ValidationError(Self.message(for: error))
        }
    }

    func run() async throws {
        let resolvedToken: ResolvedServeToken
        do {
            resolvedToken = try resolveToken(generate: ServeToken.generate)
        } catch let error as ServeTokenResolutionError {
            throw ValidationError(Self.message(for: error))
        }
        let bind = ServeBindConfiguration.resolve(allowRemote: allowRemote)

        if let warning = bind.warning {
            FileHandle.standardError.write(Data("⚠ \(warning)\n".utf8))
        }
        if resolvedToken.origin == .explicitArgument {
            FileHandle.standardError.write(
                Data(
                    (
                        "⚠ A token passed on the command line is visible to every local process via ps and is "
                            + "recorded in shell history. Prefer METERBAR_SERVE_TOKEN or --token-file.\n"
                    ).utf8
                )
            )
        }

        let cancellation = CLICancellationFlag()
        let signalSources = CLISignalHandlers.install(cancelling: cancellation)
        defer { signalSources.forEach { $0.cancel() } }

        let request = ServeCLI.Request(
            host: bind.host,
            port: port,
            token: resolvedToken.token,
            maxRequestsPerSecond: maxRequestsPerSecond
        )

        let outcome = await ServeCLI.run(
            request,
            dataSource: .liveCache,
            onReady: { info in
                print("meterbar serve listening on http://\(info.host):\(info.port)")
                print("Endpoints: GET /usage, GET /cost (Authorization: Bearer <token> required)")
                if resolvedToken.origin == .generated {
                    // Printed exactly once, at startup, and never logged again —
                    // this is the only place the token is ever surfaced.
                    print("Bearer token (generated, shown once): \(resolvedToken.token)")
                }
                print("Press Ctrl-C to stop.")
            },
            shouldCancel: { cancellation.isCancelled }
        )

        switch outcome {
        case .stopped:
            return
        case .failedToStart(let message):
            throw ValidationError("Failed to start meterbar serve: \(message)")
        }
    }

    private func resolveToken(generate: () -> String) throws -> ResolvedServeToken {
        try ServeTokenSource.resolve(
            explicitToken: token,
            tokenFilePath: tokenFile,
            environment: ProcessInfo.processInfo.environment,
            readFile: { path in
                try String(contentsOfFile: path, encoding: .utf8)
            },
            generate: generate
        )
    }

    private static func message(for error: ServeTokenResolutionError) -> String {
        switch error {
        case .blankExplicitArgument:
            return "--token must not be blank. Omit it to have one generated."
        case .unreadableTokenFile(let path):
            return "--token-file could not be read: \(path)"
        case .blankTokenFile(let path):
            return "--token-file must contain a non-blank token: \(path)"
        case .blankEnvironment:
            return "METERBAR_SERVE_TOKEN must not be blank. Unset it to have a token generated."
        }
    }
}
