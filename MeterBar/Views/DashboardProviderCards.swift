import AppKit
import SwiftUI
import MeterBarShared

// Provider status/limit cards extracted from UsageDashboardView.swift (R8 split). Pure move.

struct DashboardStatusHero: View {
    let title: String
    let detail: String
    let iconName: String
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 46, height: 46)
                Image(systemName: iconName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .dashboardCardBackground()
    }
}

struct ProviderOverviewStatusCard: View {
    let snapshot: ProviderSnapshot

    private var statusText: String {
        snapshot.band?.shortLabel ?? "No data"
    }

    private var statusColor: Color {
        snapshot.band?.color ?? .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                ProviderLogoView(kind: snapshot.logoKind, size: 20, foregroundColor: snapshot.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(updatedText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(statusColor)
            }

            if snapshot.limits.isEmpty {
                Text("No quota windows reported")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.limits) { limit in
                        DashboardLimitRow(limit: limit, accentColor: snapshot.accentColor)
                    }
                }
            }

            // Reset-credits + extra-usage badges, matching the popover card
            // (shared component so the two surfaces can't drift — issue #40).
            let badges = ProviderStatusBadges(snapshot: snapshot, style: .regular)
            if badges.hasContent {
                badges
            }
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: overviewTileMinHeight,
            alignment: .topLeading
        )
        .dashboardCardBackground()
    }

    private var updatedText: String {
        guard let updatedAt = snapshot.updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }
}

struct ProviderLimitsCard: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderTitle(
                    title: snapshot.title,
                    logoKind: snapshot.logoKind,
                    color: snapshot.accentColor,
                    font: .title3
                )
                Spacer()
                Text(updatedText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if snapshot.limits.isEmpty {
                Text("No quota windows reported")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(snapshot.limits) { limit in
                    DashboardLimitRow(limit: limit, accentColor: snapshot.accentColor)
                }
            }

            // Same reset-credits + extra-usage badges as the popover card.
            let badges = ProviderStatusBadges(snapshot: snapshot, style: .regular)
            if badges.hasContent {
                badges
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardCardBackground()
    }

    private var updatedText: String {
        guard let updatedAt = snapshot.updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }
}

struct ProviderTitle: View {
    let title: String
    let logoKind: ProviderLogoKind
    let color: Color
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            ProviderLogoView(kind: logoKind, size: 18, foregroundColor: color)
            Text(title)
                .font(font)
                .fontWeight(.semibold)
        }
    }
}

struct DashboardLimitRow: View {
    let limit: SnapshotLimit
    let accentColor: Color

    private var isOut: Bool {
        limit.percentLeft <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(limit.title)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(isOut ? "Out" : "\(limit.percentLeft)% left")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(isOut ? MeterBarTheme.danger : .primary)
            }

            UsageBar(
                usedPercentage: limit.usedPercent,
                accentColor: accentColor,
                pace: limit.usageLimit.pace(),
                paceContext: limit.paceContext
            )

            HStack {
                Text("\(Int(limit.usedPercent.rounded()))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let pace = limit.usageLimit.pace() {
                    Text(pace.leftLabel)
                        .font(.caption)
                        .foregroundColor(paceLabelColor(pace))
                }
                Spacer()
                if limit.usageLimit.resetTime != nil {
                    ResetCountdownLabel(
                        title: nil,
                        limit: limit.usageLimit,
                        font: .caption,
                        foregroundColor: .secondary,
                        iconSize: 10
                    )
                }
            }
        }
    }

    private func paceLabelColor(_ pace: UsagePace) -> Color {
        if pace.isExhausted {
            return MeterBarTheme.danger
        }
        switch pace.stage {
        case .reserve:
            return MeterBarTheme.success
        case .deficit:
            return MeterBarTheme.warning
        case .onPace:
            return .secondary
        }
    }
}
