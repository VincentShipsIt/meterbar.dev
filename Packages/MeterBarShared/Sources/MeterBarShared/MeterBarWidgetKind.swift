/// Stable WidgetKit identifiers shared by registration and every reload path.
/// Changing one removes an installed widget from the user's desktop, so these
/// values are intentionally pinned by tests.
public enum MeterBarWidgetKind {
    public static let usage = "UsageWidget"
    public static let burnDown = "BurnDownWidget"
    public static let all = [usage, burnDown]
}
