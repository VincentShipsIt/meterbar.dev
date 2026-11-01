/// Stable WidgetKit identifiers shared by registration and every reload path.
/// Changing one removes an installed widget from the user's desktop, so these
/// values are intentionally pinned by tests.
public enum MeterBarWidgetKind {
    public static let usage = "UsageWidget"
    public static let burnDown = "BurnDownWidget"
    /// Control Center style tiles, matching the popover: the tightest limit
    /// on the small size, every provider side by side on the medium.
    public static let tiles = "TilesWidget"
    public static let all = [usage, burnDown, tiles]
}
