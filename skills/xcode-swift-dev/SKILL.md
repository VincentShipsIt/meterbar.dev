---
name: xcode-swift-dev
description: Expert in Swift/SwiftUI development for macOS menu bar apps, iOS apps, widgets, and Xcode project configuration. Use for Swift architecture, SwiftUI patterns, App Intents, WidgetKit, and native Apple platform development.
---

# Xcode Swift Developer

Expert guidance for native Apple platform development with Swift and SwiftUI.

## When to Use

- Building macOS menu bar apps
- Creating iOS/macOS widgets (WidgetKit)
- Implementing App Intents and Shortcuts
- SwiftUI component architecture
- Xcode project configuration
- Swift Package Manager setup
- Code signing and entitlements
- App Store / TestFlight preparation

## Core Principles

### SwiftUI Architecture

- Use MVVM with `@Observable` (iOS 17+) or `ObservableObject`
- Prefer composition over inheritance
- Keep views small and focused
- Extract reusable components to separate files

### Project Structure (macOS Menu Bar App)

```
AppName/
├── App/
│   └── AppNameApp.swift          # @main entry point
├── Models/
│   ├── ServiceType.swift         # Enums and data models
│   └── UsageMetrics.swift        # Core data structures
├── Services/
│   ├── ServiceManager.swift      # Business logic
│   ├── KeychainManager.swift     # Secure storage
│   └── APIClient.swift           # Network layer
├── Views/
│   ├── MenuBarView.swift         # Main menu bar content
│   ├── SettingsView.swift        # Preferences window
│   └── Components/               # Reusable UI components
└── Info.plist

AppNameWidget/
├── AppNameWidgetBundle.swift     # Widget bundle entry
├── UsageWidget.swift             # Widget implementation
├── Assets.xcassets/
└── Info.plist
```

### Menu Bar App Pattern

```swift
@main
struct AppNameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("App Name", systemImage: "chart.bar") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
```

### Widget Development

- Use `TimelineProvider` for data updates
- Keep widget views lightweight
- Support multiple widget families (small, medium, large)
- Use `@Environment(\.widgetFamily)` for adaptive layouts
- Share data via App Groups

### Keychain Best Practices

- Use `kSecClassGenericPassword` for API keys
- Set `kSecAttrAccessible` appropriately
- Group related items with `kSecAttrService`
- Handle errors gracefully (item not found, access denied)

### Swift Concurrency

- Use `async/await` for asynchronous operations
- Mark main-thread-bound code with `@MainActor`
- Use `Task` for launching async work from sync contexts
- Prefer `AsyncStream` for continuous data

### Code Signing & Entitlements

Common entitlements for menu bar apps:
- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.keychain-access-groups`
- `com.apple.security.application-groups` (for widget data sharing)

### SwiftLint Configuration

```yaml
disabled_rules:
  - line_length
  - trailing_whitespace

opt_in_rules:
  - empty_count
  - closure_spacing
  - force_unwrapping

excluded:
  - .build
  - .swiftpm
```

## Common Patterns

### API Client

```swift
actor APIClient {
    private let session = URLSession.shared
    private let baseURL: URL

    func fetch<T: Decodable>(_ endpoint: String) async throws -> T {
        let url = baseURL.appendingPathComponent(endpoint)
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
```

### Shared Data Store (App Groups)

```swift
final class SharedDataStore {
    static let shared = SharedDataStore()

    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: "group.com.company.appname")!
    }

    var usageData: UsageData? {
        get {
            guard let data = defaults.data(forKey: "usageData") else { return nil }
            return try? JSONDecoder().decode(UsageData.self, from: data)
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: "usageData")
        }
    }
}
```

## File Naming Conventions

- Views: `*View.swift` (e.g., `SettingsView.swift`)
- Models: Descriptive nouns (e.g., `UsageMetrics.swift`)
- Services: `*Manager.swift` or `*Service.swift`
- Extensions: `Type+Extension.swift`
- Protocols: `*Protocol.swift` or `*able.swift`

## Testing

- Use XCTest for unit tests
- Test business logic in Services
- Use `@testable import` for internal access
- Mock network with URLProtocol
- Snapshot test SwiftUI views with swift-snapshot-testing

## Build Configuration

### Debug vs Release

- Use `#if DEBUG` for debug-only code
- Configure schemes for different environments
- Use `.xcconfig` files for build settings
- Keep secrets out of source (use Keychain or secure config)

