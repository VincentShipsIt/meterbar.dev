import Foundation
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared data store using App Groups for Widget extension access
class SharedDataStore {
    static let shared = SharedDataStore()
    
    private let appGroupIdentifier = "group.dev.shipshit.meterbar"
    private let metricsKey = "cached_usage_metrics"

    /// Serial queue for off-main disk writes so callers on the MainActor don't
    /// block on file I/O, while still serializing writes to the shared file.
    private let ioQueue = DispatchQueue(label: "dev.shipshit.meterbar.SharedDataStore.io", qos: .utility)

    private var containerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private init() {}

    func saveMetrics(_ metrics: [ServiceType: UsageMetrics]) {
        guard let containerURL = containerURL else {
            AppLog.storage.error("App Group container unavailable; enable App Groups for the app and widget targets.")
            return
        }

        let fileURL = containerURL.appendingPathComponent("\(metricsKey).json")

        let encoded = metrics.reduce(into: [String: UsageMetrics]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }

        guard let data = try? JSONEncoder().encode(encoded) else {
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
    
    func loadMetrics() -> [ServiceType: UsageMetrics] {
        guard let containerURL = containerURL else { return [:] }
        
        let fileURL = containerURL.appendingPathComponent("\(metricsKey).json")
        
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: UsageMetrics].self, from: data) else {
            return [:]
        }
        
        return decoded.reduce(into: [ServiceType: UsageMetrics]()) { result, pair in
            if let service = ServiceType(rawValue: pair.key) {
                result[service] = pair.value
            }
        }
    }

    private func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        if #available(macOS 11.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: "UsageWidget")
        }
        #endif
    }
}
