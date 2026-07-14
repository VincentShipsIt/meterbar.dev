import AppKit
import MeterBarShared
import SwiftUI

// Reusable Settings chrome extracted from the SettingsView monolith (R-settings
// split). Pure move: these primitives are shared by every settings tab, so they
// live alongside the other view components rather than buried in one 2k-line
// file. Types that previously had to be `private` in SettingsView.swift are now
// `internal` so the per-tab views can reuse them.

// MARK: - SettingsRowViewMetrics

enum SettingsRowViewMetrics {
    static let labelWidth: CGFloat = 190
}

// MARK: - SettingsInfoRow

/// A read-only label/value row used by the provider overview panels.
struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.semibold)
                .frame(width: SettingsRowViewMetrics.labelWidth, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsPanelSection

struct SettingsPanelSection<Content: View>: View {
    // MARK: Lifecycle

    init(
        title: String,
        logoKind: ProviderLogoKind,
        color: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.logoKind = logoKind
        self.systemImage = nil
        self.color = color
        self.content = content()
    }

    init(
        title: String,
        systemImage: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.logoKind = nil
        self.systemImage = systemImage
        self.color = color
        self.content = content()
    }

    // MARK: Internal

    let title: String
    let logoKind: ProviderLogoKind?
    let systemImage: String?
    let color: Color
    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let logoKind {
                    ProviderLogoView(kind: logoKind, size: 14, foregroundColor: color)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(color)
                }
                Text(title)
            }
            .font(.subheadline)
            .fontWeight(.semibold)

            DashboardTile(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - SettingsRowView

struct SettingsRowView<Content: View>: View {
    // MARK: Lifecycle

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    // MARK: Internal

    let title: String
    let detail: String?
    let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: SettingsRowViewMetrics.labelWidth, alignment: .leading)
            // Read the title and its explanatory detail as one VoiceOver element
            // rather than two adjacent fragments. The trailing control stays a
            // separate focusable element so its own label/actuation are intact.
            .accessibilityElement(children: .combine)

            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsNotice

struct SettingsNotice: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsDivider

struct SettingsDivider: View {
    var body: some View {
        Divider()
    }
}

// MARK: - StatusPill

struct StatusPill: View {
    let title: String
    let isConnected: Bool

    var body: some View {
        Label(title, systemImage: isConnected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isConnected ? MeterBarTheme.success : Color.secondary)
            .font(.subheadline)
    }
}

// MARK: - ExtraUsageRow

/// The "Extra Usage / Credits" row shown both in the API Usage tab (cross
/// provider) and in each provider's own settings pane. Extracted so the two
/// call sites share one definition of the pill + manage button + detail copy.
struct ExtraUsageRow: View {
    let title: String
    let status: ExtraUsageStatus?
    let manageURL: String

    var body: some View {
        SettingsRowView(title: title, detail: Self.detailText(status)) {
            HStack(spacing: 8) {
                ExtraUsageStatusPill(status: status ?? .unknown)

                Button("Manage") {
                    if let url = URL(string: manageURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .help("Open \(manageURL) to change extra usage settings")
            }
        }
    }

    static func detailText(_ status: ExtraUsageStatus?) -> String {
        guard let status else {
            return "Waiting for refresh."
        }
        switch status.state {
        case .on:
            return status.detail.map { "Enabled · \($0)" } ?? "Enabled — overage can be billed beyond your plan."
        case .off:
            return "Disabled — capped at your subscription quota."
        case .unknown:
            return "Could not determine. Sign in to the CLI and refresh."
        }
    }
}

// MARK: - AdminKeySettingsRow

struct AdminKeySettingsRow: View {
    // MARK: Internal

    let provider: ApiProvider
    let connected: Bool
    @Binding var draft: String

    let placeholder: String
    let onSave: () -> Void
    let onRemove: () -> Void
    let onHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(connected ? connectedMessage : "Required for organization usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusPill(title: connected ? "Connected" : "Not Connected", isConnected: connected)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                if connected {
                    SettingsReadonlyField(text: "••••••••••••••••")

                    Button("Remove", role: .destructive, action: onRemove)
                        .buttonStyle(.bordered)
                } else {
                    SecureField(placeholder, text: $draft)
                        .settingsInput()
                        .frame(minWidth: 220, maxWidth: 340)

                    Button("Save", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedDraft.isEmpty)

                    Button(action: onHelp) {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Where to create this admin API key")
                }
            }
        }
        .padding(.vertical, MeterBarTheme.Spacing.sm)
    }

    // MARK: Private

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var connectedMessage: String {
        "Connected. Estimated usage appears on the API cost card."
    }
}

// MARK: - SettingsReadonlyField

struct SettingsReadonlyField: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .settingsInputSurface(width: 280)
            .help(text)
    }
}

// MARK: - SettingsInputModifier

private struct SettingsInputModifier: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.subheadline)
            .lineLimit(1)
            .settingsInputSurface(width: width)
    }
}

// MARK: - SettingsInputSurfaceModifier

private struct SettingsInputSurfaceModifier: ViewModifier {
    let width: CGFloat?
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        // The capsule variant moved to `MeterBarChip(style: .glass)`; this
        // surface now only backs rounded-rectangle settings input fields.
        let roundedRectangle = RoundedRectangle(cornerRadius: MeterBarTheme.Radius.medium, style: .continuous)

        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            // Leading, not centered: a read-only path (or any value shorter than
            // the field) must hug the left edge like a real text input, not float
            // in the middle of the field.
            .frame(width: width, alignment: .leading)
            .background(.thinMaterial, in: roundedRectangle)
            .overlay {
                roundedRectangle.stroke(MeterBarTheme.glassCardStroke, lineWidth: 0.5)
            }
    }
}

extension View {
    func settingsInput(width: CGFloat? = nil) -> some View {
        modifier(SettingsInputModifier(width: width))
    }

    func settingsInputSurface(
        width: CGFloat? = nil,
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 6
    ) -> some View {
        modifier(
            SettingsInputSurfaceModifier(
                width: width,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            )
        )
    }
}
