import MeterBarShared
import SwiftUI

// MARK: - ApiUsageSection

/// Container shown in the popover and dashboard when the user has entered an
/// org API admin key. Renders the window selector plus one spend card per
/// authenticated API provider.
struct ApiUsageSection: View {
  @ObservedObject var store: ApiUsageStore
  /// Compact popover layout vs the roomier dashboard layout.
  var compact: Bool = false
  /// When embedded in an already-titled container (a dashboard card), hide the
  /// section's own "API Usage" heading but keep the window picker.
  var embedded: Bool = false

  var body: some View {
    if store.hasAnyAuthenticated {
      VStack(alignment: .leading, spacing: compact ? 8 : 12) {
        HStack {
          if !embedded {
            Text("API Usage")
              .font(compact ? .subheadline : .headline)
              .fontWeight(.semibold)
          }
          Spacer(minLength: 8)
          ApiUsageWindowPicker(store: store)
        }

        ForEach(store.authenticatedProviders) { provider in
          ApiUsageCard(
            provider: provider,
            usage: store.usage[provider],
            isLoading: store.isLoading,
            compact: compact
          )
        }

        Text("Estimated from available token usage and approximate list rates; provider data may be incomplete.")
          .font(.caption2)
          .foregroundColor(.secondary)

        if let error = store.lastError {
          Text(error)
            .font(.caption2)
            .foregroundColor(MeterBarTheme.warning)
            .lineLimit(2)
        }
      }
    }
  }
}

// MARK: - ApiUsageWindowPicker

/// Segmented 7-day / 30-day selector with a Custom mode that reveals a date
/// range. Changing any of these refetches through the store.
struct ApiUsageWindowPicker: View {
  @ObservedObject var store: ApiUsageStore

  private enum Mode: String, CaseIterable, Identifiable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case custom = "Custom"
    var id: String { rawValue }
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      Picker("Window", selection: modeBinding) {
        ForEach(Mode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()

      if selectedMode == .custom {
        HStack(spacing: 6) {
          DatePicker("From", selection: customStartBinding, displayedComponents: .date)
            .labelsHidden()
          Text("→").foregroundColor(.secondary)
          DatePicker("To", selection: customEndBinding, displayedComponents: .date)
            .labelsHidden()
        }
        .font(.caption)
      }
    }
  }

  private var selectedMode: Mode {
    switch store.window {
    case .last7Days: return .sevenDays
    case .last30Days: return .thirtyDays
    case .custom: return .custom
    }
  }

  private var modeBinding: Binding<Mode> {
    Binding(get: { selectedMode }, set: applyMode)
  }

  private var customStartBinding: Binding<Date> {
    Binding(
      get: { customDates.start },
      set: { store.setWindow(.custom(start: $0, end: customDates.end)) }
    )
  }

  private var customEndBinding: Binding<Date> {
    Binding(
      get: { customDates.end },
      set: { store.setWindow(.custom(start: customDates.start, end: $0)) }
    )
  }

  private var customDates: (start: Date, end: Date) {
    if case let .custom(start, end) = store.window {
      return (start, end)
    }
    return store.window.dateRange()
  }

  private func applyMode(_ newMode: Mode) {
    switch newMode {
    case .sevenDays:
      store.setWindow(.last7Days)
    case .thirtyDays:
      store.setWindow(.last30Days)
    case .custom:
      let dates = customDates
      store.setWindow(.custom(start: dates.start, end: dates.end))
    }
  }
}

// MARK: - ApiUsageCard

/// One provider's API tokens plus an approximate cost over the selected window.
/// API usage has no cap, so this does not show a quota percentage.
struct ApiUsageCard: View {
  let provider: ApiProvider
  let usage: ApiUsage?
  let isLoading: Bool
  var compact: Bool = false

  private var accent: Color { MeterBarTheme.accent(for: provider) }

  var body: some View {
    DashboardTile(
      cornerRadius: MeterBarTheme.apiCardRadius,
      padding: compact ? MeterBarTheme.Spacing.sm : MeterBarTheme.Spacing.md
    ) {
      VStack(alignment: .leading, spacing: compact ? 8 : 10) {
        HStack(spacing: 7) {
          ProviderLogoView(
            kind: .forApiProvider(provider),
            size: compact ? 17 : 18,
            foregroundColor: accent
          )
          Text(provider.displayName)
            .font(compact ? .subheadline : .headline)
            .fontWeight(.semibold)
          Spacer(minLength: 8)
          Text("Est. \(UsageFormat.cost(usage?.estimatedCostUSD ?? 0))")
            .font(compact ? .headline : .title3)
            .bold()
            .monospacedDigit()
            .foregroundColor(accent)
        }

        if isLoading, usage == nil {
          Text("Loading usage…")
            .font(.caption)
            .foregroundColor(.secondary)
        } else if let usage, usage.hasData {
          Text(tokenSummary(usage))
            .font(.caption)
            .foregroundColor(.secondary)

          ForEach(topModels(usage)) { model in
            HStack(spacing: 8) {
              Text(model.model)
                .font(.caption2)
                .lineLimit(1)
              Spacer(minLength: 6)
              Text(UsageFormat.tokens(model.totalTokens))
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
              Text(UsageFormat.cost(model.estimatedCostUSD))
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
            }
          }
        } else {
          Text("No API usage in this window.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
  }

  private func tokenSummary(_ usage: ApiUsage) -> String {
    "\(UsageFormat.tokens(usage.totalTokens)) tokens · "
      + "\(UsageFormat.tokens(usage.inputTokens)) in / \(UsageFormat.tokens(usage.outputTokens)) out"
  }

  private func topModels(_ usage: ApiUsage) -> [ApiModelUsage] {
    Array(usage.models.prefix(compact ? 2 : 4))
  }
}
