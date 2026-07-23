import MeterBarShared
import SwiftUI

// MARK: - Widget settings account projection

struct WidgetSettingsAccountOption: Equatable, Identifiable {
    let id: WidgetAccountIdentifier
    let service: ServiceType
    let name: String
}

enum WidgetSettingsAccountProjection {
    static func options(
        enabledServices: Set<ServiceType>,
        claudeAccounts: [ClaudeCodeAccount],
        codexAccounts: [CodexAccount]
    ) -> [WidgetSettingsAccountOption] {
        ServiceType.allCases.flatMap { service -> [WidgetSettingsAccountOption] in
            guard enabledServices.contains(service) else { return [] }

            switch service {
            case .claudeCode:
                return claudeAccounts.filter(\.isEnabled).map {
                    WidgetSettingsAccountOption(
                        id: .account(service: service, id: $0.id),
                        service: service,
                        name: $0.name
                    )
                }
            case .codexCli:
                return codexAccounts.filter(\.isEnabled).map {
                    WidgetSettingsAccountOption(
                        id: .account(service: service, id: $0.id),
                        service: service,
                        name: $0.name
                    )
                }
            case .cursor, .openRouter, .grok:
                return [
                    WidgetSettingsAccountOption(
                        id: .provider(service),
                        service: service,
                        name: service.displayName
                    )
                ]
            }
        }
    }
}

enum WidgetSettingsSelection {
    static func contains(
        _ identifier: WidgetAccountIdentifier,
        selection: WidgetAccountSelection
    ) -> Bool {
        switch selection.mode {
        case .all:
            return true
        case .explicit:
            return selection.explicitIdentifiers.contains(identifier)
        }
    }

    static func toggling(
        _ identifier: WidgetAccountIdentifier,
        isSelected: Bool,
        selection: WidgetAccountSelection,
        availableIdentifiers: Set<WidgetAccountIdentifier>
    ) -> WidgetAccountSelection {
        var selected = selection.mode == .all
            ? availableIdentifiers
            : selection.explicitIdentifiers.intersection(availableIdentifiers)

        if isSelected {
            selected.insert(identifier)
        } else {
            selected.remove(identifier)
        }

        return selected == availableIdentifiers && !availableIdentifiers.isEmpty
            ? .all
            : .explicit(selected)
    }
}

// MARK: - Widget preview data

struct WidgetSettingsPreviewData {
    let metrics: [ServiceType: UsageMetrics]
    let accountMetrics: [AccountUsageSnapshot]
    let usesPlaceholders: Bool

    static func make(
        options: [WidgetSettingsAccountOption],
        metrics: [ServiceType: UsageMetrics],
        claudeAccountMetrics: [UUID: UsageMetrics],
        codexAccountMetrics: [UUID: UsageMetrics],
        now: Date = Date()
    ) -> Self {
        let optionIDs = Set(options.map(\.id))
        let providerServices = Set(options.compactMap { option -> ServiceType? in
            option.id == .provider(option.service) ? option.service : nil
        })
        let filteredMetrics = metrics.filter { providerServices.contains($0.key) && $0.value.hasData }
        let filteredAccountMetrics = options.compactMap { option -> AccountUsageSnapshot? in
            guard let accountID = accountUUID(from: option.id) else { return nil }
            let accountMetrics: UsageMetrics?
            switch option.service {
            case .claudeCode:
                accountMetrics = claudeAccountMetrics[accountID]
            case .codexCli:
                accountMetrics = codexAccountMetrics[accountID]
            case .cursor, .openRouter, .grok:
                accountMetrics = nil
            }
            guard optionIDs.contains(option.id), let accountMetrics, accountMetrics.hasData else {
                return nil
            }
            return AccountUsageSnapshot(id: accountID, name: option.name, metrics: accountMetrics)
        }

        if !filteredMetrics.isEmpty || !filteredAccountMetrics.isEmpty {
            return Self(
                metrics: filteredMetrics,
                accountMetrics: filteredAccountMetrics,
                usesPlaceholders: false
            )
        }

        var placeholderMetrics: [ServiceType: UsageMetrics] = [:]
        var placeholderAccountMetrics: [AccountUsageSnapshot] = []
        for (index, option) in options.enumerated() {
            let sample = sampleMetrics(
                service: option.service,
                index: index,
                now: now
            )
            if option.id == .provider(option.service) {
                placeholderMetrics[option.service] = sample
            } else if let id = accountUUID(from: option.id) {
                placeholderAccountMetrics.append(
                    AccountUsageSnapshot(id: id, name: option.name, metrics: sample)
                )
            }
        }
        return Self(
            metrics: placeholderMetrics,
            accountMetrics: placeholderAccountMetrics,
            usesPlaceholders: !options.isEmpty
        )
    }

    private static func accountUUID(from identifier: WidgetAccountIdentifier) -> UUID? {
        let components = identifier.rawValue.split(separator: ":", maxSplits: 2)
        guard components.count == 3, components[0] == "account" else { return nil }
        return UUID(uuidString: String(components[2]))
    }

    private static func sampleMetrics(
        service: ServiceType,
        index: Int,
        now: Date
    ) -> UsageMetrics {
        let used = [28.0, 54.0, 76.0, 41.0, 63.0][index % 5]
        return UsageMetrics(
            service: service,
            sessionLimit: UsageLimit(
                used: max(10, used - 12),
                total: 100,
                resetTime: now.addingTimeInterval(90 * 60)
            ),
            weeklyLimit: UsageLimit(
                used: used,
                total: 100,
                resetTime: now.addingTimeInterval(3 * 24 * 60 * 60)
            ),
            codeReviewLimit: service == .claudeCode
                ? UsageLimit(
                    used: min(92, used + 8),
                    total: 100,
                    resetTime: now.addingTimeInterval(5 * 24 * 60 * 60)
                )
                : nil,
            lastUpdated: now
        )
    }
}

// MARK: - WidgetSettingsView

struct WidgetSettingsView: View {
    @StateObject private var preferencesStore = WidgetPreferencesStore.shared
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var codexAccountStore = CodexAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @State private var previewAppearance: WidgetSettingsPreviewAppearance = .light

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountsSection
            presentationSection
            previewsSection
            addWidgetSection
        }
        .onAppear(perform: reconcileExplicitSelection)
        .onChange(of: accountOptions) {
            reconcileExplicitSelection()
        }
    }

    private var accountOptions: [WidgetSettingsAccountOption] {
        WidgetSettingsAccountProjection.options(
            enabledServices: providerVisibility.enabledServices,
            claudeAccounts: claudeAccountStore.accounts,
            codexAccounts: codexAccountStore.accounts
        )
    }

    private var availableIdentifiers: Set<WidgetAccountIdentifier> {
        Set(accountOptions.map(\.id))
    }

    private var groupedAccountOptions: [(service: ServiceType, options: [WidgetSettingsAccountOption])] {
        ServiceType.allCases.compactMap { service in
            let options = accountOptions.filter { $0.service == service }
            return options.isEmpty ? nil : (service, options)
        }
    }

    private var accountsSection: some View {
        SettingsPanelSection(
            title: "Accounts",
            systemImage: "person.2",
            color: MeterBarTheme.appAccent
        ) {
            SettingsRowView(
                title: "Show all enabled",
                detail: "New enabled accounts are included automatically."
            ) {
                Toggle("Show all enabled", isOn: selectAllBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(accountOptions.isEmpty)
            }

            if accountOptions.isEmpty {
                EmptyStateCard(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "No enabled accounts",
                    message: "Enable a provider and account in General or Providers settings."
                )
            } else {
                ForEach(groupedAccountOptions, id: \.service) { group in
                    SettingsDivider()
                    Text(group.service.displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    ForEach(group.options) { option in
                        SettingsRowView(title: option.name) {
                            Toggle(
                                option.name,
                                isOn: accountSelectionBinding(for: option.id)
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
            }
        }
    }

    private var presentationSection: some View {
        SettingsPanelSection(
            title: "Presentation",
            systemImage: "slider.horizontal.3",
            color: MeterBarTheme.appAccent
        ) {
            SettingsRowView(
                title: "Usage value",
                detail: "Show how much quota is used or remains."
            ) {
                Picker("Usage value", selection: displayModeBinding) {
                    ForEach(WidgetUsageDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.settingsTitle).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            SettingsDivider()
            Text("Quota windows")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(WidgetQuotaWindow.allCases, id: \.self) { window in
                SettingsRowView(title: window.settingsTitle) {
                    Toggle(
                        window.settingsTitle,
                        isOn: quotaWindowBinding(for: window)
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            SettingsDivider()
            SettingsRowView(title: "Reset times") {
                Toggle("Reset times", isOn: showsResetTimeBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsRowView(title: "Data freshness") {
                Toggle("Data freshness", isOn: showsFreshnessBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsRowView(title: "Account order") {
                Picker("Account order", selection: accountOrderingBinding) {
                    ForEach(WidgetAccountOrdering.allCases, id: \.self) { ordering in
                        Text(ordering.settingsTitle).tag(ordering)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private var previewsSection: some View {
        SettingsPanelSection(
            title: "Previews",
            systemImage: "rectangle.3.group",
            color: MeterBarTheme.appAccent
        ) {
            SettingsRowView(
                title: "Appearance",
                detail: "Check contrast across macOS widget rendering styles."
            ) {
                Picker("Appearance", selection: $previewAppearance) {
                    ForEach(WidgetSettingsPreviewAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if previewData.usesPlaceholders {
                SettingsNotice(
                    text: "Previewing sample values until cached usage is available.",
                    color: .secondary
                )
            }

            WidgetSettingsPreviewGallery(
                data: previewData,
                preferences: preferencesStore.preferences,
                appearance: previewAppearance
            )
        }
    }

    private var addWidgetSection: some View {
        SettingsPanelSection(
            title: "Add MeterBar to macOS",
            systemImage: "plus.rectangle.on.rectangle",
            color: MeterBarTheme.appAccent
        ) {
            SettingsNotice(
                text: "1. Control-click the desktop and choose Edit Widgets.",
                color: .primary
            )
            SettingsNotice(
                text: "2. Search for MeterBar, choose Small, Medium, or Large, then drag it into place.",
                color: .primary
            )
            SettingsNotice(
                text: "macOS owns widget placement; MeterBar cannot add or move widgets for you.",
                color: .secondary
            )
        }
    }

    private var previewData: WidgetSettingsPreviewData {
        WidgetSettingsPreviewData.make(
            options: accountOptions,
            metrics: dataManager.metrics,
            claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
            codexAccountMetrics: dataManager.codexAccountMetrics
        )
    }

    private var selectAllBinding: Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.accountSelection.mode == .all },
            set: { selectsAll in
                if selectsAll {
                    preferencesStore.selectAllAccounts()
                } else {
                    preferencesStore.setSelectedAccounts([])
                }
            }
        )
    }

    private func accountSelectionBinding(
        for identifier: WidgetAccountIdentifier
    ) -> Binding<Bool> {
        Binding(
            get: {
                WidgetSettingsSelection.contains(
                    identifier,
                    selection: preferencesStore.preferences.accountSelection
                )
            },
            set: { isSelected in
                let selection = WidgetSettingsSelection.toggling(
                    identifier,
                    isSelected: isSelected,
                    selection: preferencesStore.preferences.accountSelection,
                    availableIdentifiers: availableIdentifiers
                )
                switch selection.mode {
                case .all:
                    preferencesStore.selectAllAccounts()
                case .explicit:
                    preferencesStore.setSelectedAccounts(selection.explicitIdentifiers)
                }
            }
        )
    }

    private var displayModeBinding: Binding<WidgetUsageDisplayMode> {
        Binding(
            get: { preferencesStore.preferences.displayMode },
            set: { preferencesStore.setDisplayMode($0) }
        )
    }

    private func quotaWindowBinding(for window: WidgetQuotaWindow) -> Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.visibleQuotaWindows.contains(window) },
            set: { isVisible in
                var windows = preferencesStore.preferences.visibleQuotaWindows
                if isVisible {
                    windows.insert(window)
                } else {
                    windows.remove(window)
                }
                preferencesStore.setVisibleQuotaWindows(windows)
            }
        )
    }

    private var showsResetTimeBinding: Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.showsResetTime },
            set: { preferencesStore.setShowsResetTime($0) }
        )
    }

    private var showsFreshnessBinding: Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.showsFreshness },
            set: { preferencesStore.setShowsFreshness($0) }
        )
    }

    private var accountOrderingBinding: Binding<WidgetAccountOrdering> {
        Binding(
            get: { preferencesStore.preferences.accountOrdering },
            set: { preferencesStore.setAccountOrdering($0) }
        )
    }

    private func reconcileExplicitSelection() {
        let selection = preferencesStore.preferences.accountSelection
        guard selection.mode == .explicit else { return }
        let reconciled = selection.explicitIdentifiers.intersection(availableIdentifiers)
        guard reconciled != selection.explicitIdentifiers else { return }
        preferencesStore.setSelectedAccounts(reconciled)
    }
}

// MARK: - Preview gallery

enum WidgetSettingsPreviewAppearance: String, CaseIterable, Equatable, Identifiable {
    case light
    case dark
    case accented
    case grayscale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .accented: return "Accented"
        case .grayscale: return "Grayscale"
        }
    }

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }

    var background: Color {
        switch self {
        case .light:
            return Color(white: 0.96)
        case .dark:
            return Color(white: 0.10)
        case .accented:
            return MeterBarTheme.appAccent.opacity(0.18)
        case .grayscale:
            return Color(white: 0.88)
        }
    }
}

struct WidgetSettingsPreviewGallery: View {
    let data: WidgetSettingsPreviewData
    let preferences: WidgetPreferences
    let appearance: WidgetSettingsPreviewAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                preview(for: .small)
                preview(for: .medium)
            }
            preview(for: .large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preview(for family: WidgetPresentationFamily) -> some View {
        let presentation = WidgetPresentationPlanner.makePresentation(
            metrics: data.metrics,
            accountMetrics: data.accountMetrics,
            preferences: preferences,
            family: family,
            now: Date()
        )
        return VStack(alignment: .leading, spacing: 5) {
            Text(family.settingsTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            WidgetSettingsPreviewSurface(
                family: family,
                presentation: presentation,
                appearance: appearance
            )
        }
    }
}

struct WidgetSettingsPreviewSurface: View {
    let family: WidgetPresentationFamily
    let presentation: WidgetPresentation
    let appearance: WidgetSettingsPreviewAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: family.isLarge ? 8 : 5) {
            if let emptyState = presentation.emptyState {
                Spacer()
                Image(systemName: emptyState == .noSelection ? "slider.horizontal.3" : "exclamationmark.triangle")
                Text(emptyState.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(emptyState.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(presentation.rows) { row in
                    WidgetSettingsPreviewRow(row: row, compact: family.isSmall)
                }
                if presentation.hiddenRowCount > 0 {
                    Label(
                        "+\(presentation.hiddenRowCount) more",
                        systemImage: "ellipsis.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(family.isSmall ? 10 : 12)
        .frame(
            width: family.previewSize.width,
            height: family.previewSize.height,
            alignment: .topLeading
        )
        .background(appearance.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        }
        .environment(\.colorScheme, appearance.colorScheme)
        .saturation(appearance == .grayscale ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(family.settingsTitle) widget preview")
    }
}

struct WidgetSettingsPreviewRow: View {
    let row: WidgetPresentationRow
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: row.service.iconName)
                    .frame(width: compact ? 11 : 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.accountName)
                        .font(compact ? .caption2 : .caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(row.quotaTitle)
                        .font(.system(size: compact ? 7 : 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                Text(compact ? row.compactSummaryText : row.summaryText)
                    .font(.system(size: compact ? 7 : 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let value = row.progressValue, let total = row.progressTotal {
                ProgressView(value: value, total: total)
                    .tint(row.usageStatus.previewColor)
            }

            if row.resetTime != nil || row.freshnessDate != nil {
                HStack(spacing: 5) {
                    if let resetTime = row.resetTime {
                        Label {
                            Text(resetTime, style: .relative)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    if let freshnessDate = row.freshnessDate {
                        Label {
                            Text(freshnessDate, style: .relative)
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                }
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension Optional where Wrapped == UsageStatus {
    var previewColor: Color {
        switch self {
        case .some(.good):
            return .green
        case .some(.warning):
            return .orange
        case .some(.critical):
            return .red
        case .none:
            return .secondary
        }
    }
}

private extension WidgetPresentationFamily {
    var isLarge: Bool {
        if case .large = self {
            return true
        }
        return false
    }

    var isSmall: Bool {
        if case .small = self {
            return true
        }
        return false
    }

    var settingsTitle: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var previewSize: CGSize {
        switch self {
        case .small: return CGSize(width: 150, height: 150)
        case .medium: return CGSize(width: 310, height: 150)
        case .large: return CGSize(width: 310, height: 300)
        }
    }
}

private extension WidgetUsageDisplayMode {
    var settingsTitle: String {
        switch self {
        case .remaining: return "Remaining"
        case .used: return "Used"
        }
    }
}

private extension WidgetQuotaWindow {
    var settingsTitle: String {
        switch self {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .codeReview: return "Code Review"
        }
    }
}

private extension WidgetAccountOrdering {
    var settingsTitle: String {
        switch self {
        case .provider: return "Provider"
        case .urgency: return "Urgency"
        }
    }
}
