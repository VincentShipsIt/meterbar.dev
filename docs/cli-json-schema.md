# MeterBar CLI JSON schema

`meterbar usage --json`, `meterbar cost --json`, `meterbar refresh --json`, and
`meterbar guard --json` emit stable, versioned JSON for menu bars, shell prompts,
dashboards, and other third-party integrations.
Human-readable output remains the default when `--json` is absent. `meterbar serve` exposes the
same versioned usage/cost documents over a local HTTP endpoint instead of standard output.

## Compatibility contract

- Every document contains `schemaVersion`. The current version is `1`.
- Fields may be added without changing the version. Existing fields will not be removed, renamed,
  or change type within version 1.
- Consumers should reject unsupported major schema versions rather than guessing their shape.
- Dates use UTC ISO 8601 strings. Provider arrays and usage windows have deterministic ordering.
- Optional values are omitted when the provider or cached source did not supply them.
- JSON is the only content written to standard output for these commands.

Provider identifiers are stable tokens: `claude`, `codex`, `cursor`, `openrouter`, and `grok`.

## Usage

```sh
meterbar usage --json
meterbar usage --provider codex --json
meterbar usage --account Work --json
meterbar usage --provider claude --account 00000000-0000-0000-0000-000000000012 --json
```

Version 1 shape:

```json
{
  "schemaVersion": 1,
  "providers": [
    {
      "provider": "codex",
      "displayName": "OpenAI Codex",
      "lastUpdated": "2026-07-14T10:00:00Z",
      "windows": [
        {
          "kind": "session",
          "used": 42.5,
          "total": 100,
          "percentUsed": 42.5,
          "percentLeft": 58,
          "resetAt": "2026-07-14T15:00:00Z",
          "windowSeconds": 18000,
          "quotaBand": "healthy",
          "estimated": false
        }
      ],
      "extraUsage": {
        "state": "off"
      },
      "resetCreditsAvailable": 2
    }
  ]
}
```

`windows[].kind` is only `session`, `weekly`, or `codeReview`. That enum is closed in version 1:
consumers may switch on it exhaustively. Extra reported periods are appended as additional
`windows[]` entries that still use one of those three tokens — short cadences (`session`,
`daily`) reuse `session`, longer cadences (`weekly`, `monthly`, `billing`, `unknown`) reuse
`weekly`. Multiple entries may therefore share a `kind`. `percentUsed` is clamped to `0...100`
for display, while `used` and `total` preserve the source values. `percentLeft` and `quotaBand`
use MeterBar's shared quota rules; `quotaBand` is `healthy`, `tight`, `critical`, or `exhausted`.
`estimated` identifies totals MeterBar inferred instead of receiving from the provider.

`windows[].periodKind` is the additive identity field. It names the provider-reported cadence
(`session`, `daily`, `weekly`, `monthly`, `billing`, `unknown`) even when `kind` stays a legacy
slot token. A monthly Grok allowance therefore stays `kind: "weekly"` and adds
`"periodKind": "monthly"`. An extra daily period is `kind: "session"` plus
`"periodKind": "daily"`. The key is omitted when the cache did not record a cadence. Do not
treat `kind` as the human title or as unique within a provider.

`extraUsage.state` is `on`, `off`, or `unknown`; its optional `detail` is provider-supplied display
context. `resetCreditsAvailable` is present only when the provider reports banked reset credits.

### Accounts

Claude, Codex, and Grok can have more than one profile. `providers[]` stays the representative
provider-wide snapshot (`loadMetrics()`), so schema-v1 consumers that only read `providers` keep
working. When the app-group account cache (`loadAccountMetrics()`) has snapshots, the document
also includes an additive `accounts` array — one entry per cached profile, never a filesystem path,
`GROK_HOME`, or token.

`accounts` is omitted when that cache is empty (legacy provider-only files, or Cursor which stays
provider-only and never gets fake accounts). OpenRouter entries are one per managed API key.

```json
{
  "schemaVersion": 1,
  "providers": [
    {
      "provider": "claude",
      "displayName": "Claude Code",
      "lastUpdated": "2026-07-14T10:00:00Z",
      "windows": []
    }
  ],
  "accounts": [
    {
      "provider": "claude",
      "accountId": "00000000-0000-0000-0000-000000000012",
      "accountName": "Work",
      "lastUpdated": "2026-07-14T10:00:00Z",
      "windows": [
        {
          "kind": "session",
          "used": 80,
          "total": 100,
          "percentUsed": 80,
          "percentLeft": 20,
          "quotaBand": "tight",
          "estimated": false
        }
      ]
    }
  ]
}
```

`--account` / `GET /usage?account=` matches an account id (UUID string) or the exact account name.
Matching is case-insensitive and trims surrounding whitespace; it is not a substring. Duplicate
names return every match, sorted by provider, then name, then id. An unknown account is
deterministic and successful: `accounts` is omitted (or empty after filtering) and `providers[]`
is unchanged except for any `--provider` / `?provider=` filter. Human text prints
`No matching accounts.` instead of the provider rows.

`--provider` / `?provider=` still filters both arrays. Combining `--provider` and `--account`
intersects them. Disabled or deleted profiles are simply absent from the cache — usage never
invents rows for them.

## Cost

```sh
meterbar cost --json
meterbar cost --days 7 --json
meterbar cost --month-to-date --json
meterbar cost --currency EUR --rate 0.92 --json
```

Version 1 shape:

```json
{
  "schemaVersion": 1,
  "lastScannedAt": "2026-07-14T10:00:00Z",
  "period": {
    "requestedDays": 30,
    "coveredDays": 30,
    "isTruncated": false
  },
  "providers": [
    {
      "provider": "claude",
      "displayName": "Claude Code",
      "inputTokens": 1000,
      "outputTokens": 250,
      "cacheCreationTokens": 50,
      "cacheReadTokens": 500,
      "totalTokens": 1800,
      "estimatedCostUSD": 1.25,
      "sessionCount": 3
    }
  ],
  "totalCostUSD": 1.25,
  "totalTokens": 1800
}
```

With `--days`, MeterBar derives the response from cached daily rows without rescanning logs.
Provider-level daily rows do not retain `cacheCreationTokens` or `sessionCount`, so those fields are
omitted in a windowed response. Cost-cache schema v2 does retain day × model and day × project
attribution; when every included row is v2, windowed providers may include `modelBreakdowns` and
`projectBreakdowns`. `period.isTruncated` is true when the cache covers fewer days than requested.

### Month-to-date window

`--month-to-date` is a second calendar-aware window alongside `--days`, in the same cached-daily-row
family (no rescan, and mutually exclusive with `--days`). `period.kind` distinguishes the three
period shapes: `"days"`, `"monthToDate"`, or omitted entirely for the full, unwindowed summary (the
version 1 fixture above never sets it, so that response is byte-for-byte unchanged).

`models` is a provider-independent rollup of the same model name across providers.
It is omitted when any selected provider lacks complete model attribution.

`meterbar serve` `GET /cost` accepts the same windows as query parameters:
`?days=7` and `?monthToDate=true`. Combining them prefers month-to-date.

```json
{
  "schemaVersion": 1,
  "lastScannedAt": "2026-07-14T10:00:00Z",
  "period": {
    "requestedDays": 14,
    "coveredDays": 14,
    "isTruncated": false,
    "kind": "monthToDate"
  },
  "providers": [
    {
      "provider": "claude",
      "displayName": "Claude Code",
      "inputTokens": 1000,
      "outputTokens": 250,
      "cacheReadTokens": 550,
      "totalTokens": 1800,
      "estimatedCostUSD": 1.25,
      "modelBreakdowns": [
        {
          "name": "claude-opus-5",
          "inputTokens": 1000,
          "outputTokens": 250,
          "cacheCreationTokens": 50,
          "cacheReadTokens": 550,
          "totalTokens": 1850,
          "estimatedCostUSD": 1.25,
          "sessionCount": 3
        }
      ],
      "projectBreakdowns": [
        {
          "name": "meterbardev",
          "inputTokens": 1000,
          "outputTokens": 250,
          "cacheCreationTokens": 50,
          "cacheReadTokens": 550,
          "totalTokens": 1850,
          "estimatedCostUSD": 1.25,
          "sessionCount": 3,
          "modelBreakdowns": [
            {
              "name": "claude-opus-5",
              "inputTokens": 1000,
              "outputTokens": 250,
              "cacheCreationTokens": 50,
              "cacheReadTokens": 550,
              "totalTokens": 1850,
              "estimatedCostUSD": 1.25,
              "sessionCount": 3
            }
          ]
        }
      ]
    }
  ],
  "totalCostUSD": 1.25,
  "totalTokens": 1800
}
```

Both totals are always derived by summing `providers`, so an empty `providers` array pairs only with
`"totalCostUSD": 0` / `"totalTokens": 0`. As with `--days`, windowed provider entries omit
provider-level `cacheCreationTokens` and `sessionCount`. Breakdown rows retain those fields as part
of their attribution record, so their token total can include cache creation even though the
provider's windowed `totalTokens` does not.

`requestedDays` for a month-to-date window is however many days have elapsed since the 1st of the
current month (inclusive), computed in the local time zone at read time — it is never a cached start
date, so the same cache reports a larger window tomorrow without a rescan or restart.

### Model and project/worktree breakdown

Each provider may carry `modelBreakdowns` plus `projectBreakdowns`: a per-project/worktree rollup
derived from scanned session paths, with its own nested `modelBreakdowns`. Full unwindowed responses
derive them from the scan totals. `--days` and `--month-to-date` derive them from cost-cache v2's
daily attribution and restrict every row to the selected calendar days.

Both fields are omitted when attribution is incomplete. In particular, a migrated v1 cache keeps
its provider totals readable but cannot reconstruct historical model/project rows; MeterBar queues
a normal background rescan, and the CLI omits the incomplete breakdowns until that v2 scan lands.
It never substitutes the full 30-day breakdown into a shorter month window.

```json
{
  "provider": "claude",
  "displayName": "Claude Code",
  "inputTokens": 1000,
  "outputTokens": 250,
  "cacheCreationTokens": 50,
  "cacheReadTokens": 500,
  "totalTokens": 1800,
  "estimatedCostUSD": 1.25,
  "sessionCount": 3,
  "modelBreakdowns": [
    {
      "name": "claude-opus-5",
      "inputTokens": 1000,
      "outputTokens": 250,
      "cacheCreationTokens": 50,
      "cacheReadTokens": 500,
      "totalTokens": 1800,
      "estimatedCostUSD": 1.25,
      "sessionCount": 3
    }
  ],
  "projectBreakdowns": [
    {
      "name": "meterbardev",
      "inputTokens": 800,
      "outputTokens": 200,
      "cacheCreationTokens": 40,
      "cacheReadTokens": 400,
      "totalTokens": 1440,
      "estimatedCostUSD": 1.00,
      "sessionCount": 2,
      "modelBreakdowns": [ ]
    },
    {
      "name": "unknown",
      "inputTokens": 200,
      "outputTokens": 50,
      "cacheCreationTokens": 10,
      "cacheReadTokens": 100,
      "totalTokens": 360,
      "estimatedCostUSD": 0.25,
      "sessionCount": 1,
      "modelBreakdowns": [ ]
    }
  ]
}
```

Every usage event attributes to exactly one project row; an event whose path can't be attributed to
a project lands in an explicit `unknown` row rather than being dropped or guessed. Names are
sanitized before they ever reach the cache or this JSON — no full home-directory paths — and
MeterBar never persists branch names, remotes, prompt content, or credentials to derive them.

### Session breakdown

Each provider may also carry `sessionBreakdowns`: one row per local session (Codex conversation id,
Claude transcript stem, Grok session id). Project rows nest the same sessions under
`projectBreakdowns[].sessionBreakdowns`. The field is omitted when empty. Identifiers are stable
local stems — never working directories, prompts, credentials, branch names, or git remotes.

Session ids are only unique within their own project, so the provider-level list qualifies any name
that would otherwise be ambiguous as `"<project>/<session>"`: the `unknown` fallback bucket always,
and any id recorded under more than one project. Every other row keeps the bare session id. Rows
nested under `projectBreakdowns[]` are already scoped by their parent project and always use the bare
id. Match on the trailing path component if you want to pair a provider-level row with its project.

```json
{
  "sessionBreakdowns": [
    {
      "name": "aabbccdd-1111-2222-3333-444444444444",
      "inputTokens": 1000,
      "outputTokens": 250,
      "cacheCreationTokens": 50,
      "cacheReadTokens": 500,
      "totalTokens": 1800,
      "estimatedCostUSD": 1.25,
      "sessionCount": 3,
      "modelBreakdowns": []
    }
  ]
}
```

### Display currency

`--currency CODE --rate N` (both required together) adds a top-level `displayCurrency` object
converting `totalCostUSD` for display. This is presentation-only: stored and exported cost data
always stays USD, and MeterBar never fetches a live exchange rate — `unitsPerUSD` and `enteredAt` are
exactly what the caller typed for that one invocation. The field is omitted entirely unless both
flags are supplied.

```json
{
  "displayCurrency": {
    "code": "EUR",
    "unitsPerUSD": 0.92,
    "enteredAt": "2026-07-20T10:00:00Z",
    "totalCostConverted": 1.15,
    "source": "manual"
  }
}
```

`source` is always `"manual"` — a marker (not a variant to branch on today) that a future live-rate
source, if ever added, would need to distinguish itself from.

### Pricing provenance

Added in version 1 as an additive field. Events are priced at the rate in effect at their own
timestamp, so a scan can span more than one rate entry. The top-level `pricing` object reports
which entries the cached scan actually used:

```json
{
  "pricing": {
    "verifiedFrom": "2026-01-05",
    "verifiedThrough": "2026-07-02",
    "eventsBeforeFirstEntry": 0
  }
}
```

- `verifiedFrom` / `verifiedThrough` — verification dates of the oldest and newest rate entry that
  priced this scan. Equal when a single entry priced everything.
- `eventsBeforeFirstEntry` — events older than every entry in the pricing table. Those are priced
  at the oldest known rate, so a non-zero value means the total is an estimate for that portion.

The object is omitted entirely when the cache predates dated pricing or the scan priced nothing.
Consumers on version 1 that do not know the field keep working unchanged.

## Errors

When cached input is unavailable, JSON mode still emits a versioned document:

```json
{
  "schemaVersion": 1,
  "error": {
    "code": "usage_cache_missing",
    "message": "No cached metrics found. Open MeterBar app to fetch data."
  }
}
```

Stable version 1 error codes are `usage_cache_missing` and `cost_cache_missing`.

## Refresh

```sh
meterbar refresh --json
meterbar refresh --timeout 30 --json
```

Refresh performs one bounded, non-overlapping pass through MeterBar's existing provider
coordinator. It uses the provider visibility and account configuration explicitly mirrored by the
app; if that configuration is unavailable, the command fails without modifying shared metrics.
Provider errors and reasons are redacted and never include credentials or response bodies.

Version 1 shape:

```json
{
  "schemaVersion": 1,
  "outcome": "partialFailure",
  "collectedAt": "2026-07-20T17:00:00Z",
  "durationSeconds": 1.25,
  "providers": [
    {
      "provider": "codex",
      "displayName": "OpenAI Codex",
      "state": "refreshed",
      "servedFromCache": false,
      "lastUpdated": "2026-07-20T17:00:00Z"
    },
    {
      "provider": "cursor",
      "displayName": "Cursor",
      "state": "failed",
      "reason": "The provider returned an invalid response.",
      "servedFromCache": true,
      "lastUpdated": "2026-07-20T16:45:00Z"
    }
  ],
  "cache": {
    "providerCount": 2,
    "lastUpdated": "2026-07-20T17:00:00Z",
    "ageSeconds": 0,
    "isStale": false
  },
  "message": "1 provider(s) failed to refresh (Cursor); 1 kept last-known-good metrics."
}
```

`providers[].state` is `refreshed`, `failed`, or `skipped`. `outcome` is `success`,
`partialFailure`, `refreshFailed`, `alreadyRunning`, `timedOut`, or `cancellation`.

Exit codes are stable for scripting: `0` success, `10` already running, `11` timeout,
`12` partial provider failure, `13` complete/configuration failure, and `130` cancellation.
Non-success JSON remains on standard output; optional human diagnostics use standard error.

A rejected `--timeout` adds an `error` object with a stable `code`, plus the `flag` and `value`
that were rejected, and reports `refreshFailed` (exit `13`). It is a refresh document like any
other, so a script parses one shape whether the input or the provider was at fault:

```json
{
  "schemaVersion": 1,
  "outcome": "refreshFailed",
  "collectedAt": "2026-07-20T17:00:00Z",
  "durationSeconds": 0,
  "providers": [],
  "cache": { "providerCount": 2, "lastUpdated": "2026-07-20T16:45:00Z", "ageSeconds": 900, "isStale": false },
  "error": {
    "code": "invalid_timeout",
    "message": "Invalid --timeout value 'abc'. Expected 1...600 seconds.",
    "flag": "--timeout",
    "value": "abc"
  },
  "message": "Invalid --timeout value 'abc'. Expected 1...600 seconds."
}
```

The stable version 1 refresh error code is `invalid_timeout`; `--timeout` accepts `1`–`600`
seconds. Malformed input never exits `EX_USAGE` (`64`) and never puts non-JSON on standard output.

`SIGINT` and `SIGTERM` cancel the refresh cooperatively rather than killing the process: in-flight
provider work stops, the document is still written to standard output, and the command exits `130`
(`cancellation`). Once that document is out, an over-running refresh is given a bounded grace
period to release the cross-process refresh lock before the process exits, so a later `meterbar
refresh` is not answered `alreadyRunning` by an abandoned holder.

## Guard

```sh
meterbar guard --provider claude --limit session --min-remaining 25
meterbar guard --provider codex --limit weekly --json
meterbar guard --provider grok --config-dir ~/.grok-work --json
meterbar guard --config-dir ~/.claude-work --refresh --json
```

Guard answers one question — may this caller spend quota right now? — and encodes the answer in
its exit code. It reads the cached snapshot MeterBar maintains, so a shell hook costs a file read
rather than a provider round trip; `--refresh` opts into one bounded refresh through the same
coordinator `meterbar refresh` uses, then evaluates the resulting cache. Guard never waits for a
quota to reset and never consumes a reset credit — that is `meterbar wake`.

Severity comes from the shared quota band model the menu bar and `meterbar usage` already use, so
a band threshold change moves guard's behavior with it.

`--limit` accepts the version 1 window tokens `session`, `weekly`, and `code-review`. Additive
cadence selectors `daily`, `monthly`, `billing`, and `unknown` resolve a reported period by
`periodKind` — including a monthly allowance stored in the weekly slot, or an extra daily
period in `additionalLimits`. `--min-remaining` is a percentage of quota that must remain;
without it, only exhaustion blocks. `--config-dir` narrows the check to one configured Claude
Code, OpenAI Codex, or Grok account by its configuration directory (Claude/Codex config dir, or
Grok `GROK_HOME`). Cursor and OpenRouter have no per-account directories and are rejected.
The JSON `window` field stays `session`, `weekly`, or `codeReview`. Additive `periodKind` names
the reported cadence. Human `message` text uses that cadence ("monthly", never "weekly" for a
monthly Grok allowance).

Version 1 shape:

```json
{
  "schemaVersion": 1,
  "outcome": "belowThreshold",
  "exitCode": 10,
  "checkedAt": "2026-07-20T17:00:00Z",
  "provider": "claude",
  "displayName": "Claude Code",
  "window": "session",
  "account": {
    "scope": "provider",
    "name": "All accounts"
  },
  "used": 82,
  "total": 100,
  "percentUsed": 82,
  "percentLeft": 18,
  "quotaBand": "tight",
  "estimated": false,
  "resetAt": "2026-07-20T18:00:00Z",
  "minRemainingPercent": 25,
  "snapshot": {
    "lastUpdated": "2026-07-20T16:59:00Z",
    "ageSeconds": 60,
    "isStale": false
  },
  "message": "Claude Code session quota below threshold: 18% left (minimum 25%). Resets in 1h."
}
```

`outcome` is `available`, `belowThreshold`, `exhausted`, `dataUnavailable`, or `usageError`.
`quotaBand` uses the same tokens as `meterbar usage --json`. `account.scope` is `provider` for the
provider-wide roll-up or `account` when `--config-dir` selected one account.

Every field beyond `schemaVersion`, `outcome`, `exitCode`, `checkedAt`, and `message` is optional:
a usage error never reaches a provider, and an unavailable snapshot has no numbers to report.
Omission means "not known" — guard never emits a zero that could read as available.

Non-success outcomes add an `error` object with a stable `code`, plus `flag` and `value` when a
caller-supplied input was at fault:

```json
{
  "schemaVersion": 1,
  "outcome": "usageError",
  "exitCode": 13,
  "checkedAt": "2026-07-20T17:00:00Z",
  "message": "Unknown quota window 'hourly' for --limit. Expected one of: session, weekly, code-review, daily, monthly, billing, unknown.",
  "error": {
    "code": "invalid_window",
    "message": "Unknown quota window 'hourly' for --limit. Expected one of: session, weekly, code-review, daily, monthly, billing, unknown.",
    "flag": "--limit",
    "value": "hourly"
  }
}
```

Stable version 1 guard error codes are `snapshot_missing`, `snapshot_stale`, `window_unavailable`,
`account_lookup_unavailable`, `invalid_provider`, `invalid_window`, `invalid_threshold`,
`invalid_refresh_timeout`, `unsupported_config_dir`, and `unknown_account`.

Exit codes are stable for scripting:

| Code | Outcome | Meaning |
| --- | --- | --- |
| `0` | `available` | The evaluated window is at or above `--min-remaining` and not exhausted. |
| `10` | `belowThreshold` | Quota remains, but less than `--min-remaining`. Distinct from exhausted so a caller can throttle before it is blocked. |
| `11` | `exhausted` | The window is spent. `resetAt` and the message carry the reset time. |
| `12` | `dataUnavailable` | No usable snapshot, a snapshot older than the freshness bound without `--refresh`, or a window the provider did not report. Never reported as available. |
| `13` | `usageError` | An invalid `--provider`, `--limit`, `--min-remaining`, `--refresh-timeout`, or `--config-dir`. The message names the offending input. |

The freshness bound is two hours, shared with the provider parse-health model. A snapshot older
than that is `dataUnavailable` rather than a stale pass. Non-success JSON stays on standard output;
the human-readable reason uses standard error.

`SIGINT` and `SIGTERM` end a `--refresh` window early instead of killing the process. Guard then
evaluates the cached snapshot exactly as it would after a refresh that simply failed, and exits
with one of the codes above — guard has no cancellation code, because an interrupted guard still
has an answer. Without `--refresh` there is no window to interrupt.

## Doctor

```sh
meterbar doctor --json
```

Doctor emits a JSON array of redacted readiness reports. Unlike the usage and cost integration
documents, it is a diagnostic DTO rather than a versioned cache schema:

```json
[
  {
    "provider": "Codex CLI",
    "accountId": "00000000-0000-0000-0000-000000000002",
    "accountName": "Default CLI Profile",
    "overall": "warn",
    "healthy": false,
    "checks": [
      {
        "id": "auth",
        "title": "Signed in",
        "level": "warn",
        "detail": "Sign-in not verified yet.",
        "recovery": "Run `codex login`."
      }
    ]
  }
]
```

`overall` and `checks[].level` are `pass`, `warn`, or `fail`. `healthy` is true only when
`overall` is `pass`. Multi-account providers (Claude, Codex, Grok) emit one object per enabled
profile, plus a provider-wide aggregate when more than one profile is enabled. `accountId` is
MeterBar's local profile id and `accountName` is the user-facing display name; both are omitted
for provider-wide reports (Cursor, OpenRouter, and the aggregate). Filesystem paths, credentials,
tokens, passwords, authorization headers, and raw response bodies are never emitted. Diagnostic
messages may use standard error, but standard output remains one JSON document.

## Serve

```sh
meterbar serve
meterbar serve --port 8787 --max-requests-per-second 10
meterbar serve --token "$(openssl rand -hex 32)"
meterbar serve --allow-remote
```

`meterbar serve` runs a small, opt-in HTTP endpoint that serves the exact same schema-versioned
`UsageCLIJSONResponse` and `CostCLIJSONResponse` documents `meterbar usage --json` and
`meterbar cost --json` print — there is no second serialization to drift from the CLI. It reads
MeterBar's existing cached app-group snapshot; it never triggers a provider refresh, never spends a
reset credit, and never accepts a write, mutation, or configuration change. There is no endpoint
that changes state.

**Bind address.** The server binds to loopback (`127.0.0.1`) only by default, so it is not reachable
from other devices. Reaching any other interface requires the explicit `--allow-remote` flag, which
also prints a warning to standard error before the server starts:

```text
⚠ meterbar serve is bound to all network interfaces (--allow-remote). Usage and cost data will be
reachable from other devices on this network; anyone with the printed bearer token can read it.
```

**Authentication.** Every request must carry `Authorization: Bearer <token>`. If `--token` is not
supplied, a random 256-bit token is generated and printed once, at startup, to standard output; it
is never logged again and never appears in any response body, including error bodies. Token
comparison is constant-time. A blank `--token` is rejected before the socket binds, so the server
can never come up with an auth check that accepts every caller. A missing or incorrect token always
returns `401` with a generic `unauthorized` error body — before routing even inspects the path or
method, so an unauthenticated caller cannot use status codes to enumerate endpoints.

**Connection limits.** A request must deliver its complete header block within 5 seconds of
connecting, measured against the connection as a whole rather than per socket read, so a client that
trickles bytes cannot hold a handler open indefinitely. Request heads over 8 KiB are rejected.

**Endpoints** (`GET` only; any other method on a known path returns `405`):

| Method & path | Query parameters | Behavior |
| --- | --- | --- |
| `GET /usage` | `provider` (optional, same matching as `meterbar usage --provider`); `account` (optional, same matching as `meterbar usage --account`: exact account id or name) | Returns `UsageCLIJSONResponse` |
| `GET /cost` | `days` (optional, same matching as `meterbar cost --days`; non-positive or non-numeric values are ignored) | Returns `CostCLIJSONResponse` |

An unknown path returns `404` with the same generic error envelope. If the underlying cache is
empty (no metrics yet, or no cost scan yet), the endpoint returns `200` with the same
`usage_cache_missing` / `cost_cache_missing` error document `meterbar usage --json` /
`meterbar cost --json` already return in that situation — same codes, same messages.

**Headers.** Every response — data and error alike — sets `Cache-Control: no-store` and
`Content-Type: application/json; charset=utf-8`. Responses are never cached by clients or
intermediaries.

**Rate limiting.** Requests are bounded to `--max-requests-per-second` (default 5) **per client
address**; requests beyond that return `429` with the standard error envelope (`too_many_requests`).
The budget is charged before a request is parsed or authenticated, so keying it by source is what
keeps an unauthenticated burst — the risk `--allow-remote` introduces — from consuming the token
holder's allowance. A local client still sees exactly the documented default: every loopback caller
shares the `127.0.0.1` bucket. A malformed HTTP request returns `400` (`bad_request`).

**Lifecycle.** `meterbar serve` runs until it receives `SIGINT` or `SIGTERM` (for example, Ctrl-C),
at which point it stops accepting new connections, closes its listening socket, and exits cleanly.

Errors reuse the same `CLIJSONErrorResponse` envelope as the rest of the CLI:

```json
{
  "schemaVersion": 1,
  "error": {
    "code": "unauthorized",
    "message": "Missing or invalid bearer token."
  }
}
```

Stable version 1 serve error codes are `unauthorized` (401), `not_found` (404),
`method_not_allowed` (405), `too_many_requests` (429), `bad_request` (400), and the
pre-existing `usage_cache_missing` / `cost_cache_missing` (200).

## Quota event webhooks

The app's explicitly enabled webhook integration uses a separate public
version 1 event document. It is included here so every public MeterBar JSON
contract has one compatibility index, even though this body is sent by the app
rather than printed by the CLI:

```json
{
  "schema_version": 1,
  "provider": "Codex CLI",
  "account": {
    "id": "AB45485C-7C78-4E71-A238-A2EED2C97DC5",
    "name": "Work"
  },
  "event": "exhausted",
  "window": "weekly",
  "period_kind": "monthly",
  "percentage": 100,
  "band": "exhausted",
  "timestamp": "2027-01-15T08:00:00Z"
}
```

Version 1 fields will not be removed, renamed, or change type; additive fields
may appear. The complete field definitions, transition semantics, local-command
environment, privacy guarantees, and webhook URL boundary are documented in
[Quota event webhook contract](quota-event-webhooks.md).
