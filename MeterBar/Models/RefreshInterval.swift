import Foundation

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case manual = 0

    static let defaultInterval: RefreshInterval = .tenMinutes

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .oneMinute:
            return "1 minute"
        case .twoMinutes:
            return "2 minutes"
        case .fiveMinutes:
            return "5 minutes"
        case .tenMinutes:
            return "10 minutes"
        case .fifteenMinutes:
            return "15 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        case .manual:
            return "Manual only"
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue)
    }
}
