import Foundation
import MeterBarShared
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared data store using App Groups for Widget extension access.
/// Public so the meterbar CLI reads the same file through the same code path
/// instead of maintaining its own copy of the location and decode logic.
/// `@unchecked Sendable`: all stored properties are immutable and disk writes
/// are serialized on `ioQueue`, so instances are safe to use from any actor.
nonisolated public final class SharedDataStore: @unchecked Sendable {
    public static let shared = SharedDataStore()

    /// Serial queue for off-main disk writes so callers on the MainActor don't
    /// block on file I/O, while still serializing writes to the shared file.
    private let ioQueue = DispatchQueue(label: "dev.meterbar.app.SharedDataStore.io", qos: .utility)

    /// Overrides the App Group container location. `nil` in production (the
    /// container is resolved via `SharedMetricsStore`); tests inject a temp
    /// directory so the encode → atomic-write → decode round-trip can run
    /// without the App Group entitlement (unavailable to `swift test`).
    private let directoryOverride: URL?

    /// Invoked after a successful write. Defaults to reloading the widget
    /// timelines; tests inject a spy to assert the write completed.
    private let didWrite: () -> Void

    /// Location (app-group id + file name) is single-sourced in MeterBarShared
    /// so the widget and CLI readers can't drift from this writer.
    private var metricsFileURL: URL? {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent("\(SharedMetricsStore.metricsKey).json")
        }
        return SharedMetricsStore.metricsFileURL
    }

    private var accountMetricsFileURL: URL? {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent("\(SharedMetricsStore.accountMetricsKey).json")
        }
        return SharedMetricsStore.accountMetricsFileURL
    }

    /// Defaults reproduce the production singleton exactly; tests inject a
    /// directory + write spy.
    init(directoryOverride: URL? = nil, didWrite: (() -> Void)? = nil) {
        self.directoryOverride = directoryOverride
        self.didWrite = didWrite ?? SharedDataStore.reloadWidgetTimelines
    }

    func saveMetrics(_ metrics: [ServiceType: UsageMetrics]) {
        guard let fileURL = metricsFileURL else {
            AppLog.storage.error("App Group container unavailable; enable App Groups for the app and widget targets.")
            return
        }

        guard let data = MetricsCodec.encode(metrics) else {
            AppLog.storage.error("Failed to encode shared metrics")
            return
        }

        // Write off the main thread (callers run on the MainActor). Atomic write
        // avoids a torn file if two saves race.
        ioQueue.async { [weak self] in
            do {
                try data.write(to: fileURL, options: [.atomic])
                self?.didWrite()
            } catch {
                AppLog.storage.error("Failed to save shared metrics: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func saveAccountMetrics(_ snapshots: [AccountUsageSnapshot]) {
        guard let fileURL = accountMetricsFileURL,
              let data = try? JSONEncoder().encode(snapshots) else {
            AppLog.storage.error("Failed to prepare shared account metrics")
            return
        }

        ioQueue.async { [weak self] in
            do {
                try data.write(to: fileURL, options: [.atomic])
                self?.didWrite()
            } catch {
                AppLog.storage.error(
                    "Failed to save shared account metrics: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Reads through the shared reader so the app, widget, and CLI decode the
    /// same file the same way. The test override reads the same file name from
    /// the injected directory.
    public func loadMetrics() -> [ServiceType: UsageMetrics] {
        guard directoryOverride == nil else {
            guard let fileURL = metricsFileURL,
                  let data = try? Data(contentsOf: fileURL) else { return [:] }
            return MetricsCodec.decode(data)
        }
        return SharedMetricsStore.loadMetrics()
    }

    public func loadAccountMetrics() -> [AccountUsageSnapshot] {
        guard directoryOverride == nil else {
            guard let fileURL = accountMetricsFileURL,
                  let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode([AccountUsageSnapshot].self, from: data) else { return [] }
            return decoded
        }
        return SharedMetricsStore.loadAccountMetrics()
    }

    /// Blocks until any in-flight async write has completed. Test-only: lets a
    /// test observe the on-disk result of `saveMetrics` deterministically.
    func flushPendingWrites() {
        ioQueue.sync {}
    }

    private static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        if #available(macOS 11.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: "UsageWidget")
        }
        #endif
    }
}
