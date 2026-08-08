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
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = DemoData.costSummary()

        try render(width: 1000, name: "0-overview", into: outputDir) {
            DashboardOverviewSection(
                snapshots: overviewSnapshots(),
                tightestLimit: overviewSnapshots().first?.limits.first,
                costSummary: summary,
                onSelectProvider: { _ in }
            )
        }

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

    /// One healthy provider and one logged-out stale one, so the render shows
    /// both the "Use next" tile and the collapsed login one-liner.
    private func overviewSnapshots() -> [ProviderSnapshot] {
        let healthy = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: UsageMetrics(
                service: .codexCli,
                sessionLimit: UsageLimit(used: 56, total: 100, resetTime: Date().addingTimeInterval(9_000)),
                weeklyLimit: UsageLimit(used: 8, total: 100, resetTime: Date().addingTimeInterval(345_600))
            ),
            emptyDetail: "Run codex login"
        )
        let staleLogin = ProviderSnapshot(
            id: "claude-shipshitdev",
            title: "shipshitdev",
            service: .claudeCode,
            updatedAt: Date().addingTimeInterval(-3 * 60 * 60),
            limits: [
                SnapshotLimit(
                    id: "session",
                    kind: .session,
                    title: "Session",
                    usageLimit: UsageLimit(used: 56, total: 100, resetTime: nil)
                ),
            ],
            emptyDetail: "Run claude login",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil,
            authNotice: .loginRequired
        )
        return [staleLogin, healthy]
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
