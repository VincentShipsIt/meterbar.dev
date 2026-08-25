---
last_verified: 2026-08-25
status: active
---

# Distribution

## How users install

- **Homebrew (recommended):** `brew tap VincentShipsIt/tap && brew install --cask VincentShipsIt/tap/meterbar`
- **Direct download:** GitHub Releases / meterbar.dev. After **v1.6.1**, Developer ID signed and notarized. **v1.7.1+** includes Sparkle 2 and an EdDSA-signed `appcast.xml`.
- **Not the Mac App Store.** The app is deliberately unsandboxed so it can read other tools’ credential and log files. MAS would be a different architecture. Do not advertise “App Store Coming Soon”.

Automatic Sparkle checks stay off until the user opts in. **Check Now** is always a one-shot. Maintainer notes: `docs/sparkle-updates.md`.

## CI

- `ci.yml` — push/PR to `master`, `macos-26` + Xcode 26.6. Tests/coverage and SwiftLint `--strict` are hard gates, then universal app/widget/CLI builds. No `|| echo` swallow. The workflow contract keeps CI, E2E, and signed releases on the same explicit Xcode toolchain.
- `secret-scan.yml` — gitleaks, pinned + checksum-verified, full history.
- `release.yml` — tag `vMAJOR.MINOR.PATCH`. Preflights Developer ID, notarization, Sparkle EdDSA. Builds universal artifacts, checks tag/app/CLI version agreement, signs/notarizes/staples, publishes the appcast, then calls `update-homebrew.yml`.

## Local vs CI

This Mac Studio (`$HOME` `/Users/decod3rslabs`) may run `swift test` / `xcodebuild`. Do not treat Command Line Tools-only hosts as able to run XCTest.
