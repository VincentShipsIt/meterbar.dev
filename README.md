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

A lightweight macOS menu bar app that monitors Claude Code, Codex CLI, Cursor,
OpenRouter, and Grok usage at a glance — then tells you which provider still has
headroom, warns you before you hit a wall, and can resume your blocked sessions
by itself once a limit resets.

## Screenshots

<p align="center">
  <img
    src="https://meterbar.dev/product/overview.png"
    alt="MeterBar overview window tracking Codex, Claude, and Cursor usage limits"
    width="800"
  >
</p>

## Features

### Monitoring

- **Menu Bar App**: Quick access to usage data from your menu bar
- **Per-Account Menu Bar Items**: Give up to 4 Claude/Codex accounts their own status item, or use one merged item with an in-menu account switcher (Settings → General → Menu Bar Accounts)
- **Multi-Service Support**: Track Claude Code, Codex CLI, Cursor, OpenRouter, and Grok
- **Provider Status**: Service-health monitoring for all five providers, so you can tell a provider outage apart from your own exhausted quota
- **Widget Support**: macOS widget for at-a-glance monitoring
- **Zero Configuration for CLI Providers**: Reuses local CLI sign-ins without password entry
- **Real-time Updates**: Background refresh defaults to 10 minutes, with an opt-in 1–30 minute
  adaptive cadence and prompt catch-up after wake
- **Pace-aware Bars**: Usage bars show quota left with an expected-pace marker and burn-rate projection
- **Color-coded Status**: Green (healthy), Orange (tight), Red (critical/exhausted)

### Automation

- **Session Wake**: Watch one Claude or Codex account and automatically resume its blocked sessions, one at a time, once the limit resets — the watcher keeps running after MeterBar quits ([details](#session-wake))
- **Pre-limit Alerts**: Two configurable thresholds — an early heads-up as a quota tightens, and a stronger alert as it runs out ([details](#alerts))
- **Event Integrations**: Run a local command or POST quota transitions to a webhook ([details](#event-integrations))

### Cost and optimization

- **Local Cost Scan**: 30-day token spend computed from local session logs — nothing is uploaded
- **Optimize Tab**: See where tokens actually go, and which provider has the most headroom right now
- **Display Currency**: Show costs in your own currency at a rate you enter (Settings → Costs)

### Scripting

- **CLI Tool**: `meterbar usage` and `meterbar cost`, with a versioned `--json` schema ([details](#cli-tool))
- **Local HTTP Endpoint**: `meterbar serve` exposes the same cached data read-only over loopback ([details](#http-endpoint))

## Supported Services

| Service | Auth Method | Metrics Tracked |
|---------|-------------|-----------------|
| **Claude Code** | Keychain OAuth token (`/api/oauth/usage`); CLI `/usage` fallback | 5h session, 7-day all models, 7-day Sonnet |
| **Codex CLI** | OAuth token from `codex login` | 5h limit, weekly limit, code review |
| **Cursor** | Local SQLite database | Monthly usage |
| **OpenRouter** | User-provided API key stored in Keychain | Account credits, spend, per-key limits |
| **Grok** | Cached `grok login` session, accessed by the official CLI | Weekly quota, reset time, extra credits |

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

Homebrew installations continue to update through Homebrew. Direct-download builds from v1.7.1 onward can also use **Settings → General → Software Update**. Automatic checks are disabled until you explicitly opt in; **Check Now** always performs a one-time manual check.

### Manual Download

Download the latest release from [meterbar.dev](https://meterbar.dev).

Releases after v1.6.1 are Developer ID signed and notarized, so direct downloads open without Gatekeeper warnings. For v1.6.1 and earlier (ad-hoc signed only), right-click and select "Open" the first time, or run `xattr -cr /Applications/MeterBar.app`.

Starting with v1.7.1, direct-download releases include Sparkle 2 and consume an EdDSA-signed `appcast.xml` published with each GitHub Release. Older versions without Sparkle cannot discover v1.7.1 automatically and must be upgraded once manually.

Maintainer setup and release verification are documented in [docs/sparkle-updates.md](docs/sparkle-updates.md).

### Build from Source

Prerequisites: macOS 26+, Xcode 26+

```bash
git clone https://github.com/VincentShipsIt/meterbar.dev.git
cd meterbar.dev
open MeterBar.xcodeproj
# Build and run (Cmd+R)
```

## Setup

### Claude Code

1. Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code`
2. Log in: `claude login`
3. The app reads usage from Claude Code's authenticated `/api/oauth/usage` endpoint using its Keychain login (first launch shows a one-time Keychain access prompt); if no token is available it falls back to parsing `claude /usage` output
4. Configure each Claude account in Settings with its own `CLAUDE_CONFIG_DIR`. The unscoped default account can use the global Keychain token; any explicitly scoped account uses the CLI.

### Codex CLI

1. Install Codex CLI: `npm install -g @openai/codex`
2. Log in: `codex login`
3. Select your team/workspace when prompted
4. The app automatically reads credentials from `$CODEX_HOME/auth.json` (`~/.codex/auth.json` by default)

### Cursor

1. Install and log into Cursor IDE
2. The app automatically reads from Cursor's local database

### Grok

1. Install [Grok Build](https://x.ai/cli)
2. Log in: `grok login`
3. Enable Grok under **Settings → General → Tracked Providers**
4. MeterBar asks the official CLI for billing data over ACP; it does not read or store the cached token

To track more than one Grok Build account, give each CLI login a distinct
`GROK_HOME`, then add that directory under **Settings → Providers → Grok Build**:

```bash
GROK_HOME=~/.grok-work grok login
GROK_HOME=~/.grok-personal grok login
```

The existing unscoped login remains the zero-configuration default profile
(`$GROK_HOME` when already exported, otherwise `~/.grok`). Each enabled profile
gets its own card, menu-bar account, widget entry, cache snapshot, refresh
result, and diagnostics check. A failed profile does not block the others.

## Usage

1. **Launch the app** - It appears in your menu bar with the tightest quota's percent left
2. **Click the icon** - The popover shows every provider's quota windows
3. **Open the dashboard** - Full view with limits, token costs, optimization, and settings
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

### Dashboard

| Tab | What it shows |
|-----|---------------|
| **Overview** | Current health and local token history |
| **Limits** | Every tracked quota window |
| **Costs** | Local 30-day token spend |
| **Optimize** | Where tokens go, and which provider has headroom right now |
| **Status** | Provider service health |
| **Diagnostics** | Provider setup health |
| **Share** | Social card export |

### Alerts

**Settings → General → Notifications** turns on threshold alerts, with two
independently configurable levels:

- **Warn me** — the first heads-up as a quota tightens
- **Alert me** — a stronger alert as the quota runs out

Both are off until you enable notifications. Disabled providers and stale data
never notify, repeat crossings are deduplicated rather than stacked, and an
alert only claims a quota is *exhausted* when it actually is — configuring the
critical level at "10% left" produces a warning at 10%, not a false
limit-reached banner.

### Session Wake

**Settings → Automation** watches a single Claude or Codex account and, once its
limit resets, automatically resumes the sessions that limit blocked — one at a
time, not all at once. A one-time confirmation explains this the first time you
turn it on.

The watcher runs as a launch agent, so it keeps working after you quit MeterBar.
Only one watcher runs at a time across the app and the CLI; a cross-process lock
prevents two from racing each other.

## Cost Tracking

The **Costs** tab computes 30-day token spend by scanning your local Claude,
Codex, and Grok session logs. The scan is incremental and resumable — it caches
per-file results and picks up where it left off rather than re-reading the whole
corpus each time. Nothing is uploaded; the numbers are derived entirely from
files already on your disk.

Set a **Display Currency** under **Settings → Costs** to show totals in a
currency other than USD, using a conversion rate you enter yourself. MeterBar
does not fetch exchange rates.

## CLI Tool

MeterBar includes a command-line tool for scripts and automation.

```bash
# Show current usage
meterbar usage

# JSON output for scripts
meterbar usage --json

# Filter by provider (claude, codex, cursor, openrouter, grok)
meterbar usage --provider claude

# Show token costs from the app's last local scan
meterbar cost

# JSON output
meterbar cost --json
```

`meterbar cost` reports the MeterBar app's cached 30-day scan (run one from
the app's Costs tab), so the CLI and the app always show the same numbers.
The [`--json` schema](docs/cli-json-schema.md) is versioned for third-party integrations.

### HTTP Endpoint

`meterbar serve` exposes the same cached data over a local HTTP endpoint, for
status bars, dashboards, and scripts that would rather poll a URL than shell out.

```bash
meterbar serve
# meterbar serve listening on http://127.0.0.1:47663
# Endpoints: GET /usage, GET /cost (Authorization: Bearer <token> required)
# Bearer token (generated, shown once): ...
```

The endpoint is **read-only** — it serves the cache and never triggers a provider
refresh or mutates state. It binds to loopback only unless you pass
`--allow-remote`, requires a bearer token on every request (generated and printed
once at startup if you do not supply `--token`), and rate-limits to 5 requests
per second by default.

`--allow-remote` exposes a **plaintext HTTP** listener on your network. The
bearer token and cached usage/cost data are not encrypted in transit, so use it
only on a trusted private network or place MeterBar behind a TLS-terminating
reverse proxy. Do not expose the listener directly to the public internet.

### Event Integrations

Settings → General → Event Integrations can run a literal-argv local command or
POST quota transitions to a webhook. Both lanes and every event/provider/account
scope are off until explicitly enabled. The
[versioned webhook contract](docs/quota-event-webhooks.md) documents the exact
payload, transition semantics, and outbound security boundary.

The CLI is automatically installed when using Homebrew. For manual installs, it's located at:
```
/Applications/MeterBar.app/Contents/Helpers/meterbar
```

## How It Works

MeterBar reads usage data from local CLI output, local credential stores, and provider APIs:

```
macOS Keychain           # Claude Code OAuth token (Claude Code-credentials)
claude /usage            # Claude Code usage fallback (CLI output)
~/.claude/               # Claude Code account metadata and local sessions
$CODEX_HOME/auth.json    # Codex CLI OAuth token (defaults to ~/.codex/auth.json)
~/Library/Application Support/Cursor/  # Cursor local DB
$GROK_HOME/auth.json     # Grok CLI login presence only; defaults to ~/.grok
```

It then uses the respective local source or API to fetch current usage data:
- Claude Code (primary): `https://api.anthropic.com/api/oauth/usage`, using the `Claude Code-credentials` Keychain OAuth token
- Codex: `https://chatgpt.com/backend-api/wham/usage`
- Grok: official `grok agent --no-leader stdio` ACP billing response, scoped per profile with `GROK_HOME`

Claude Code usage reads the authenticated `/api/oauth/usage` endpoint — the same data Claude Code's own `/usage` screen shows — because `claude /usage` no longer renders in a headless (non-interactive) spawn. Parsing the CLI output is kept as a fallback and can be forced by turning off "Claude Code OAuth usage" in Settings.
- Explicitly scoped Claude accounts are tracked by running `claude /usage` with each account's configured `CLAUDE_CONFIG_DIR` (they have no profile-specific Keychain token of their own).
- Cursor: Local SQLite queries

**No provider API keys are required for CLI-backed services** - the app reuses local Claude Code, Codex, and Grok sign-ins. The unscoped default Claude Code account's Keychain OAuth token is read to fetch usage (a one-time macOS Keychain prompt on first launch); Grok authentication remains inside the official CLI process.

## Privacy & Security

- All credentials remain in their original locations (managed by CLI tools)
- Cost figures are computed locally from session logs already on your disk; no log content leaves the machine
- No data is sent beyond providers' own usage endpoints by default. An explicitly
  enabled webhook sends only the documented quota event fields to the URL the
  user configured; credentials and config paths are never included.
- `meterbar serve` is opt-in, read-only, loopback-bound by default, and token-gated.
  `--allow-remote` is plaintext HTTP; use a trusted private network or a TLS proxy.
- The main app is **not** sandboxed — it must read other tools' credential/log files
  (`~/.claude`, `~/.codex`, Cursor's local database) and run the `claude` and `grok` binaries. The
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
grok login     # For Grok Build
```

If the app still shows "Not Connected" or "Not configured", re-run the login command. MeterBar treats expired local OAuth tokens as disconnected so it does not keep making failing usage requests.

### Codex showing "Free" instead of Team

Run `codex logout && codex login` and select your team workspace when prompted.

### App can't read credentials

The app reads CLI credential files from `$CODEX_HOME/auth.json` (`~/.codex/auth.json` by default), checks for the Grok CLI login, and reads Cursor's local database. If you built from source with App Sandbox enabled, those accesses will fail — the shipped configuration keeps the main app un-sandboxed for this reason.

## Contributing

Contributions welcome! Please open an issue first to discuss changes.

## License

MIT License - see [LICENSE](LICENSE) for details.
