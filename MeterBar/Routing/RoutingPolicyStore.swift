import Foundation
import MeterBarShared

/// Reads and writes the routing-policy file in the shared App Group container.
///
/// A plain file, not `UserDefaults`, for the reason `UsageRefreshConfigurationStore`
/// documents: the bundled CLI has no App Group entitlement, so its
/// `UserDefaults` is a different domain from the app's. The app writes the
/// file; the CLI reads it.
///
/// Loading never throws and never fails closed to *nothing*: whatever is on
/// disk, the caller gets a usable catalog — the shipped defaults when the file
/// is absent, from a newer MeterBar, or unreadable — plus a notice saying so.
nonisolated enum RoutingPolicyStore {
    static let fileName = "routing-policies.json"

    struct Loaded: Equatable, Sendable {
        let catalog: RoutingPolicyCatalog
        /// Set when the file existed but could not be used, so a surface can
        /// say why the user's policies are not in effect.
        let notice: RoutingReason?
    }

    static func fileURL(directory: URL?) -> URL? {
        directory?.appendingPathComponent(fileName)
    }

    /// - Parameter persistMigration: rewrite the file in the current schema
    ///   after an upgrade. Off by default so a read-only caller such as
    ///   `meterbar route` never writes; the app passes `true`.
    static func load(
        directory: URL? = SharedMetricsStore.containerURL,
        codec: RoutingPolicyDocumentCodec = .standard,
        persistMigration: Bool = false
    ) -> Loaded {
        guard let url = fileURL(directory: directory),
              let data = try? Data(contentsOf: url) else {
            return Loaded(catalog: RoutingPolicyCatalog(), notice: nil)
        }

        switch codec.decode(data) {
        case let .document(document, migratedFrom):
            if migratedFrom != nil, persistMigration {
                try? save(document, directory: directory, codec: codec)
            }
            return Loaded(catalog: RoutingPolicyCatalog(document: document), notice: nil)
        case let .unsupportedVersion(version):
            // Left untouched on disk: a newer build may understand fields this
            // one would drop.
            return Loaded(
                catalog: RoutingPolicyCatalog(),
                notice: RoutingReason(
                    code: .policyUnsupportedVersion,
                    message: "Routing policies were saved by a newer MeterBar (schema \(version)); "
                        + "using defaults. Update MeterBar to use them."
                )
            )
        case .unreadable:
            return Loaded(
                catalog: RoutingPolicyCatalog(),
                notice: RoutingReason(
                    code: .policyUnreadable,
                    message: "Routing policies could not be read; using defaults."
                )
            )
        }
    }

    static func save(
        _ document: RoutingPolicyDocument,
        directory: URL? = SharedMetricsStore.containerURL,
        codec: RoutingPolicyDocumentCodec = .standard
    ) throws {
        guard let url = fileURL(directory: directory), let data = codec.encode(document) else { return }
        try SecureFileWriter.write(data, to: url)
    }
}
