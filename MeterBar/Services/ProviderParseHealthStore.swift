import Combine
import Foundation
import MeterBarShared

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

    func needsAttention(now: Date = Date()) -> Bool {
        if consecutiveShapeMismatches >= Self.sustainedShapeMismatchCount
            || consecutiveFailures >= Self.sustainedFailureCount {
            return true
        }
        guard let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) > Self.staleAfter
    }
}

/// Records provider outcomes in the app-group domain so the GUI and bundled
/// `meterbar doctor` process read the same diagnostic state.
final class ProviderParseHealthStore: ObservableObject {
    static let shared = ProviderParseHealthStore()
    nonisolated static let storageKey = "ProviderParseHealthV1"

    @Published private(set) var records: [ServiceType: ProviderParseHealthRecord]

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults? = nil) {
        let resolved = userDefaults
            ?? UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier)
            ?? .standard
        self.userDefaults = resolved
        records = Self.persistedRecords(from: resolved)
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
        guard let defaults = UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier) else { return [:] }
        return persistedRecords(from: defaults)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
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
