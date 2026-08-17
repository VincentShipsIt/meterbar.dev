---
last_verified: 2026-08-17
status: active
---

# Providers

MeterBar reads usage from local CLI artifacts and provider APIs. CLI-backed providers do not ask the user for API keys.

| Provider | `ServiceType` | Source |
|---|---|---|
| Claude Code | `.claudeCode` | Scoped Keychain/file OAuth → `https://api.anthropic.com/api/oauth/usage`. Expired token: delegated `claude /status` with that account’s `CLAUDE_CONFIG_DIR`; success only if the credential fingerprint changes. Missing credentials fall back to `claude /usage`. |
| Codex CLI | `.codexCli` | `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`) → `https://chatgpt.com/backend-api/wham/usage`. Exhausted accounts can spend a banked reset credit after explicit confirmation. |
| Cursor | `.cursor` | Session JWT from Cursor `state.vscdb` → `https://cursor.com/api/usage-summary`. Current payloads expose two included pools as `plan.autoPercentUsed` (Cursor Models) and `plan.apiPercentUsed` (Other Models) — those are the dashboard bars. If those fields are absent, the UI falls back to `plan.used` / server quota, and if the API omits totals it uses an assumed 500-request default marked estimated. On-demand spend is the third bar when enabled. Grok Bot is **not** MeterBar's Grok provider and is **not** on usage-summary: the weekly Ultra entitlement is `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` with the same Cursor JWT, mapped to `additionalLimits`. That fetch is optional — Cursor still shows the three usage-summary bars if the sand RPC fails. |
| OpenRouter | `.openRouter` | User API key in Keychain → documented `/api/v1/credits` and `/api/v1/key`. |
| Grok | `.grok` | On by default (opt-out). Official Grok Build CLI ACP stdio maps `_x.ai/billing` for the weekly gauge. Usage-limit resets (display + Redeem) come from unofficial grok.com `ConsumerUiSvc/GetRemainingResets` and `RedeemReset` using the cached OIDC token in `$GROK_HOME/auth.json` — same class as Codex wham. The token is not logged. Exhausted accounts can spend a banked reset after explicit confirmation. |
| Claude admin | `.claude` | User Anthropic Admin key → `/v1/organizations/usage_report/messages` (50-page cap). |
| OpenAI admin | `.openai` | User OpenAI Admin key → `/v1/organization/usage/completions` (50-page cap). |

## Cost scan

`CostTracker` scans local transcripts for the visible 7/30-day window only. Lifetime totals are not published — filling them meant walking multi-gigabyte archives. Quota APIs (Claude OAuth usage, Codex wham, Cursor, OpenRouter credits, Grok ACP) feed the gauges; they do not carry per-model 30-day spend, so the chart still reads logs.

Listing filters: mtime newer than `cutoff - 36h`, Grok `updates.jsonl` only. Codex reads `$CODEX_HOME/sessions` and recent `archived_sessions`; it does **not** open `logs_2.sqlite` for the default scan. Codex `token_count` events carry neither model nor front end — the scanner streams each file and carries `turn_context.model`, nested `collaboration_mode.settings.model`, `thread_settings.model`, and `world_state.state.model`. Tokens emitted before the first model in the same file are back-filled. The two Codex directories are deduped by session id, keeping the larger copy. Per-session cost rows (issue #391) fold from the same scan into `sessionBreakdowns`.

Grok usage-limit resets: fetch `GetRemainingResets`, redeem via `RedeemReset` with the token id after explicit confirmation. Same unofficial class as Codex wham consume. Live 2026-08-13: `RedeemReset` is implemented; a fake token id returns `grpc-status: 9` (FAILED_PRECONDITION) on the HTTP header with an empty body and does not spend a real reset. Consume must read that header — a missing trailer is not success.

Admin keys live in keychain service `dev.meterbar.app`, with reads migrating `dev.shipshit.meterbar` and `com.agenticindiedev.quotaguard`. Removals delete all three.

## Residual risk (R1)

Claude `/usage` parse, Codex wham, Cursor SQLite + cookie, and Grok ACP are unofficial or vendor-internal. A vendor change can break a provider with no compile error. Fixtures live in `ProviderResponseContractTests`. There is no telemetry; users are the canary.

Never log tokens, cookies, webhook URLs with secrets, or raw provider bodies.
