---
last_verified: 2026-08-30
status: active
---

# Distribution

## How users install

- **Homebrew (recommended):** `brew tap VincentShipsIt/tap && brew install --cask VincentShipsIt/tap/meterbar`
- **Direct download:** GitHub Releases / meterbar.dev. After **v1.6.1**, Developer ID signed and notarized. **v1.7.1+** includes Sparkle 2 and an EdDSA-signed `appcast.xml`.
- **Not the Mac App Store.** The app is deliberately unsandboxed so it can read other tools’ credential and log files. MAS would be a different architecture. Do not advertise “App Store Coming Soon”.

Automatic Sparkle checks stay off until the user opts in. **Check Now** is always a one-shot. Maintainer notes: `docs/sparkle-updates.md`.

## CI

- `ci.yml` — push/PR to `master`, `macos-26` + the pinned Xcode. Tests/coverage and SwiftLint `--strict` are hard gates, then universal app/widget/CLI builds. No `|| echo` swallow. The toolchain version is single-sourced in `.github/actions/select-xcode/action.yml`; every macOS job pulls it in with `uses: ./.github/actions/select-xcode`, and the workflow contract fails PR CI if a workflow pins Xcode itself or a Swift-building job skips the action.
- `secret-scan.yml` — gitleaks, pinned + checksum-verified, full history.
- `release.yml` — tag `vMAJOR.MINOR.PATCH`. Preflights Developer ID, notarization, Sparkle EdDSA. Builds universal artifacts, checks tag/app/CLI version agreement, signs/notarizes/staples, publishes the appcast, then calls `update-homebrew.yml`.

## Local vs CI

This Mac Studio (`$HOME` `/Users/decod3rslabs`) may run `swift test` / `xcodebuild`. Do not treat Command Line Tools-only hosts as able to run XCTest.

## CloudKit release gate

The opt-in multi-Mac aggregation feature is not release-ready from a source build alone. Before shipping it, the release owner must provision the `iCloud.dev.meterbar.app` container for the distribution team, associate that container with both the `dev.meterbar.app` and `dev.meterbar.app.debug` application identifiers, deploy the `MeterBarDeviceV1` and `MeterBarDailyUsageV1` record schema (including every field in `ICloudUsageRecordSchema`) to CloudKit production, and regenerate/verify both provisioning profiles with the CloudKit/iCloud entitlements. Unsigned local and CI builds prove compilation only; they do not prove production-container access.
