# Xcode Project Setup

> **Historical scaffold reference:** The checked-in `MeterBar.xcodeproj` is the
> source of truth. Do not recreate it from these legacy steps. Current builds
> require macOS 26, Xcode 26, the Swift 6.2 toolchain in Swift 5 language mode,
> and the identifiers documented in `.agents/SYSTEM/ARCHITECTURE.md`.

This guide explains how to set up the Xcode project for MeterBar.

## Creating the Xcode Project

### Option 1: Create from Swift Package

1. Open Xcode
2. File > New > Project
3. Select "macOS" > "App"
4. Fill in:
   - Product Name: `MeterBar`
   - Team: Your development team
   - Organization Identifier: `com.agenticindiedev`
   - Interface: SwiftUI
   - Language: Swift
5. Save to `apps/ai-usage-tracker/`

### Option 2: Use Existing Package.swift

If you prefer using Swift Package Manager:

```bash
cd apps/ai-usage-tracker
swift package generate-xcodeproj
```

## Project Configuration

### 1. Add App Groups Capability

1. Select the `MeterBar` target
2. Go to "Signing & Capabilities"
3. Click "+ Capability"
4. Add "App Groups"
5. Create/select group: `group.dev.meterbar.app`
6. Enable it

### 2. Add Widget Extension Target

1. File > New > Target
2. Select "Widget Extension"
3. Name: `UsageWidgetExtension`
4. Include Configuration Intent: No
5. Add to target: `MeterBar`

### 3. Configure Widget Extension

1. Select the `UsageWidgetExtension` target
2. Go to "Signing & Capabilities"
3. Add the same App Group: `group.dev.meterbar.app`
4. Set Deployment Target to macOS 13.0

### 4. Add Source Files

Add all Swift files from `MeterBar/` to the main app target:
- Models/
- Services/
- Views/
- App/

Add Widget files to the Widget Extension target:
- Widget/UsageWidget.swift
- Widget/UsageWidgetBundle.swift
- Models/ (shared)
- Services/SharedDataStore.swift (shared)

### 5. Configure Build Settings

**Main App Target:**
- Deployment Target: macOS 13.0
- Swift Language Version: Swift 5.9

**Widget Extension Target:**
- Deployment Target: macOS 13.0
- Swift Language Version: Swift 5.9

### 6. Info.plist Configuration

The main app needs:
- `LSApplicationCategoryType`: `public.app-category.utilities`
- `LSUIElement`: `YES` (for menu bar app)

Add to Info.plist:
```xml
<key>LSApplicationCategoryType</key>
<string>public.app-category.utilities</string>
<key>LSUIElement</key>
<true/>
```

## Required Capabilities

### Main App
- App Groups
- Keychain Sharing (if needed)

### Widget Extension
- App Groups (same group as main app)

## Build and Run

1. Select the `MeterBar` scheme
2. Press `Cmd+R` to build and run
3. The app will appear in the menu bar

## Troubleshooting

### Widget Not Showing

1. Check that App Groups are configured for both targets
2. Verify the group identifier matches exactly
3. Check that SharedDataStore uses the same group identifier

### Menu Bar Not Appearing

1. Check that `LSUIElement` is set to `YES` in Info.plist
2. Verify the app is running (check Activity Monitor)
3. Check Console for errors

### Keychain Access Issues

1. Ensure Keychain Sharing capability is enabled (if needed)
2. Check that KeychainManager uses the correct service identifier

## Next Steps

After setting up the project:
1. Configure authentication (see SETUP.md)
2. Test widget functionality
3. Test menu bar functionality
4. Verify notifications work
