import Foundation
import MeterBarShared

/// Version 1 contract for `meterbar guard --json`.
///
/// Every field except `schemaVersion`, `outcome`, `exitCode`, `checkedAt`, and
/// `message` is optional: a usage error never reaches a provider, and an
/// unavailable snapshot has no quota numbers to report. Omission is how the
/// document says "not known" instead of inventing a safe-looking zero.
nonisolated struct GuardCLIResponse: CLIJSONDocument {
    static let currentSchemaVersion = 1

    private let schemaVersion = currentSchemaVersion
    private let outcome: String
    private let exitCode: Int32
    private let checkedAt: Date
    private let provider: String?
    private let displayName: String?
    private let window: String?
    private let account: Account?
    private let used: Double?
    private let total: Double?
    private let percentUsed: Double?
    private let percentLeft: Int?
    private let quotaBand: String?
    private let estimated: Bool?
    private let resetAt: Date?
    private let minRemainingPercent: Double?
    private let snapshot: Snapshot?
    private let message: String
    private let error: ErrorDetail?

    init(evaluation: QuotaGuardEvaluation) {
        outcome = evaluation.outcome.rawValue
        exitCode = evaluation.outcome.exitCode
        checkedAt = evaluation.checkedAt
        provider = evaluation.service?.cliIdentifier
        displayName = evaluation.service?.displayName
        window = evaluation.window?.cliIdentifier
        account = evaluation.account.map(Account.init(account:))
        used = evaluation.quota?.used
        total = evaluation.quota?.total
        percentUsed = evaluation.quota?.percentUsed
        percentLeft = evaluation.quota?.percentLeft
        quotaBand = evaluation.quota?.band.cliIdentifier
        estimated = evaluation.quota?.estimated
        resetAt = evaluation.quota?.resetAt
        minRemainingPercent = evaluation.minRemainingPercent
        snapshot = evaluation.snapshot.map(Snapshot.init(info:))
        message = evaluation.message
        error = evaluation.failure.map(ErrorDetail.init(failure:))
    }

    private struct Account: Encodable {
        let scope: String
        let name: String

        init(account: QuotaGuardAccount) {
            scope = account.scope.rawValue
            name = account.name
        }
    }

    private struct Snapshot: Encodable {
        let lastUpdated: Date
        let ageSeconds: TimeInterval
        let isStale: Bool

        init(info: QuotaGuardSnapshotInfo) {
            lastUpdated = info.lastUpdated
            ageSeconds = info.ageSeconds
            isStale = info.isStale
        }
    }

    private struct ErrorDetail: Encodable {
        let code: String
        let message: String
        let flag: String?
        let value: String?

        init(failure: QuotaGuardFailure) {
            code = failure.code
            message = failure.message
            flag = failure.flag
            value = failure.value
        }
    }
}
