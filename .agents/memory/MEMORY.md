---
last_verified: 2026-10-21
status: active
---

# MeterBar — repo memory index

Link index plus hard facts. Auto-loaded at session start. Open a topic file for detail.

## Read these

- [architecture.md](architecture.md) — what the code is
- [conventions.md](conventions.md) — Swift, tests, git, agent-doc rules
- [providers.md](providers.md) — data sources and unofficial-API risk
- [distribution.md](distribution.md) — signing, notarization, Sparkle, Homebrew
- [design.md](design.md) — Liquid Glass / native chrome
- [decisions.md](decisions.md) — live ADRs
- [deferred.md](deferred.md) — structural debt and integration boundaries
- [verify-meterbar](../../skills/verify-meterbar/SKILL.md) — quota/cache/cost/routing/UI/CLI verification

User contracts (not agent memory): `README.md`, `docs/cli-json-schema.md`, `docs/localization.md`, `docs/quota-event-webhooks.md`, `docs/session-wake-migration.md`, `docs/sparkle-updates.md`.

## Hard facts

- Repo: `VincentShipsIt/meterbar.dev`. Public. Default branch `master`.
- Product: native **macOS 26** menu bar app + WidgetKit widgets + bundled `meterbar` CLI. No backend. No database server. The one opt-in exception is **Public profile** (#594): the app publishes to the site, which lives in `VincentShipsIt/landings`. See `decisions.md`.
- Releases after **v1.6.1** are Developer ID signed and notarized. Sparkle 2 from **v1.7.1**. Read current release and trunk state from GitHub; delivery history is not cached here.
- The shipped version comes from the **git tag**, not the project file. `release.yml` derives it via `scripts/validate-release-tag.sh` and passes it to the signed build, which overrides `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. `MARKETING_VERSION` in `MeterBar.xcodeproj` is a build default; being behind a release tag is **not** a bug to fix. Cutting a release = push a `vMAJOR.MINOR.PATCH` tag.
- Providers: Claude Code, Codex CLI, xAI (Grok CLI + Cursor, one merged provider), OpenRouter, Kimi Code, Z.ai GLM Coding Plan, GitHub Copilot, Muse Code, and Claude Platform. Opt-in behavior comes from `ServiceType`. Provider source/risk contracts and integration boundaries live in [providers.md](providers.md).
- Shared models live in `Packages/MeterBarShared`. App group `group.dev.meterbar.app`.
- Release bundle ids `dev.meterbar.app` / `dev.meterbar.app.Widget`. Debug uses `dev.meterbar.app.debug` so local builds cannot shadow the installed app.
- The **app is not sandboxed** (must read other tools’ logs/credentials and spawn CLIs). The widget is sandboxed. Hardened runtime on both.
- Three build systems: `MeterBar.xcodeproj` (app + widget), root `Package.swift` (`swift test`), `MeterBarCLI/Package.swift`.
- Tests: `swift test` at repo root needs full Xcode. CI on `macos-26` is the merge gate.
- Delivery state lives on **GitHub issues**, not a local TASKS folder.
- Session logs: `.agents/sessions/YYYY-MM-DD.md` (lowercase), gitignored, never committed. This repo is public.
- Unofficial provider APIs are the main residual risk. No crash reporter; `AppLog` (`os.Logger`) only.

## Commands

- Tests: `swift test` (full Xcode)
- App: `xcodebuild -project MeterBar.xcodeproj -scheme MeterBar build`
- CLI: `cd MeterBarCLI && swift build`

## Do not follow

- `.agents/SYSTEM/` and `.agents/docs/` — removed. This directory replaced them.
- `.agents/TASKS/` — never existed here. Delivery state is GitHub issues.
- `docs/audits/` — deleted 2026-09-09. The superseded repo-map and DRY-slop audits live in git history only.
- Do not restore `/start`, `/validate`, `/bug`, `/inbox`, `/task`, `/end`. They were generic-template commands wired to `.agents/TASKS/` and a `session-documenter` skill this repo does not have, and `/start` taught rules this repo contradicts.
