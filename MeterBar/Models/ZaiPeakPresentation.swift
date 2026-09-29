import Foundation
import MeterBarShared

/// The words for `ZaiPeakSchedule.Status`, shared by the provider-card badge
/// and the Settings row so the two cannot describe the same moment differently.
enum ZaiPeakPresentation {
    static func label(_ status: ZaiPeakSchedule.Status, now: Date = Date()) -> String {
        let countdown = status.nextChange.map {
            UsageDurationText.short(seconds: $0.timeIntervalSince(now))
        }
        switch (status.isPeak, status.isPromotion, countdown) {
        case let (true, _, countdown?):
            return String(localized: "zai.peak.peak", defaultValue: "Peak · off-peak in \(countdown)")
        case (true, _, nil):
            return String(localized: "zai.peak.peak_only", defaultValue: "Peak")
        case let (false, true, countdown?):
            return String(
                localized: "zai.peak.promotion",
                defaultValue: "Off-peak all day · peak resumes in \(countdown)"
            )
        case (false, true, nil):
            return String(localized: "zai.peak.promotion_only", defaultValue: "Off-peak all day")
        case let (false, false, countdown?):
            return String(localized: "zai.peak.offpeak", defaultValue: "Off-peak · peak in \(countdown)")
        case (false, false, nil):
            return String(localized: "zai.peak.offpeak_only", defaultValue: "Off-peak")
        }
    }

    /// One sentence of context for the tooltip: what the rate difference is and
    /// where the schedule comes from.
    static var explanation: String {
        String(
            localized: "zai.peak.explanation",
            defaultValue: """
            Z.ai charges off-peak usage at 50% of the standard credit rate. \
            Peak hours are Monday to Friday, 14:00–18:00 Singapore time (UTC+8).
            """
        )
    }
}
