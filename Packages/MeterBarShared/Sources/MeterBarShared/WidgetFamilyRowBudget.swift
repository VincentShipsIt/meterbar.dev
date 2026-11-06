public enum WidgetPresentationFamily: CaseIterable, Sendable {
    case small
    case medium
    case large

    public var maximumSlots: Int {
        switch self {
        case .small, .medium:
            return 3
        case .large:
            return 7
        }
    }
}

public struct WidgetFamilyRowBudget: Equatable, Sendable {
    public let visibleRowCount: Int
    public let hiddenRowCount: Int

    public init(visibleRowCount: Int, hiddenRowCount: Int) {
        self.visibleRowCount = visibleRowCount
        self.hiddenRowCount = hiddenRowCount
    }

    public static func plan(
        totalRowCount: Int,
        family: WidgetPresentationFamily,
        showsDetails: Bool = false
    ) -> Self {
        let total = max(0, totalRowCount)
        let visible: Int
        if showsDetails {
            let detailedRowCapacity: Int
            switch family {
            case .small:
                detailedRowCapacity = 3
            case .medium:
                detailedRowCapacity = 2
            case .large:
                detailedRowCapacity = 5
            }
            visible = min(total, detailedRowCapacity)
        } else {
            let maximumSlots = family.maximumSlots
            visible = total > maximumSlots ? maximumSlots - 1 : total
        }
        return Self(
            visibleRowCount: visible,
            hiddenRowCount: max(0, total - visible)
        )
    }
}
