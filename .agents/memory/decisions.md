---
last_verified: 2026-08-25
status: active
---

# Decisions

Live ADRs only.

## Agent memory lives in `.agents/memory/`

**Accepted 2026-08-12.** Replaces `.agents/SYSTEM/` and `.agents/docs/`. `MEMORY.md` is the session-start index. GitHub issues hold delivery state. Session logs stay local and gitignored.

## `MeterBarShared` is the wire-format source of truth

**Accepted 2026-07-02.** `ServiceType`, `UsageLimit`, `UsageMetrics`, `UsageStatus`, pricing, and widget planners live in `Packages/MeterBarShared`. App, widget, and CLI import it. Do not re-fork those types.

## Malformed JWT is not expired

**Accepted.** `OAuthTokenExpiry.isExpired(jwt:)` returns `false` when the token cannot be parsed. The server 401 is the source of truth. Treating malformed as expired would lock out real Codex setups whose token is not a standard JWT.

## App is not sandboxed

**Accepted.** The app must read other tools’ credential/log files and spawn CLIs. Widget is sandboxed. This is why there is no Mac App Store build.

## Debug must not shadow release

**Accepted.** Debug bundle id `dev.meterbar.app.debug`, product name `MeterBar Dev`. Same app group as release. Local runs cannot overwrite the notarized install.

## CI and releases use Xcode 26.6

**Accepted 2026-08-25.** CI, scheduled E2E, nightly, and stable signed releases select Xcode 26.6 explicitly. The GitHub-built v1.8.41 artifact from Xcode 26.2 reproduced the same launch `EXC_BAD_ACCESS` on both the MacBook Pro and Mac Studio, while the Xcode 26.6 Studio build remained running. `verify-release-workflow-contract.sh` rejects toolchain drift between validation and distribution workflows.

## The Xcode pin lives in one file

**Accepted 2026-08-26.** `.github/actions/select-xcode/action.yml` holds the version; workflows say `uses: ./.github/actions/select-xcode` and never name a toolchain path. Bumping is a one-line edit to that action's `default`, not the five-workflow, six-literal sweep the 26.2 → 26.6 bump required. The action fails loudly when the version is absent from the runner image, and exports `DEVELOPER_DIR` so later steps — including the `swift test` inside `check-coverage.sh` — cannot fall back to the image default. `verify-release-workflow-contract.sh` rejects any workflow that pins Xcode itself, and any job running `xcodebuild` or `check-coverage.sh` that skips the action.

## Singletons for services

**Accepted 2025-12-29, still in force.** `UsageDataManager.shared` and peer services. A DI refactor is not scheduled.

## Availability-biased cache

**Accepted.** Fetch failures keep the last good metrics. Blanking the UI on a transport error is worse than showing slightly stale numbers with health dimming.

## Cost scan is the visible window only

**Accepted 2026-08-13.** Quota APIs do not replace 30-day per-model spend. The local scan lists files by mtime (`cutoff - 36h`) and publishes period totals only. Lifetime is kept on `CostSummary` for cache decode and is no longer filled or shown. Codex `logs_2.sqlite` is not opened for the default scan. The Costs page shows listed file count and bytes while a refresh runs.
