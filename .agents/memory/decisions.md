---
last_verified: 2026-08-13
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

## Singletons for services

**Accepted 2025-12-29, still in force.** `UsageDataManager.shared` and peer services. A DI refactor is not scheduled.

## Availability-biased cache

**Accepted.** Fetch failures keep the last good metrics. Blanking the UI on a transport error is worse than showing slightly stale numbers with health dimming.

## Cost scan is the visible window only

**Accepted 2026-08-13.** Quota APIs do not replace 30-day per-model spend. The local scan lists files by mtime (`cutoff - 36h`) and publishes period totals only. Lifetime is kept on `CostSummary` for cache decode and is no longer filled or shown. Codex `logs_2.sqlite` is not opened for the default scan. The Costs page shows listed file count and bytes while a refresh runs.
