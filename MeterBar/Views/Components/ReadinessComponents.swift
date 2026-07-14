import MeterBarShared
import SwiftUI

// Shared provider-readiness UI, rendered identically by the dashboard
// Diagnostics section and the first-run/empty-state checklist. The data comes
// from `ProviderReadinessInspector`; these views only present it.

extension ReadinessLevel {
  /// Tint for the check icon/badge.
  var tint: Color {
    switch self {
    case .pass: return .green
    case .warn: return .orange
    case .fail: return .red
    }
  }

  /// SF Symbol shown next to a check.
  var iconName: String {
    switch self {
    case .pass: return "checkmark.circle.fill"
    case .warn: return "exclamationmark.triangle.fill"
    case .fail: return "xmark.octagon.fill"
    }
  }

  /// Short badge label for the provider header.
  var badgeLabel: String {
    switch self {
    case .pass: return "Ready"
    case .warn: return "Check"
    case .fail: return "Action needed"
    }
  }
}

/// One readiness check: status icon, title, plain-language detail, and an
/// optional recovery action rendered as a monospaced call-to-action.
struct ReadinessCheckRow: View {
  let check: ReadinessCheck
  var compact: Bool = false
  var recoveryAction: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: check.level.iconName)
        .font(.system(size: compact ? 11 : 13, weight: .semibold))
        .foregroundStyle(check.level.tint)
        .padding(.top, MeterBarTheme.Spacing.xxs)

      VStack(alignment: .leading, spacing: 2) {
        Text(check.title)
          .font(compact ? .caption : .subheadline)
          .fontWeight(.medium)
        Text(check.detail)
          .font(compact ? .caption2 : .caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let recovery = check.recovery {
          if let recoveryAction {
            Button(action: recoveryAction) {
              HStack(spacing: 4) {
                Text(recovery)
                Image(systemName: "arrow.up.forward.app")
              }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open MeterBar Settings")
            .recoveryStyle(compact: compact, tint: check.level.tint)
          } else {
            Text(recovery)
              .recoveryStyle(compact: compact, tint: check.level.tint)
          }
        }
      }
      Spacer(minLength: 0)
    }
  }
}

/// A provider's full readiness report: header with logo + overall badge, then
/// each ordered check.
struct ReadinessProviderCard: View {
  let report: ProviderReadiness
  var compact: Bool = false
  var recoveryAction: (() -> Void)?

  var body: some View {
    DashboardTile(padding: compact ? 11 : 14) {
      VStack(alignment: .leading, spacing: compact ? 8 : 10) {
        HStack(spacing: 8) {
          ProviderLogoView(
            kind: .forService(report.provider),
            size: compact ? 15 : 18,
            foregroundColor: .primary
          )
          Text(report.provider.displayName)
            .font(compact ? .subheadline : .headline)
            .fontWeight(.semibold)
          Spacer(minLength: 0)
          ReadinessBadge(level: report.overall)
        }

        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
          ForEach(report.checks) { check in
            ReadinessCheckRow(check: check, compact: compact, recoveryAction: recoveryAction)
          }
        }
      }
    }
  }
}

/// Rolled-up status pill for a provider header.
struct ReadinessBadge: View {
  let level: ReadinessLevel

  var body: some View {
    Text(level.badgeLabel)
      .font(.caption2)
      .fontWeight(.semibold)
      .foregroundStyle(level.tint)
      .padding(.horizontal, MeterBarTheme.Spacing.sm)
      .padding(.vertical, MeterBarTheme.Spacing.xs)
      .background(level.tint.opacity(MeterBarTheme.Fill.subtle), in: Capsule())
  }
}

/// Renders readiness reports as a plain-text block for the "Copy report" button.
/// Mirrors the `meterbar doctor` layout so a pasted report reads the same whether
/// it came from the CLI or the app. Every string is already redacted upstream.
enum DiagnosticsReportText {
  static func plainText(_ reports: [ProviderReadiness]) -> String {
    var lines = ["MeterBar Diagnostics", ""]
    for report in reports {
      lines.append("\(report.provider.displayName)  [\(report.overall.rawValue.uppercased())]")
      for check in report.checks {
        lines.append("  \(symbol(check.level)) \(check.title): \(check.detail)")
        if let recovery = check.recovery {
          lines.append("      -> \(recovery)")
        }
      }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  private static func symbol(_ level: ReadinessLevel) -> String {
    switch level {
    case .pass: return "[ok]"
    case .warn: return "[warn]"
    case .fail: return "[fail]"
    }
  }
}

/// A stack of provider readiness cards. Used by the dashboard Diagnostics
/// section (all providers) and the empty-state checklist (unhealthy only).
struct ReadinessChecklist: View {
  let reports: [ProviderReadiness]
  var compact: Bool = false
  var recoveryAction: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      ForEach(reports) { report in
        ReadinessProviderCard(report: report, compact: compact, recoveryAction: recoveryAction)
      }
    }
  }
}

private extension View {
  func recoveryStyle(compact: Bool, tint: Color) -> some View {
    font(compact ? .caption2 : .caption)
      .fontWeight(.medium)
      .foregroundStyle(tint)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, MeterBarTheme.Spacing.xxs)
  }
}
