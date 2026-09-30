import MeterBarShared
import SwiftUI

/// The one breakdown table on the Usage page. Replaces "Spend by model", "Token
/// Burn by Model", "Top Usage Origins" and every provider card's Models and
/// Usage Origin lists — the same rows drawn five ways with different columns and
/// different truncation.
struct UsageBreakdownCard: View {
    let report: UsageReport

    @State private var tab: UsageBreakdownTab = .model
    @State private var showsAll = false

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// Rows shown before the reader asks for the rest.
    static let compactRowLimit = 8

    /// Title for the expand/collapse control, or `nil` when the table already
    /// fits within the compact limit and a control would toggle nothing.
    static func toggleTitle(showingAll: Bool, totalCount: Int) -> String? {
        guard totalCount > compactRowLimit else { return nil }
        return showingAll ? "Show top \(compactRowLimit)" : "Show all \(totalCount)"
    }

    /// Header caption for a tab whose rows describe something other than the
    /// selected window, `nil` when they describe the window.
    static func scopeCaption(for tab: UsageBreakdownTab, in report: UsageReport) -> String? {
        report.breakdownIsWindowed(tab) ? report.selection.subtitle : "\(report.scanPeriodDays)-day scan"
    }

    private var rows: [UsageBreakdownRow] { report.breakdown(tab) }

    private var displayedRows: [UsageBreakdownRow] {
        showsAll ? rows : Array(rows.prefix(Self.compactRowLimit))
    }

    var body: some View {
        DashboardCard(title: "Breakdown", trailing: Self.scopeCaption(for: tab, in: report)) {
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
                tabPicker

                if rows.isEmpty {
                    Text("No \(tab.primaryColumnTitle.lowercased()) breakdown in this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                } else {
                    CompositionLegend()

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        headerRow
                        Divider()
                            .gridCellUnsizedAxes(.horizontal)
                        ForEach(displayedRows) { row in
                            UsageBreakdownRowView(row: row, tab: tab)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if let title = Self.toggleTitle(showingAll: showsAll, totalCount: rows.count) {
                        Button {
                            withAnimation(MeterBarTheme.Motion.resolve(
                                MeterBarTheme.Motion.disclosure,
                                reduceMotion: reduceMotion
                            )) {
                                showsAll.toggle()
                            }
                        } label: {
                            Label(title, systemImage: showsAll ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("Breakdown", selection: $tab) {
            ForEach(UsageBreakdownTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Breakdown by")
        .onChange(of: tab) { showsAll = false }
    }

    private var headerRow: some View {
        GridRow {
            Text(tab.primaryColumnTitle)
                .gridColumnAlignment(.leading)
            Text("Tokens")
                .gridColumnAlignment(.trailing)
            Text("Composition")
                .gridColumnAlignment(.leading)
            Text("Cost")
                .gridColumnAlignment(.trailing)
            Text("Share")
                .gridColumnAlignment(.trailing)
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Row

private struct UsageBreakdownRowView: View {
    let row: UsageBreakdownRow
    let tab: UsageBreakdownTab

    var body: some View {
        GridRow {
            HStack(spacing: 8) {
                if let provider = row.provider {
                    Circle()
                        .fill(MeterBarTheme.accent(for: provider))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                Text(row.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let tier = row.tier, tier != .unknown {
                    Text(tier.costIndicator)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .accessibilityLabel(tier.costAccessibilityLabel)
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            Text(UsageFormat.tokens(row.tokenCount))
                .font(.callout)
                .fontWeight(.semibold)
                .monospacedDigit()

            TokenCompositionBar(composition: row.composition)
                .frame(minWidth: 72, maxWidth: 200)
                .gridColumnAlignment(.leading)

            Text(UsageFormat.cost(row.costUSD))
                .font(.callout)
                .monospacedDigit()

            Text(OptimizationInsights.percentString(row.share))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let tier = row.tier, tier != .unknown {
            parts.append(tier.costAccessibilityLabel)
        }
        parts.append("\(UsageFormat.tokens(row.tokenCount)) tokens")
        parts.append(TokenCompositionBar.accessibilityDescription(for: row.composition))
        parts.append(UsageFormat.cost(row.costUSD))
        parts.append("\(OptimizationInsights.percentString(row.share)) of the total")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Composition bar

/// Four segments — input, output, cache write, cache read — that always fill
/// the bar, so two rows compare by *mix* regardless of size. A row's size is the
/// tokens column beside it; this bar answers "what kind of tokens were they?".
struct TokenCompositionBar: View {
    let composition: TokenComposition

    static let height: CGFloat = 6

    struct Segment: Identifiable, Equatable {
        let kind: TokenKind
        let fraction: Double

        var id: TokenKind { kind }
    }

    /// The segments worth drawing, in fixed order.
    static func segments(for composition: TokenComposition) -> [Segment] {
        TokenKind.allCases
            .map { Segment(kind: $0, fraction: composition.fraction($0)) }
            .filter { $0.fraction > 0 }
    }

    static func accessibilityDescription(for composition: TokenComposition) -> String {
        let parts = segments(for: composition).map {
            "\(OptimizationInsights.percentString($0.fraction)) \($0.kind.title.lowercased())"
        }
        return parts.isEmpty ? "no tokens" : parts.joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { proxy in
            let segments = Self.segments(for: composition)
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.kind.color)
                        .frame(width: max(1, (proxy.size.width - CGFloat(segments.count - 1)) * segment.fraction))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipShape(Capsule())
            .background(Capsule().fill(.quaternary))
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

private struct CompositionLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(TokenKind.allCases) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: MeterBarTheme.Radius.small)
                        .fill(kind.color)
                        .frame(width: 8, height: 8)
                    Text(kind.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }
}
