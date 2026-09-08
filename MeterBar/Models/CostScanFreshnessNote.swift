import Foundation
import MeterBarShared

/// Distinguishes the cost-scan pipeline's freshness from the quota-poll
/// pipeline's, wherever both sit on the same card (issue #530).
///
/// The popover header's "Updated N min ago" (`ProviderSnapshot.updatedText`)
/// describes the **quota poll** — the fetch that drives the Session/Weekly/
/// limit bars. The seven-day sparkline in the hover detail panel is fed by an
/// entirely different pipeline, the **cost scan**, which keeps its own
/// independent `CostTracker.lastScanDate`. #517 was first diagnosed as a data
/// bug for exactly this reason: a fresh "Updated 4 min ago" sitting over an
/// empty sparkline reads as "your usage is missing," not "you're looking at
/// two different clocks." #528 fixed the underlying staleness gate; this type
/// is what makes the two clocks legible so the same misdiagnosis can't recur.
///
/// Deliberately quiet, matching the design brief's "secondary signal, not a
/// warning banner": `text` is `nil` whenever the scan is at least as fresh as
/// the poll (within `materiallyOlderThreshold`), so the sparkline does not
/// repeat a timestamp the card header already states just above it.
struct CostScanFreshnessNote: Equatable {
    /// Secondary caption for the sparkline's own header, or `nil` when there
    /// is nothing to add beyond what the card header already says.
    let text: String?

    /// How far behind the quota poll a cost scan can trail before the gap is
    /// worth calling out on its own. Reuses `ProviderParseHealthRecord
    /// .staleAfter`, the app's existing "old enough that the UI should stop
    /// implying this is current" threshold (also what ages a card's own
    /// freshness overlay into `.stale`), rather than inventing a second one.
    static let materiallyOlderThreshold = ProviderParseHealthRecord.staleAfter

    /// - Parameters:
    ///   - quotaPollUpdatedAt: The same timestamp the card header's "Updated
    ///     N min ago" reads (`ProviderSnapshot.updatedAt`). `nil` when the
    ///     provider has never been polled.
    ///   - costScanDate: `CostTracker.lastScanDate` — the timestamp behind
    ///     the sparkline's own data. `nil` when no cost scan has ever run.
    ///   - now: Injectable clock for deterministic relative-time text.
    init(quotaPollUpdatedAt: Date?, costScanDate: Date?, now: Date = Date()) {
        guard let costScanDate else {
            text = "Not scanned yet"
            return
        }
        // No poll to compare against: there is nothing to disagree with, but
        // the sparkline still owes its own clock rather than silence.
        guard let quotaPollUpdatedAt else {
            text = "Scanned \(UsageFormat.relative(costScanDate, to: now))"
            return
        }
        // Only the poll being *ahead* of the scan is worth flagging — a scan
        // that ran after the last poll is, if anything, more current.
        let gap = quotaPollUpdatedAt.timeIntervalSince(costScanDate)
        guard gap > Self.materiallyOlderThreshold else {
            text = nil
            return
        }
        text = "Scanned \(UsageFormat.relative(costScanDate, to: now))"
    }
}
