<p align="center">
  <img src="docs/logo.svg" alt="MeterBar" width="128" height="128">
</p>

<h1 align="center">MeterBar</h1>

<p align="center">
  <strong>Track your AI coding assistant usage limits from the menu bar</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2013.0+-black?logo=apple" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/SwiftUI-5.0-blue?logo=swift" alt="SwiftUI">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/App%20Store-Coming%20Soon-lightgrey?logo=app-store" alt="App Store Coming Soon">
</p>

---

> **Note**: MeterBar is currently in active development. The app is not yet available on the Mac App Store but will be published soon. For now, you can build from source or download pre-built binaries from the Releases page.

A lightweight macOS menu bar app that monitors Claude Code, Codex CLI, and Cursor usage at a glance.

## Screenshots

<p align="center">
  <img src="docs/screenshots/menubar.png" alt="Menu Bar" width="300">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/screenshots/widget-medium.png" alt="Widget" width="300">
</p>

## Features

- **Menu Bar App**: Quick access to usage data from your menu bar
- **Widget Support**: macOS widget for at-a-glance monitoring
- **Multi-Service Support**: Track Claude Code, Codex CLI, and Cursor
- **Zero Configuration**: Automatically reads credentials from CLI tools (no API keys needed)
- **Real-time Updates**: Background refresh every 15 minutes
- **Accordion UI**: Collapsible cards show compact progress bars
- **Color-coded Status**: Green (good), Yellow (warning), Red (critical)

## Supported Services

| Service | Auth Method | Metrics Tracked |
|---------|-------------|-----------------|
| **Claude Code** | OAuth token from `claude login` | 5h session, 7-day all models, 7-day Sonnet |
| **Codex CLI** | OAuth token from `codex login` | 5h limit, weekly limit, code review |
| **Cursor** | Local SQLite database | Monthly usage |

## Installation

### Agent Install Prompt

Paste this into your local coding agent to have it install MeterBar for you:

```text
Install MeterBar on this Mac. First verify this is macOS 13 or newer and that Homebrew is available. Install with: brew tap VincentShipsIt/tap && brew install --cask VincentShipsIt/tap/meterbar. If Homebrew is missing, ask before installing Homebrew. After installing, verify /Applications/MeterBar.app exists and that the meterbar CLI is linked, then open MeterBar. If macOS blocks the first launch because the app is unsigned, remove quarantine with xattr -cr /Applications/MeterBar.app and open it again. Do not ask me for API keys or paste secrets; for usage data, tell me to run claude login, codex login, and log into Cursor if I want those providers tracked.
```

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

Download the latest release from the [Releases](https://github.com/VincentShipsIt/meterbar.app/releases) page.

> **Note**: Since the app isn't notarized, you may need to right-click and select "Open" the first time, or run:
> ```bash
> xattr -cr /Applications/MeterBar.app
> ```

### Build from Source

Prerequisites: macOS 13.0+, Xcode 15.0+

```bash
git clone https://github.com/VincentShipsIt/meterbar.app.git
cd meterbar.app
open MeterBar.xcodeproj
# Build and run (Cmd+R)
```

## Setup

### Claude Code

1. Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code`
2. Log in: `claude login`
3. The app runs `claude /usage` and parses the CLI usage output
4. Add extra Claude accounts in Settings by pointing each one at a separate `CLAUDE_CONFIG_DIR`

### Codex CLI

1. Install Codex CLI: `npm install -g @openai/codex`
2. Log in: `codex login`
3. Select your team/workspace when prompted
4. The app automatically reads credentials from `~/.codex/auth.json`

### Cursor

1. Install and log into Cursor IDE
2. The app automatically reads from Cursor's local database

## Usage

1. **Launch the app** - It appears in your menu bar
2. **Click the icon** - See all your usage metrics
3. **Click a card header** - Expand/collapse to see details
4. **Refresh** - Click the refresh icon to update metrics

### Understanding the Display

**Collapsed view**: Shows service name + compact progress bar for quick status

**Expanded view**: Shows detailed metrics:
- Usage percentage and progress bar
- Reset time (when limits refresh)
- Subscription type badge

### Status Colors

| Color | Meaning |
|-------|---------|
| Green | < 50% used - plenty remaining |
| Yellow | 50-80% used - approaching limit |
| Red | > 80% used - near or at limit |

## CLI Tool

MeterBar includes a command-line tool for scripts and automation.

```bash
# Show current usage
meterbar usage

# JSON output for scripts
meterbar usage --json

# Filter by provider
meterbar usage --provider claude

# Show token costs (last 30 days)
meterbar cost

# Cost for specific period
meterbar cost --days 7 --json
```

The CLI is automatically installed when using Homebrew. For manual installs, it's located at:
```
/Applications/MeterBar.app/Contents/Helpers/meterbar
```

## How It Works

MeterBar reads usage data from local CLI output, local credential stores, and provider APIs:

```
claude /usage            # Claude Code usage
macOS Keychain           # Legacy Claude Code OAuth fallback only
~/.claude/               # Claude Code account metadata and local sessions
~/.codex/auth.json       # Codex CLI OAuth token
~/Library/Application Support/Cursor/  # Cursor local DB
```

It then uses the respective local source or API to fetch current usage data:
- Claude: `https://api.anthropic.com/settings/usage`
- Codex: `https://chatgpt.com/backend-api/wham/usage`

Claude Code usage uses `claude /usage` first so MeterBar does not need to read Claude Code's OAuth token during normal operation. A legacy OAuth fallback can be enabled with the `ClaudeCodeEnableOAuthFallback` UserDefaults key for local debugging.
- Additional Claude accounts are tracked by running `claude /usage` with each account's configured `CLAUDE_CONFIG_DIR`.
- Cursor: Local SQLite queries

**No provider API keys are required for CLI-backed services** - the app uses local CLI/session data where possible and does not read Claude Code's OAuth token during normal operation.

## Privacy & Security

- All credentials remain in their original locations (managed by CLI tools)
- No data sent to external servers (only official API calls)
- Sandboxed app with minimal file system access
- Open source for full transparency

## Architecture

- **SwiftUI** - Modern declarative UI
- **Combine** - Reactive data flow
- **App Sandbox** - Secure with specific entitlements for credential access
- **URLSession** - Native networking

## Troubleshooting

### "Not Connected" or "Not configured" for a service

Make sure you're logged into the CLI tool:
```bash
claude login   # For Claude Code
codex login    # For Codex CLI
```

If the app still shows "Not Connected" or "Not configured", re-run the login command. MeterBar treats expired local OAuth tokens as disconnected so it does not keep making failing usage requests.

### Codex showing "Free" instead of Team

Run `codex logout && codex login` and select your team workspace when prompted.

### App can't read credentials

The app needs sandbox exceptions to read CLI credential files. Rebuild from source if using a modified entitlements file.

## Contributing

Contributions welcome! Please open an issue first to discuss changes.

## License

MIT License - see [LICENSE](LICENSE) for details.
