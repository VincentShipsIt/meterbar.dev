---
name: macos-menubar-app
description: Expert in building macOS menu bar applications with SwiftUI, MenuBarExtra, and system integration. Use for menu bar UI patterns, status items, popover windows, keyboard shortcuts, and macOS-specific APIs.
---

# macOS Menu Bar App Expert

Specialized guidance for macOS menu bar applications using SwiftUI.

## When to Use

- Building menu bar-only apps (no dock icon)
- Creating status item with popover or menu
- Implementing keyboard shortcuts
- System tray integrations
- Background app functionality
- Login item configuration

## App Configuration

### Info.plist Settings

```xml
<!-- Hide dock icon -->
<key>LSUIElement</key>
<true/>

<!-- App category -->
<key>LSApplicationCategoryType</key>
<string>public.app-category.utilities</string>
```

### MenuBarExtra Styles

```swift
// Window style - shows popover
MenuBarExtra("Title", systemImage: "icon") {
    ContentView()
}
.menuBarExtraStyle(.window)

// Menu style - shows traditional menu
MenuBarExtra("Title", systemImage: "icon") {
    Button("Action") { }
    Divider()
    Button("Quit") { NSApp.terminate(nil) }
}
.menuBarExtraStyle(.menu)
```

## Common Patterns

### App Delegate for System Events

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup on launch
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                        hasVisibleWindows flag: Bool) -> Bool {
        // Handle dock icon click if visible
        return true
    }
}
```

### Settings Window

```swift
@main
struct MyApp: App {
    var body: some Scene {
        MenuBarExtra { ... }

        Settings {
            SettingsView()
        }
    }
}

// Open settings programmatically
NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

// Or for older macOS:
if #available(macOS 14.0, *) {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
} else {
    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
}
```

### Keyboard Shortcuts (Global Hotkeys)

```swift
import Carbon

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?

    func registerHotkey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType("htky".fourCharCode)
        hotKeyID.id = 1

        // Cmd + Shift + U
        RegisterEventHotKey(
            UInt32(kVK_ANSI_U),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
```

### Login Item (Launch at Login)

```swift
import ServiceManagement

func setLaunchAtLogin(_ enabled: Bool) {
    if #available(macOS 13.0, *) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set login item: \(error)")
        }
    }
}

var isLaunchAtLoginEnabled: Bool {
    if #available(macOS 13.0, *) {
        return SMAppService.mainApp.status == .enabled
    }
    return false
}
```

### Timer-Based Updates

```swift
@Observable
class UsageMonitor {
    private var timer: Timer?

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refreshData() }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func refreshData() async {
        // Update data
    }
}
```

### Menu Bar Icon with State

```swift
MenuBarExtra {
    ContentView()
} label: {
    if isActive {
        Image(systemName: "chart.bar.fill")
            .foregroundStyle(.green)
    } else {
        Image(systemName: "chart.bar")
    }
}
```

## Widget Integration

### App Groups for Data Sharing

1. Enable App Groups capability in both app and widget targets
2. Use shared UserDefaults:

```swift
let sharedDefaults = UserDefaults(suiteName: "group.com.company.app")!
```

3. Share data:

```swift
// In main app
sharedDefaults.set(encodedData, forKey: "widgetData")
WidgetCenter.shared.reloadAllTimelines()

// In widget
let data = sharedDefaults.data(forKey: "widgetData")
```

## UI Patterns

### Consistent Styling

```swift
struct MenuBarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("App Name")
                    .font(.headline)
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Content
            ForEach(items) { item in
                ItemRow(item: item)
            }

            Divider()

            // Footer
            HStack {
                Button("Refresh") { refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
        .padding()
        .frame(width: 280)
    }
}
```

### Progress Indicators

```swift
struct UsageBar: View {
    let current: Double
    let limit: Double

    var percentage: Double {
        guard limit > 0 else { return 0 }
        return min(current / limit, 1.0)
    }

    var color: Color {
        switch percentage {
        case 0..<0.5: return .green
        case 0.5..<0.8: return .yellow
        default: return .red
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geometry.size.width * percentage)
            }
        }
        .frame(height: 8)
    }
}
```

## Best Practices

- Keep the popover lightweight and fast to open
- Use system colors for automatic dark/light mode support
- Respect user's accent color with `.tint(.accentColor)`
- Test with different menu bar densities
- Handle notch on newer MacBooks (menu bar space is limited)
- Consider "Reduce motion" accessibility setting

