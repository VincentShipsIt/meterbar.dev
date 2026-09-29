import MeterBarShared
import SwiftUI

/// Z.ai's Providers-settings panel: the Coding Plan key (Keychain), the region
/// the key belongs to, the plan tier the API names, and today's peak/off-peak
/// window.
struct ZaiCodingPlanSettingsSection: View {
    let onChange: () -> Void

    var body: some View {
        SingleKeyProviderSettingsSection(
            service: .zaiCodingPlan,
            logoKind: .zaiCodingPlan,
            accent: MeterBarTheme.zaiCodingPlanAccent,
            notice: String(
                localized: "settings.zai.notice",
                defaultValue: """
                Paste your GLM Coding Plan API key. It is stored in macOS Keychain and sent only to \
                Z.ai's quota endpoint for the region you choose. MeterBar shows only the limits Z.ai \
                reports for your key.
                """
            ),
            keyPlaceholder: String(localized: "settings.zai.key_placeholder", defaultValue: "GLM Coding Plan API key"),
            helpURL: nil,
            helpTitle: "",
            hasAccess: service.hasAccess,
            hasKey: service.hasAPIKey,
            lastError: service.lastError,
            unauthenticatedDetail: String(
                localized: "settings.zai.unauthenticated",
                defaultValue: "Z.ai rejected the key. Check that it is a Coding Plan key for the selected region."
            ),
            onSaveKey: { value in
                let saved = service.saveAPIKey(value)
                if saved { onChange() }
                return saved
            },
            onRemoveKey: {
                service.removeAPIKey()
                onChange()
            },
            extra: {
                SettingsRowView(title: String(localized: "settings.zai.region", defaultValue: "Region")) {
                    Picker("", selection: regionBinding) {
                        ForEach(ZaiCodingPlanRegion.allCases, id: \.self) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsRowView(
                    title: String(localized: "settings.zai.pricing", defaultValue: "Credit rate"),
                    detail: ZaiPeakPresentation.explanation
                ) {
                    Text(ZaiPeakPresentation.label(ZaiPeakSchedule.status(at: Date())))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        )
    }

    @ObservedObject private var service = ZaiCodingPlanService.shared
    @State private var region = ZaiRegionSetting.current()

    private var regionBinding: Binding<ZaiCodingPlanRegion> {
        Binding(
            get: { region },
            set: { newValue in
                region = newValue
                ZaiRegionSetting.save(newValue)
                onChange()
            }
        )
    }
}
