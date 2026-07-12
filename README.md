<p align="center">
  <img src="docs/logo.svg" alt="MeterBar" width="128" height="128">
</p>

<h1 align="center">MeterBar</h1>

<p align="center">
  <strong>Track your AI coding assistant usage limits from the menu bar</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2026+-black?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-5-orange?logo=swift" alt="Swift 5">
  <img src="https://img.shields.io/badge/SwiftUI-blue?logo=swift" alt="SwiftUI">
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
  <img
    src="https://meterbar.dev/product/overview.png"
    alt="MeterBar overview window tracking Codex, Claude, and Cursor usage limits"
    width="800"
  >
</p>

## Features

- **Menu Bar App**: Quick access to usage data from your menu bar
- **Widget Support**: macOS widget for at-a-glance monitoring
- **Multi-Service Support**: Track Claude Code, Codex CLI, and Cursor
- **Zero Configuration**: Automatically reads credentials from CLI tools (no API keys needed)
- **Real-time Updates**: Background refresh every 15 minutes
- **Pace-aware Bars**: Usage bars show quota left with an expected-pace marker and burn-rate projection
- **Color-coded Status**: Green (healthy), Orange (tight), Red (critical/exhausted)

## Supported Services

| Service | Auth Method | Metrics Tracked |
|---------|-------------|-----------------|
| **Claude Code** | Claude CLI `/usage` output | 5h session, 7-day all models, 7-day Sonnet |
| **Codex CLI** | OAuth token from `codex login` | 5h limit, weekly limit, code review |
| **Cursor** | Local SQLite database | Monthly usage |

## Installation

### Agent Install Prompt

Paste this into your local coding agent to have it install MeterBar for you:

```text
Install MeterBar on this Mac. First verify this is macOS 26 or newer and that Homebrew is available. Install with: brew tap VincentShipsIt/tap && brew install --cask VincentShipsIt/tap/meterbar. If Homebrew is missing, ask before installing Homebrew. After installing, verify /Applications/MeterBar.app exists and that the meterbar CLI is linked, then open MeterBar. Do not ask me for API keys or paste secrets; for usage data, tell me to run claude login, codex login, and log into Cursor if I want those providers tracked.
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

Download the latest release from [meterbar.dev](https://meterbar.dev).

Releases after v1.6.1 are Developer ID signed and notarized, so direct downloads open without Gatekeeper warnings. For v1.6.1 and earlier (ad-hoc signed only), right-click and select "Open" the first time, or run `xattr -cr /Applications/MeterBar.app`.

### Build from Source

Prerequisites: macOS 26+, Xcode 26+

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
4. The app automatically reads credentials from `$CODEX_HOME/auth.json` (`~/.codex/auth.json` by default)

### Cursor

1. Install and log into Cursor IDE
2. The app automatically reads from Cursor's local database

## Usage

1. **Launch the app** - It appears in your menu bar with the tightest quota's percent left
2. **Click the icon** - The popover shows every provider's quota windows
3. **Open the dashboard** - Full view with limits, 30-day token costs, and settings
4. **Refresh** - Click the refresh icon to update metrics

### Understanding the Display

Each quota window shows the percent **left**, a pace marker for where usage
should be at this point in the window, reset countdowns, and — when a limit is
exhausted — a countdown to when usage resumes.

### Status Colors

| Color | Meaning |
|-------|---------|
| Green | more than 25% of the quota left |
| Orange | 25% or less left - quota is tight |
| Red | 10% or less left - critical or exhausted |

## CLI Tool

MeterBar includes a command-line tool for scripts and automation.

```bash
# Show current usage
meterbar usage

# JSON output for scripts
meterbar usage --json

# Filter by provider (claude, codex, cursor)
meterbar usage --provider claude

# Show token costs from the app's last local scan
meterbar cost

# JSON output
meterbar cost --json
```

`meterbar cost` reports the MeterBar app's cached 30-day scan (run one from
the app's Costs tab), so the CLI and the app always show the same numbers.

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
$CODEX_HOME/auth.json    # Codex CLI OAuth token (defaults to ~/.codex/auth.json)
~/Library/Application Support/Cursor/  # Cursor local DB
```

It then uses the respective local source or API to fetch current usage data:
- Claude Code (legacy OAuth fallback only): `https://api.anthropic.com/api/oauth/usage`
- Codex: `https://chatgpt.com/backend-api/wham/usage`

Claude Code usage uses `claude /usage` first so MeterBar does not need to read Claude Code's OAuth token during normal operation. A legacy OAuth fallback can be enabled in Settings under Claude Code.
- Additional Claude accounts are tracked by running `claude /usage` with each account's configured `CLAUDE_CONFIG_DIR`.
- Cursor: Local SQLite queries

**No provider API keys are required for CLI-backed services** - the app uses local CLI/session data where possible and does not read Claude Code's OAuth token during normal operation.

## Privacy & Security

- All credentials remain in their original locations (managed by CLI tools)
- No data sent to external servers (only calls to the providers' own usage endpoints)
- The main app is **not** sandboxed — it must read other tools' credential/log files
  (`~/.claude`, `~/.codex`, Cursor's local database) and run the `claude` binary. The
  widget extension is sandboxed. Hardened runtime is enabled for both.
- No analytics, telemetry, or crash reporting
- Open source for full transparency

## Architecture

- **SwiftUI** - Modern declarative UI
- **Combine** - Reactive data flow
- **Hardened Runtime** - Enabled for app and widget (the main app is un-sandboxed by
  design so it can read local CLI credential/log files)
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

The app reads CLI credential files from `$CODEX_HOME/auth.json` (`~/.codex/auth.json` by default) and Cursor's local database. If you built from source with App Sandbox enabled, those reads will fail — the shipped configuration keeps the main app un-sandboxed for this reason.

## Contributing

Contributions welcome! Please open an issue first to discuss changes.

## License

MIT License - see [LICENSE](LICENSE) for details.
