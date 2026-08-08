import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

/// Offscreen PNG renders of the redesigned Costs-page cards, for visual
/// verification without driving the running app. Skipped unless SNAPSHOT_DIR
/// is set, so the normal suite never writes artifacts.
@MainActor
final class CostsPageSnapshotRenderTests: XCTestCase {
    func testRenderCostsPageCards() throws {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else {
            throw XCTSkip("render only when SNAPSHOT_DIR is set")
        }
        let outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        let summary = DemoData.costSummary()

        try render(width: 1000, name: "1-headline-row", into: outputDir) {
            HStack(alignment: .top, spacing: MeterBarTheme.Spacing.sm) {
                CostOverviewStatusCard(
                    summary: summary,
                    isScanning: false,
                    isRefreshingMissingDays: false,
                    formattedTokens: UsageFormat.tokens(summary.totalTokens)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                LifetimeCostSummaryCard(summary: summary.lifetime, isScanning: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        try render(width: 1000, name: "2-spend-charts", into: outputDir) {
            DashboardCard(title: "30 Day Spend") {
                CostSpendCharts(presentation: CostChartPresentation(summary: summary))
            }
        }

        try render(width: 1000, name: "3-token-activity", into: outputDir) {
            TokenActivityCard(
                summary: summary,
                isScanning: false,
                isScanDisabled: false,
                scan: {}
            )
        }
    }

    private func render<V: View>(
        width: CGFloat,
        name: String,
        into outputDir: URL,
        @ViewBuilder content: () -> V
    ) throws {
        let host = NSHostingView(
            rootView: content()
                .frame(width: width)
                .padding(20)
                .background(Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1)))
                .environment(\.colorScheme, .dark)
        )
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        // A window backs the view hierarchy so layers materialize; it is never
        // ordered onto the screen — the capture is an offscreen cacheDisplay.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("no bitmap rep for \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("no png data for \(name)")
        }
        try data.write(to: outputDir.appendingPathComponent("\(name).png"))
    }
}
