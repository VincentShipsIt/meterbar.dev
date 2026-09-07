import AppKit
import MeterBarShared
import SwiftUI

/// Owns share-card content assembly and PNG rendering outside UsageDashboardView.
enum SocialCardRenderer {
    nonisolated static func content(
        costSummary: CostSummary?,
        providerSnapshotTitles: [String],
        enabledSourceLabels: [String],
        generatedAt: Date
    ) -> SocialShareCardContent {
        let tokenTotal = costSummary?.totalTokens
        let sessionCount = costSummary?.costs.reduce(0) { $0 + $1.sessionCount }
        let topProviderName = costSummary?.costs.max {
            $0.totalTokens < $1.totalTokens
        }?.provider.displayName

        let providerNames: [String]
        if let costs = costSummary?.costs, !costs.isEmpty {
            providerNames = costs.map(\.provider.displayName)
        } else if !providerSnapshotTitles.isEmpty {
            providerNames = providerSnapshotTitles
        } else {
            providerNames = enabledSourceLabels
        }

        let dailyTokenTotals: [Int]
        if let costSummary {
            dailyTokenTotals = SocialShareCardContent.dailyTokenTotals(
                from: costSummary.dailyUsage,
                now: generatedAt
            )
        } else {
            dailyTokenTotals = []
        }

        return SocialShareCardContent(
            tokenTotal: tokenTotal,
            sessionCount: sessionCount,
            providerNames: providerNames,
            topProviderName: topProviderName,
            dailyTokenTotals: dailyTokenTotals,
            generatedAt: generatedAt
        )
    }

    @MainActor
    static func image(for content: SocialShareCardContent) -> NSImage? {
        image(of: SocialShareCard(content: content))
    }

    @MainActor
    static func pngData(for content: SocialShareCardContent) -> Data? {
        image(for: content).flatMap(pngData(from:))
    }

    /// Same pipeline as the token card, so both PNGs come out at
    /// `SocialShareCardLayout.exportSize` with identical encoding.
    @MainActor
    static func image(for content: SocialLimitsCardContent) -> NSImage? {
        image(of: SocialLimitsCard(content: content))
    }

    @MainActor
    static func pngData(for content: SocialLimitsCardContent) -> Data? {
        image(for: content).flatMap(pngData(from:))
    }

    @MainActor
    private static func image(of card: some View) -> NSImage? {
        let exportSize = SocialShareCardLayout.exportSize
        let renderer = ImageRenderer(
            content: card.frame(width: exportSize.width, height: exportSize.height)
        )
        renderer.proposedSize = ProposedViewSize(width: exportSize.width, height: exportSize.height)
        renderer.scale = 1
        return renderer.nsImage
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
