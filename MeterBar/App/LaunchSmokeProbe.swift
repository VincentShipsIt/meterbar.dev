import Foundation

/// The `--launch-smoke` probe that proves a signed bundle can actually start.
///
/// `codesign --verify --deep --strict` only inspects signatures sitting on disk.
/// It says nothing about whether dyld will map the app's embedded frameworks
/// into the process, so a bundle can verify perfectly and still die before
/// `main()` — which is exactly what an ad-hoc bundle signed with hardened
/// runtime does, because library validation refuses to map an ad-hoc framework
/// (no Team ID) into an ad-hoc process. Running the real executable is the only
/// check that covers that gap.
///
/// The probe therefore answers before AppKit starts: one versioned JSON document
/// on stdout, then exit. dyld has already resolved and validated every linked
/// library by the time this runs, so reaching the output at all is the proof.
/// Nothing is initialized, no window server is needed, and no network or disk
/// state is touched — the same reasons `meterbar wake --dry-run` is safe to run
/// from the release gate.
nonisolated enum LaunchSmokeProbe {
    /// Exact argument that requests the probe. Launch Services never passes it.
    static let flag = "--launch-smoke"

    enum ProbeError: Error, Equatable {
        /// The bundle's `Info.plist` lacks a key the release gate cross-checks.
        case missingBundleMetadata(key: String)
        case invalidUTF8
    }

    private struct Response: Encodable {
        let schemaVersion = 1
        let launchSmoke = true
        let bundleIdentifier: String
        let shortVersion: String
        let buildVersion: String
    }

    static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains(flag)
    }

    /// One compact, key-sorted JSON line describing the bundle that just booted.
    ///
    /// Versions come from the running process's own `Info.plist`, which lets the
    /// release verifier confirm the bundle it signed is the bundle that ran.
    static func responseJSON(info: [String: Any]) throws -> String {
        let response = Response(
            bundleIdentifier: try requireString(info, "CFBundleIdentifier"),
            shortVersion: try requireString(info, "CFBundleShortVersionString"),
            buildVersion: try requireString(info, "CFBundleVersion")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let json = String(data: try encoder.encode(response), encoding: .utf8) else {
            throw ProbeError.invalidUTF8
        }
        return json
    }

    /// Answers the probe and exits, or returns so the app starts normally.
    ///
    /// Called as the very first thing in `main()`, ahead of every singleton and
    /// SwiftUI itself, so a probe run can never leave state behind.
    static func exitIfRequested(
        arguments: [String] = CommandLine.arguments,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        guard isRequested(in: arguments) else { return }

        do {
            FileHandle.standardOutput.write(Data((try responseJSON(info: info) + "\n").utf8))
            exit(0)
        } catch {
            // Failing loudly matters more than launching: a bundle that cannot
            // describe itself must not report a successful launch smoke.
            FileHandle.standardError.write(Data("MeterBar launch smoke failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func requireString(_ info: [String: Any], _ key: String) throws -> String {
        guard let value = info[key] as? String, !value.isEmpty else {
            throw ProbeError.missingBundleMetadata(key: key)
        }
        return value
    }
}
