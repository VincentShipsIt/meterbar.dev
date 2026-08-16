import Combine
import Foundation
import MeterBarShared
import os

/// Persisted fetch/parse health for one reverse-engineered provider integration.
nonisolated public struct ProviderParseHealthRecord: Codable, Equatable, Sendable {
    static let staleAfter: TimeInterval = 2 * 60 * 60
    static let sustainedFailureCount = 3
    /// Genuine schema drift fails on every refresh, so two consecutive
    /// mismatches are the earliest reliable drift signal; a single decode
    /// failure can be a truncated body from a flaky connection.
    static let sustainedShapeMismatchCount = 2

    public let provider: ServiceType
    public let lastSuccess: Date?
    public let lastAttempt: Date
    public let consecutiveFailures: Int
    public let lastFailureWasShapeMismatch: Bool
    public let consecutiveShapeMismatches: Int

    public init(
        provider: ServiceType,
        lastSuccess: Date?,
        lastAttempt: Date,
        consecutiveFailures: Int,
        lastFailureWasShapeMismatch: Bool,
        consecutiveShapeMismatches: Int = 0
    ) {
        self.provider = provider
        self.lastSuccess = lastSuccess
        self.lastAttempt = lastAttempt
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureWasShapeMismatch = lastFailureWasShapeMismatch
        self.consecutiveShapeMismatches = consecutiveShapeMismatches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ServiceType.self, forKey: .provider)
        lastSuccess = try container.decodeIfPresent(Date.self, forKey: .lastSuccess)
        lastAttempt = try container.decode(Date.self, forKey: .lastAttempt)
        consecutiveFailures = try container.decode(Int.self, forKey: .consecutiveFailures)
        lastFailureWasShapeMismatch = try container.decode(Bool.self, forKey: .lastFailureWasShapeMismatch)
        // Records persisted before this field existed used a one-shot
        // mismatch flag; carry that meaning forward conservatively.
        consecutiveShapeMismatches = try container.decodeIfPresent(Int.self, forKey: .consecutiveShapeMismatches)
            ?? (lastFailureWasShapeMismatch ? Self.sustainedShapeMismatchCount : 0)
    }

    static func success(provider: ServiceType = .claudeCode, at date: Date) -> Self {
        Self(
            provider: provider,
            lastSuccess: date,
            lastAttempt: date,
            consecutiveFailures: 0,
            lastFailureWasShapeMismatch: false,
            consecutiveShapeMismatches: 0
        )
    }

    /// Sustained transport failures or consecutive shape mismatches. Does not
    /// include an aged `lastSuccess` — that is staleness, not attention.
    var isSustainedOrParseFailure: Bool {
        consecutiveShapeMismatches >= Self.sustainedShapeMismatchCount
            || consecutiveFailures >= Self.sustainedFailureCount
    }

    func needsAttention(now: Date = Date()) -> Bool {
        if isSustainedOrParseFailure { return true }
        guard let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) > Self.staleAfter
    }
}

/// Records provider outcomes in preferences for app observers and mirrors them
/// to an explicit App Group file so the bundled `meterbar doctor` process reads
/// the same diagnostic state.
final class ProviderParseHealthStore: ObservableObject {
    static let shared = ProviderParseHealthStore()
    nonisolated static let storageKey = "ProviderParseHealthV1"

    @Published private(set) var records: [ServiceType: ProviderParseHealthRecord]

    private let userDefaults: UserDefaults
    private let sharedFileURL: URL?
    private let ioQueue = DispatchQueue(label: "dev.meterbar.app.ProviderParseHealthStore.io", qos: .utility)

    init(userDefaults: UserDefaults? = nil, sharedDirectoryOverride: URL? = nil) {
        let usesProductionStore = userDefaults == nil && sharedDirectoryOverride == nil
        let resolved = userDefaults
            ?? UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier)
            ?? .standard
        self.userDefaults = resolved
        if let sharedDirectoryOverride {
            sharedFileURL = sharedDirectoryOverride
                .appendingPathComponent("\(SharedMetricsStore.parseHealthKey).json")
        } else {
            sharedFileURL = usesProductionStore ? SharedMetricsStore.parseHealthFileURL : nil
        }

        let sharedRecords = Self.loadRecords(from: sharedFileURL)
        records = sharedRecords ?? Self.persistedRecords(from: resolved)

        // Migrate the App Group preference-domain record to an explicit shared
        // file. An unentitled bundled CLI can read the App Group container but
        // `UserDefaults(suiteName:)` resolves its ordinary preferences domain,
        // so the file is the only cross-process source that both targets share.
        if sharedRecords == nil, !records.isEmpty {
            persistSharedFile(records)
        }
    }

    func recordSuccess(_ provider: ServiceType, at date: Date = Date()) {
        records[provider] = .success(provider: provider, at: date)
        persist()
    }

    func recordFailure(_ provider: ServiceType, error: Error, at date: Date = Date()) {
        let previous = records[provider]
        let isShapeMismatch = Self.isShapeMismatch(error)
        records[provider] = ProviderParseHealthRecord(
            provider: provider,
            lastSuccess: previous?.lastSuccess,
            lastAttempt: date,
            consecutiveFailures: (previous?.consecutiveFailures ?? 0) + 1,
            lastFailureWasShapeMismatch: isShapeMismatch,
            consecutiveShapeMismatches: isShapeMismatch
                ? (previous?.consecutiveShapeMismatches ?? 0) + 1
                : 0
        )
        persist()
    }

    nonisolated static func persistedRecords(from userDefaults: UserDefaults) -> [ServiceType: ProviderParseHealthRecord] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ProviderParseHealthRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.provider, $0) })
    }

    nonisolated static func sharedRecords() -> [ServiceType: ProviderParseHealthRecord] {
        sharedRecords(
            fileURL: SharedMetricsStore.parseHealthFileURL,
            fallbackUserDefaults: UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier)
        )
    }

    nonisolated static func sharedRecords(
        fileURL: URL?,
        fallbackUserDefaults: UserDefaults?
    ) -> [ServiceType: ProviderParseHealthRecord] {
        if let records = loadRecords(from: fileURL) {
            return records
        }
        guard let fallbackUserDefaults else { return [:] }
        return persistedRecords(from: fallbackUserDefaults)
    }

    private func persist() {
        guard let data = Self.encodedRecords(records) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
        persistSharedData(data)
    }

    func flushPendingWrites() {
        ioQueue.sync {}
    }

    nonisolated private static func loadRecords(
        from fileURL: URL?
    ) -> [ServiceType: ProviderParseHealthRecord]? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ProviderParseHealthRecord].self, from: data) else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.provider, $0) })
    }

    nonisolated private static func encodedRecords(
        _ records: [ServiceType: ProviderParseHealthRecord]
    ) -> Data? {
        let ordered = records.values.sorted { $0.provider.sortOrder < $1.provider.sortOrder }
        return try? JSONEncoder().encode(ordered)
    }

    private func persistSharedFile(_ records: [ServiceType: ProviderParseHealthRecord]) {
        guard let data = Self.encodedRecords(records) else { return }
        persistSharedData(data)
    }

    private func persistSharedData(_ data: Data) {
        guard let sharedFileURL else { return }
        ioQueue.async {
            do {
                try SecureFileWriter.write(data, to: sharedFileURL)
            } catch {
                AppLog.storage.error(
                    """
                    Failed to save provider health: \
                    \(SecureFileWriterError.logDescription(for: error), privacy: .public)
                    """
                )
            }
        }
    }

    nonisolated private static func isShapeMismatch(_ error: Error) -> Bool {
        if let serviceError = error as? ServiceError,
           case .parsingError = serviceError {
            return true
        }
        if error is DecodingError { return true }
        let message = error.localizedDescription.lowercased()
        return message.contains("parse") || message.contains("decode") || message.contains("format")
    }
}
