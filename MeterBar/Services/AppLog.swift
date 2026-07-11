import Foundation
import os

/// Centralized logging for the app.
///
/// Replaces scattered stdout printing (flagged by the `no_print_statements`
/// SwiftLint rule) with the unified logging system. Using `Logger` keeps diagnostics
/// out of release stdout, lets the OS apply privacy redaction, and avoids logging
/// raw API response bodies or token-bearing strings to the console.
nonisolated enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.meterbar.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let usage = Logger(subsystem: subsystem, category: "usage")
    static let cost = Logger(subsystem: subsystem, category: "cost")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let wake = Logger(subsystem: subsystem, category: "wake")
}
