import Foundation

/// Maps the outcome of spending a Codex reset credit onto the alert the card
/// shows.
///
/// The distinction this encodes is easy to get wrong inline: a failed *refresh*
/// after a *successful* redemption is not a failure. The credit is gone, so copy
/// that reads like an error invites the user to retry and burn a second one.
enum ProviderCardResetCreditOutcome {
    struct Alert: Equatable {
        let title: String
        let message: String?
    }

    static let failureTitle = "Couldn't use reset credit"
    static let partialSuccessTitle = "Reset credit used"

    /// The redemption itself threw — nothing was spent.
    static func alert(for error: Error) -> Alert {
        Alert(title: failureTitle, message: error.localizedDescription)
    }

    /// The redemption succeeded. Returns `nil` unless the follow-up usage
    /// refresh failed, in which case the alert warns *without* implying the
    /// credit can be reclaimed by retrying.
    static func alert(for consumption: CodexResetCreditConsumption) -> Alert? {
        guard let refreshError = consumption.usageRefreshErrorDescription else { return nil }
        return partialSuccessAlert(refreshError: refreshError)
    }

    static func alert(for consumption: GrokResetCreditConsumption) -> Alert? {
        guard let refreshError = consumption.usageRefreshErrorDescription else { return nil }
        return partialSuccessAlert(refreshError: refreshError)
    }

    private static func partialSuccessAlert(refreshError: String) -> Alert {
        let message = "The credit was used, but usage could not refresh (\(refreshError)). "
            + "Do not retry; refresh later."
        return Alert(title: partialSuccessTitle, message: message)
    }
}
