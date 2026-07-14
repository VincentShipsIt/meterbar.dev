import SwiftUI

/// The single empty/not-connected/error placeholder used across MeterBar's
/// settings and dashboard surfaces.
///
/// Before this existed, each surface hand-rolled its own treatment: providers
/// stacked two differently-worded `SettingsNotice`s, the cost and usage sections
/// invented near-duplicate "no data" strings, and the social share card even
/// faked a chart. `EmptyStateCard` gives all of them one shape — icon, title,
/// one-line explanation, and an optional recovery button — and one copy tone
/// (short, action-oriented). Callers only supply the words that genuinely
/// differ (e.g. "Run `codex login`" vs "Log in to Cursor IDE").
///
/// It renders as lightweight inline content (no tile of its own) so it drops
/// straight into a `SettingsPanelSection`, which already provides the card
/// surface.
struct EmptyStateCard: View {
    // MARK: Internal

    /// Visual weight of the state. `.neutral` reads as informational (nothing is
    /// wrong — just no data yet); `.warning` signals the user must act to
    /// proceed (sign in, enable a provider, fix a key).
    enum Tone {
        case neutral
        case warning

        var tint: Color {
            switch self {
            case .neutral:
                .secondary
            case .warning:
                MeterBarTheme.warning
            }
        }
    }

    let systemImage: String
    let title: String
    let message: String
    var tone: Tone = .neutral
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.tint)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
