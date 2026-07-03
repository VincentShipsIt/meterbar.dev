import Foundation
import MeterBarShared
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared data store using App Groups for Widget extension access.
/// Public so the meterbar CLI reads the same file through the same code path
/// instead of maintaining its own copy of the location and decode logic.
public class SharedDataStore {
    public static let shared = SharedDataStore()

    /// Serial queue for off-main disk writes so callers on the MainActor don't
    /// block on file I/O, while still serializing writes to the shared file.
    private let ioQueue = DispatchQueue(label: "dev.shipshit.meterbar.SharedDataStore.io", qos: .utility)

    private init() {}

    func saveMetrics(_ metrics: [ServiceType: UsageMetrics]) {
        // Location (app-group id + file name) is single-sourced in MeterBarShared
        // so the widget and CLI readers can't drift from this writer.
        guard let fileURL = SharedMetricsStore.metricsFileURL else {
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
                self?.reloadWidgetTimelines()
            } catch {
                AppLog.storage.error("Failed to save shared metrics: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reads through the shared reader so the app, widget, and CLI decode the
    /// same file the same way.
    public func loadMetrics() -> [ServiceType: UsageMetrics] {
        SharedMetricsStore.loadMetrics()
    }

    private func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        if #available(macOS 11.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: "UsageWidget")
        }
        #endif
    }
}
