import Foundation

/// What the xAI settings pane says about its two data sources as one provider.
///
/// xAI is a single subscription read through the Grok CLI's billing call and
/// the Cursor dashboard, so Settings shows one connection status and one plan
/// label instead of a section (and a plan row) per source.
nonisolated struct XAISettingsSummary: Equatable, Sendable {
    let grokConnected: Bool
    let cursorConnected: Bool
    /// Raw tier tokens, reported only by the matching source.
    let grokPlan: String?
    let cursorPlan: String?

    var isConnected: Bool {
        grokConnected || cursorConnected
    }

    var statusTitle: String {
        isConnected ? "Connected" : "Not Connected"
    }

    var sourcesText: String {
        switch (grokConnected, cursorConnected) {
        case (true, true): "Grok CLI + Cursor"
        case (true, false): "Grok CLI"
        case (false, true): "Cursor"
        case (false, false): "No source connected"
        }
    }

    /// One label for both sources. Grok's billing tier ("SuperGrok Heavy") is
    /// the more specific name, so it wins; Cursor's coarser token ("ultra") is
    /// only the fallback.
    var planLabel: String? {
        if grokConnected, let plan = grokPlan?.nilIfEmpty {
            return plan
        }
        guard cursorConnected, let plan = cursorPlan?.nilIfEmpty else { return nil }
        return plan == plan.lowercased() ? plan.capitalized : plan
    }
}
