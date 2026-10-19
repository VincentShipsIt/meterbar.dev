import Foundation
import MeterBarShared

// Plain-language names for the policy fields the editor lets people change. The
// raw values are the on-disk format and stay out of the interface.

extension RoutingProviderScope {
    var title: String {
        switch self {
        case .anyProvider: "Any provider"
        case .preferredOnly: "Preferred only"
        }
    }

    var help: String {
        switch self {
        case .anyProvider: "Preferred providers rank higher, but any provider can be recommended."
        case .preferredOnly: "Only the providers chosen below can be recommended."
        }
    }
}

extension RoutingAccountSelection {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .preferred: "Prefer chosen"
        case .restricted: "Only chosen"
        }
    }

    var help: String {
        switch self {
        case .automatic: "Every account competes on remaining quota."
        case .preferred: "Chosen accounts rank higher; the others stay eligible."
        case .restricted: "A provider with chosen accounts is limited to exactly those."
        }
    }
}

extension RoutingModelTier {
    var title: String {
        switch self {
        case .economy: "Economy"
        case .standard: "Standard"
        case .premium: "Premium"
        }
    }
}

extension RoutingCostPreference {
    var title: String {
        switch self {
        case .headroom: "Most headroom"
        case .balanced: "Balanced"
        case .cost: "Lowest cost"
        }
    }

    var help: String {
        switch self {
        case .headroom: "Rank on remaining quota alone."
        case .balanced: "Lean toward included quota over pay-per-use spend."
        case .cost: "Strongly prefer included quota over pay-per-use spend."
        }
    }
}

extension RoutingFallbackOrder {
    var title: String {
        switch self {
        case .score: "By score"
        case .policyPreference: "By preference"
        }
    }
}
