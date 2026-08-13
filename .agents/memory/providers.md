---
last_verified: 2026-08-13
status: active
---

# Providers

MeterBar reads usage from local CLI artifacts and provider APIs. CLI-backed providers do not ask the user for API keys.

| Provider | `ServiceType` | Source |
|---|---|---|
| Claude Code | `.claudeCode` | Scoped Keychain/file OAuth → `https://api.anthropic.com/api/oauth/usage`. Expired token: delegated `claude /status` with that account’s `CLAUDE_CONFIG_DIR`; success only if the credential fingerprint changes. Missing credentials fall back to `claude /usage`. |
| Codex CLI | `.codexCli` | `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`) → `https://chatgpt.com/backend-api/wham/usage`. Exhausted accounts can spend a banked reset credit after explicit confirmation. |
| Cursor | `.cursor` | Session JWT from Cursor `state.vscdb` → `https://cursor.com/api/usage-summary`. If the API omits totals, the UI uses an assumed 500-request default — treat as an estimate. |
| OpenRouter | `.openRouter` | User API key in Keychain → documented `/api/v1/credits` and `/api/v1/key`. |
| Grok | `.grok` | On by default (opt-out). Official Grok Build CLI ACP stdio; maps `_x.ai/billing`. MeterBar checks `$GROK_HOME/auth.json` exists; it never opens or logs the token. |
| Claude admin | `.claude` | User Anthropic Admin key → `/v1/organizations/usage_report/messages` (50-page cap). |
| OpenAI admin | `.openai` | User OpenAI Admin key → `/v1/organization/usage/completions` (50-page cap). |

## Cost scan

`CostTracker` scans local transcripts for the visible 7/30-day window only. Lifetime totals are not published — filling them meant walking multi-gigabyte archives. Quota APIs (Claude OAuth usage, Codex wham, Cursor, OpenRouter credits, Grok ACP) feed the gauges; they do not carry per-model 30-day spend, so the chart still reads logs.

Listing filters: mtime newer than `cutoff - 36h`, Grok `updates.jsonl` only. Codex reads `$CODEX_HOME/sessions` and recent `archived_sessions`; it does **not** open `logs_2.sqlite` for the default scan. Codex `token_count` events carry neither model nor front end — the scanner streams each rollout and forwards the last `turn_context` model and opening `session_meta` originator. The two Codex directories are deduped by session id, keeping the larger copy.

Admin keys live in keychain service `dev.meterbar.app`, with reads migrating `dev.shipshit.meterbar` and `com.agenticindiedev.quotaguard`. Removals delete all three.

## Residual risk (R1)

Claude `/usage` parse, Codex wham, Cursor SQLite + cookie, and Grok ACP are unofficial or vendor-internal. A vendor change can break a provider with no compile error. Fixtures live in `ProviderResponseContractTests`. There is no telemetry; users are the canary.

Never log tokens, cookies, webhook URLs with secrets, or raw provider bodies.
