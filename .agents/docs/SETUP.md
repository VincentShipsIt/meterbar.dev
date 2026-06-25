# Setup Guide

This guide will help you set up MeterBar on your Mac.

## Install Prerequisites

- macOS 13.0 (Ventura) or later

## Installing MeterBar

### Homebrew (Recommended)

```bash
brew tap VincentShipsIt/tap
brew install --cask VincentShipsIt/tap/meterbar
```

To update:

```bash
brew upgrade --cask VincentShipsIt/tap/meterbar
```

### Manual Download

Download the latest release from:

```text
https://github.com/VincentShipsIt/meterbar.app/releases
```

The release build is currently unsigned/not notarized. If macOS blocks the first launch, right-click `MeterBar.app` and choose Open, or run:

```bash
xattr -cr /Applications/MeterBar.app
```

## Development Prerequisites

- Xcode 15.0 or later
- Swift 5.9 or later

### Development Tools (Recommended)

Install SwiftLint and SwiftFormat for code quality:

```bash
brew install swiftlint swiftformat
```

These tools help maintain consistent code style across the project.

## Building from Source

### 1. Clone the Repository

```bash
git clone https://github.com/VincentShipsIt/meterbar.app.git
cd meterbar.app
```

### 2. Open in Xcode

```bash
open MeterBar.xcodeproj
```

### 3. Configure the Project

1. Select the `MeterBar` target
2. Go to Signing & Capabilities
3. Add your development team
4. Enable App Sandbox if needed

### 4. Build and Run

- Press `Cmd+R` to build and run
- Or use Product > Run from the menu

## Authentication Setup

### Claude Code

1. Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code`
2. Log in: `claude login`
3. MeterBar runs `claude /usage` and parses the CLI usage output.
4. Add extra Claude accounts in Settings by pointing each account at a separate `CLAUDE_CONFIG_DIR`.

### Codex CLI

1. Install Codex CLI: `npm install -g @openai/codex`
2. Log in: `codex login`
3. Select your team/workspace when prompted.
4. MeterBar reads Codex CLI credentials from `~/.codex/auth.json`.

### Cursor

1. Install and log into Cursor IDE.
2. MeterBar reads usage from Cursor's local state database.

## Widget Setup

### Adding the Widget

1. Click the date/time in the menu bar
2. Click "Edit Widgets"
3. Search for "MeterBar"
4. Select your preferred size:
   - **Small**: Shows one service with key metrics
   - **Medium**: Shows all connected services
   - **Large**: Shows detailed breakdown with all limits

### Configuring the Widget

1. Right-click the widget
2. Select "Edit Widget"
3. Choose which services to display (if multiple are connected)

## Menu Bar

The menu bar icon shows your overall usage status:
- **Green**: All services have plenty of usage remaining
- **Yellow**: One or more services are approaching limits
- **Red**: One or more services are at or near their limits

Click the icon to see detailed usage metrics for all connected services.

## Troubleshooting

### Widget Not Updating

1. Check that you're authenticated for at least one service
2. Try manually refreshing from the menu bar
3. Check your internet connection
4. Restart the app

### Authentication Not Working

1. Re-run `claude login` or `codex login`.
2. For Codex team accounts, select the correct team/workspace during login.
3. For Cursor, open Cursor IDE and confirm you are signed in.
4. Check the console for error messages.

### Notifications Not Appearing

1. Check System Settings > Notifications
2. Ensure MeterBar has notification permissions
3. Check that notification thresholds are configured

## Security Notes

- Credentials remain in their original CLI or app-managed locations.
- MeterBar calls only the official provider APIs needed to fetch usage.
- Local parsing and display happen on your device.
- The app is open source for transparency

## Development

### Linting and Formatting

This project uses SwiftLint and SwiftFormat for code quality.

**Run SwiftLint:**
```bash
swiftlint
```

**Run SwiftFormat:**
```bash
swiftformat .
```

**Xcode Integration:**

To run linting on every build, add a "Run Script Phase" to your target:

1. Select your target in Xcode
2. Go to Build Phases
3. Click "+" and add "New Run Script Phase"
4. Add this script:
   ```bash
   if which swiftlint > /dev/null; then
     swiftlint
   else
     echo "warning: SwiftLint not installed, download from https://github.com/realm/SwiftLint"
   fi
   ```

## Getting Help

- Check the [README](README.md) for general information
- Open an issue on GitHub for bugs or feature requests
- See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines
