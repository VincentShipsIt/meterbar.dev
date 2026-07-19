public enum MediumWidgetRowBudget {
    public static let maximumSlots = 3

    public static func visibleRowCount(totalRowCount: Int) -> Int {
        guard totalRowCount > maximumSlots else { return max(0, totalRowCount) }
        return maximumSlots - 1
    }

    public static func hiddenRowCount(totalRowCount: Int) -> Int {
        max(0, totalRowCount - visibleRowCount(totalRowCount: totalRowCount))
    }
}
