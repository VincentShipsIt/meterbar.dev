import Foundation
import MeterBarShared

/// What one popover tile says, worked out from a snapshot with no SwiftUI
/// attached so every rule is directly assertable.
///
/// Every number a tile shows names its direction: "52% left" or "48% used",
/// never a bare "52%". A bare figure next to a ring was read as usage, which is
/// the opposite of what the ring meant.
struct PopoverTileContent: Equatable {
    enum Tone: Equatable {
        case healthy
        case tight
        case critical
        /// No quota reading: a status word stands in for the number.
        case neutral
    }

    /// A smaller window shown under the hero figure ("Session 81% left").
    struct WindowChip: Equatable, Identifiable {
        let id: String
        let title: String
        let valueText: String
        let tone: Tone
    }

    let id: String
    let title: String
    let planLabel: String?
    /// The window the figure describes ("Weekly"), or `nil` for a status tile.
    let windowTitle: String?
    /// Whole-number percent left, when the primary window is measured.
    let percentLeft: Int?
    /// 0...1 share of the ring that is filled (what is left).
    let fractionLeft: Double?
    /// "52% left", "$4.10 left", or a status word ("Login required").
    let headline: String
    /// "48% used" for a measured window, otherwise `nil`.
    let usedText: String?
    /// "Out by Tue 9 AM", "Lasts until reset", or "Resets in 2h 10m".
    let outlook: String?
    /// True when `outlook` warns that the window runs dry before it resets.
    let outlookIsShortfall: Bool
    let tone: Tone
    /// The provider's other measured windows, in card order.
    let otherWindows: [WindowChip]

    init(snapshot: ProviderSnapshot, now: Date = Date()) {
        id = snapshot.id
        title = snapshot.title
        planLabel = snapshot.planLabel

        let hasStatusOverride = ProviderCardPresentation.setupStatusText(for: snapshot) != nil
            || snapshot.authNotice != nil
            || !snapshot.hasMetrics

        guard !hasStatusOverride, let primary = snapshot.presentationPrimaryLimit(now: now) else {
            windowTitle = nil
            percentLeft = nil
            fractionLeft = nil
            headline = ProviderCardPresentation.statusText(for: snapshot)
            usedText = nil
            outlook = snapshot.hasMetrics ? snapshot.updatedText : nil
            outlookIsShortfall = false
            tone = .neutral
            otherWindows = []
            return
        }

        windowTitle = primary.localizedTitle
        let usage = primary.usageLimit
        let isMeasured = usage.reading == .measured && primary.valueStyle == .quota
        if isMeasured {
            percentLeft = primary.percentLeft
            fractionLeft = usage.total > 0 ? min(1, max(0, 1 - usage.rawPercentage / 100)) : nil
            headline = LocalizedUsageFormat.percentLeft(usage)
            usedText = LocalizedUsageFormat.percentUsed(usage)
        } else {
            percentLeft = nil
            fractionLeft = nil
            headline = ProviderCardPresentation.statusText(for: snapshot)
            usedText = nil
        }
        tone = Self.tone(for: usage)

        let projection = Self.projectedOutlook(for: primary, snapshot: snapshot, now: now)
        outlook = projection.text
        outlookIsShortfall = projection.isShortfall

        otherWindows = snapshot.limits
            .filter { $0.id != primary.id }
            .compactMap { limit in
                guard limit.usageLimit.reading == .measured, limit.valueStyle == .quota else { return nil }
                return WindowChip(
                    id: limit.id,
                    title: limit.localizedTitle,
                    valueText: LocalizedUsageFormat.percentLeft(limit.usageLimit),
                    tone: Self.tone(for: limit.usageLimit)
                )
            }
    }

    /// The figure split for display: "52" and "% left". Falls back to the
    /// whole headline when the window is not a measured percentage.
    var figure: (number: String, unit: String)? {
        guard let percentLeft else { return nil }
        let number = "\(percentLeft)"
        guard headline.hasPrefix(number) else { return nil }
        return (number, String(headline.dropFirst(number.count)))
    }

    static func tone(for usage: UsageLimit) -> Tone {
        switch QuotaBand.forLimit(usage) {
        case .healthy: .healthy
        case .tight: .tight
        case .critical, .exhausted: .critical
        }
    }

    /// The runway headline when the window can be projected; otherwise the
    /// plain time to reset. A blocked provider says when it is back.
    static func projectedOutlook(
        for limit: SnapshotLimit,
        snapshot: ProviderSnapshot,
        now: Date
    ) -> (text: String?, isShortfall: Bool) {
        if snapshot.hasExhaustedLimit, let reset = snapshot.resetWindows.compactMap(\.limit.resetTime).min() {
            return ("Back in \(UsageDurationText.short(seconds: reset.timeIntervalSince(now)))", true)
        }
        if let runway = RunwayContent(limit: limit.usageLimit, now: now) {
            return (runway.headline, runway.outlook == .shortfall)
        }
        if let reset = limit.usageLimit.resetTime, reset > now {
            return ("Resets in \(UsageDurationText.short(seconds: reset.timeIntervalSince(now)))", false)
        }
        return (nil, false)
    }
}

/// How the popover deals its tiles: the tightest provider gets the wide hero
/// tile, everyone else shares a two-column grid in display order.
enum PopoverTileLayout {
    struct Plan: Equatable {
        let heroID: String?
        let gridIDs: [String]
    }

    static func plan(for snapshots: [ProviderSnapshot], now: Date = Date()) -> Plan {
        let hero = heroSnapshot(in: snapshots, now: now)
        return Plan(
            heroID: hero?.id,
            gridIDs: snapshots.map(\.id).filter { $0 != hero?.id }
        )
    }

    /// The provider with the least measured headroom. A provider without a
    /// reading never takes the hero: there is no number to lead with.
    /// Ties keep display order.
    static func heroSnapshot(in snapshots: [ProviderSnapshot], now: Date = Date()) -> ProviderSnapshot? {
        var best: (snapshot: ProviderSnapshot, percentLeft: Int)?
        for snapshot in snapshots {
            guard let percentLeft = PopoverTileContent(snapshot: snapshot, now: now).percentLeft else { continue }
            if best == nil || percentLeft < (best?.percentLeft ?? Int.max) {
                best = (snapshot, percentLeft)
            }
        }
        return best?.snapshot
    }
}
