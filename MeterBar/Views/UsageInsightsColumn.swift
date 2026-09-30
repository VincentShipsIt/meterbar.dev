import MeterBarShared
import SwiftUI

/// The Usage page's right column: what the numbers suggest, and how far to trust
/// them. Each insight carries a severity dot, the recommendation copy, and the
/// number it was derived from; data-quality notes say what the figures cannot
/// see.
struct UsageInsightsColumn: View {
    let report: UsageReport
    /// Notes the page knows and the report cannot, such as which Macs an
    /// "All Macs" total was combined from.
    var extraNotes: [UsageDataNote] = []

    private var notes: [UsageDataNote] { extraNotes + report.notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            insightsCard
            dataQualityCard
        }
    }

    @ViewBuilder private var insightsCard: some View {
        DashboardCard(title: "Insights", trailing: report.selection.subtitle) {
            VStack(alignment: .leading, spacing: 14) {
                if report.insights.recommendations.isEmpty {
                    Text("Nothing to flag: there is no usage in this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(report.insights.recommendations) { recommendation in
                        UsageInsightRow(recommendation: recommendation)
                    }
                }

                Divider()

                Label(
                    "Computed locally from token totals and model names only — no prompt contents "
                        + "leave your Mac.",
                    systemImage: "lock.shield"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var dataQualityCard: some View {
        if !notes.isEmpty {
            DashboardCard(title: "Data quality") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notes) { note in
                        UsageDataNoteRow(note: note)
                    }
                }
            }
        }
    }
}

/// One insight: severity dot, title, recommendation copy, and its source number.
struct UsageInsightRow: View {
    let recommendation: OptimizationRecommendation

    var accessibilityLabelText: String { recommendation.title }

    /// The copy with `$$$` read as a cost tier, plus the number it came from.
    var accessibilityValueText: String {
        [recommendation.accessibilityDetail, recommendation.source].compactMap { $0 }.joined(separator: ". ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Self.color(for: recommendation.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(recommendation.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(recommendation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = recommendation.source {
                    Text(source)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(accessibilityValueText)
    }

    /// Warning reads red, a suggestion orange, an informational note in the
    /// neutral accent, and a healthy signal green — the same mapping the old
    /// Recommendations card used for its glyphs.
    static func color(for severity: RecommendationSeverity) -> Color {
        switch severity {
        case .warning: return MeterBarTheme.danger
        case .suggestion: return MeterBarTheme.warning
        case .info: return MeterBarTheme.accent(for: .claudeCode)
        case .positive: return MeterBarTheme.success
        }
    }
}

struct UsageDataNoteRow: View {
    let note: UsageDataNote

    var body: some View {
        Label {
            Text(note.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: note.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(note.severity == .warning ? MeterBarTheme.warning : Color.secondary)
                .imageScale(.small)
        }
        .accessibilityElement(children: .combine)
    }
}
