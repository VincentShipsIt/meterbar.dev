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
    typealias Writer = (Data, URL) throws -> Void

    enum PersistenceError: LocalizedError, Equatable {
        case containerUnavailable
        case encodingFailed
        case existingFileUnreadable
        case unsupportedVersion(Int)
        case writeFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .containerUnavailable:
                "Routing policy storage is unavailable. Open MeterBar and try again."
            case .encodingFailed:
                "Routing policies could not be encoded."
            case .existingFileUnreadable:
                "Routing policies could not be read; the existing file was not changed."
            case let .unsupportedVersion(version):
                "Routing policies use a newer schema (\(version)); update MeterBar before saving."
            case let .writeFailed(reason):
                "Routing policies could not be saved (\(reason))."
            }
        }
    }

    struct Loaded: Equatable, Sendable {
        let catalog: RoutingPolicyCatalog
        /// Explains unusable policies or a failed migration write. A failed
        /// write keeps the decoded catalog usable without claiming persistence.
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
        persistMigration: Bool = false,
        writer: Writer = { try SecureFileWriter.write($0, to: $1) }
    ) -> Loaded {
        guard let url = fileURL(directory: directory) else {
            return Loaded(catalog: RoutingPolicyCatalog(), notice: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Only a missing file is normal. A dangling symlink or an existing
            // unreadable entry must not silently remove the user's constraints.
            return isConfirmedMissing(url, after: error)
                ? Loaded(catalog: RoutingPolicyCatalog(), notice: nil)
                : unreadable()
        }

        switch codec.decode(data) {
        case let .document(document, migratedFrom):
            if migratedFrom != nil, persistMigration {
                do {
                    try save(document, directory: directory, codec: codec, writer: writer)
                } catch {
                    return Loaded(
                        catalog: RoutingPolicyCatalog(document: document),
                        notice: RoutingReason(
                            code: .policyMigrationFailed,
                            message: "Routing policy upgrade could not be saved; "
                                + "using upgraded policies for this session. The original file is unchanged."
                        )
                    )
                }
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
            return unreadable()
        }
    }

    static func save(
        _ document: RoutingPolicyDocument,
        directory: URL? = SharedMetricsStore.containerURL,
        codec: RoutingPolicyDocumentCodec = .standard,
        encoder: ((RoutingPolicyDocument) -> Data?)? = nil,
        writer: Writer = { try SecureFileWriter.write($0, to: $1) }
    ) throws {
        guard let url = fileURL(directory: directory) else {
            throw PersistenceError.containerUnavailable
        }
        guard let data = (encoder ?? codec.encode)(document) else {
            throw PersistenceError.encodingFailed
        }
        let existing: Data?
        do {
            existing = try Data(contentsOf: url)
        } catch {
            guard isConfirmedMissing(url, after: error) else {
                throw PersistenceError.existingFileUnreadable
            }
            existing = nil
        }
        if let existing, case let .unsupportedVersion(version) = codec.decode(existing) {
            throw PersistenceError.unsupportedVersion(version)
        }
        do {
            try writer(data, url)
        } catch {
            throw PersistenceError.writeFailed(reason: SecureFileWriterError.logDescription(for: error))
        }
    }

    private static func isConfirmedMissing(_ url: URL, after error: Error) -> Bool {
        let readError = error as NSError
        guard readError.domain == NSCocoaErrorDomain,
              readError.code == NSFileReadNoSuchFileError else {
            return false
        }
        do {
            // Attributes inspect the directory entry itself, including a
            // dangling symlink, rather than only following its target.
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch {
            let entryError = error as NSError
            return entryError.domain == NSCocoaErrorDomain
                && (entryError.code == NSFileNoSuchFileError || entryError.code == NSFileReadNoSuchFileError)
        }
    }

    private static func unreadable() -> Loaded {
        Loaded(
            catalog: RoutingPolicyCatalog(),
            notice: RoutingReason(
                code: .policyUnreadable,
                message: "Routing policies could not be read; using defaults."
            )
        )
    }
}
