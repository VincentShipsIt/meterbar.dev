# MeterBar CLI JSON schema

`meterbar usage --json`, `meterbar cost --json`, `meterbar refresh --json`,
`meterbar guard --json`, and `meterbar fable-sessions --json` emit stable,
versioned JSON for menu bars, shell prompts, dashboards, and other third-party integrations.
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

`windows[].kind` is `session`, `weekly`, or `codeReview`. `percentUsed` is clamped to `0...100`
for display, while `used` and `total` preserve the source values. `percentLeft` and `quotaBand`
use MeterBar's shared quota rules; `quotaBand` is `healthy`, `tight`, `critical`, or `exhausted`.
`estimated` identifies totals MeterBar inferred instead of receiving from the provider.

`extraUsage.state` is `on`, `off`, or `unknown`; its optional `detail` is provider-supplied display
context. `resetCreditsAvailable` is present only when the provider reports banked reset credits.

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
Daily rows do not retain `cacheCreationTokens` or `sessionCount`, so those fields are omitted in a
windowed response. `period.isTruncated` is true when the cache covers fewer days than requested.

### Month-to-date window

`--month-to-date` is a second calendar-aware window alongside `--days`, in the same cached-daily-row
family (no rescan, and mutually exclusive with `--days`). `period.kind` distinguishes the three
period shapes: `"days"`, `"monthToDate"`, or omitted entirely for the full, unwindowed summary (the
version 1 fixture above never sets it, so that response is byte-for-byte unchanged).

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
      "estimatedCostUSD": 1.25
    }
  ],
  "totalCostUSD": 1.25,
  "totalTokens": 1800
}
```

Both totals are always derived by summing `providers`, so an empty `providers` array pairs only with
`"totalCostUSD": 0` / `"totalTokens": 0`. As with `--days`, windowed provider entries omit
`cacheCreationTokens` and `sessionCount`, which daily rows do not retain.

`requestedDays` for a month-to-date window is however many days have elapsed since the 1st of the
current month (inclusive), computed in the local time zone at read time — it is never a cached start
date, so the same cache reports a larger window tomorrow without a rescan or restart.

### Project/worktree breakdown

Each provider in the full, unwindowed summary (no `--days`/`--month-to-date`) may carry
`projectBreakdowns`: a per-project/worktree rollup derived from scanned session paths, with its own
nested `modelBreakdowns`. The field is omitted entirely when nothing was scanned with a project
dimension — including every windowed (`--days`/`--month-to-date`) response, since daily rows carry no
project dimension of their own.

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

Every session attributes to exactly one project row; a session whose path can't be attributed to a
project lands in an explicit `unknown` row rather than being dropped or guessed. Names are sanitized
before they ever reach this JSON — no full home-directory paths — and MeterBar never persists branch
names, remotes, prompt content, or credentials to derive them.

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

## Fable sessions

```sh
meterbar fable-sessions
meterbar fable-sessions --json
```

This command reads the app's persisted Fable 5 tracker snapshot without scanning transcripts.
An empty snapshot is successful and returns an empty `sessions` array.

Version 1 shape:

```json
{
  "schemaVersion": 1,
  "sessions": [
    {
      "id": "00000000-0000-0000-0000-000000000002:session-1",
      "profile": {
        "id": "00000000-0000-0000-0000-000000000002",
        "name": "Ship"
      },
      "model": "claude-fable-5",
      "state": "active",
      "firstObservedAt": "2026-07-20T10:00:00Z",
      "lastObservedAt": "2026-07-20T10:05:00Z"
    }
  ]
}
```

`state` is `active`, `completed`, or `unknown`. Records are newest-first and deduplicated by the
stable `id`. The response contains tracker metadata only: it never includes prompt/response
content, credentials, working directories, or git metadata.

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

## Guard

```sh
meterbar guard --provider claude --limit session --min-remaining 25
meterbar guard --provider codex --limit weekly --json
meterbar guard --config-dir ~/.claude-work --refresh --json
```

Guard answers one question — may this caller spend quota right now? — and encodes the answer in
its exit code. It reads the cached snapshot MeterBar maintains, so a shell hook costs a file read
rather than a provider round trip; `--refresh` opts into one bounded refresh through the same
coordinator `meterbar refresh` uses, then evaluates the resulting cache. Guard never waits for a
quota to reset and never consumes a reset credit — that is `meterbar wake`.

Severity comes from the shared quota band model the menu bar and `meterbar usage` already use, so
a band threshold change moves guard's behavior with it.

`--limit` accepts `session`, `weekly`, and `code-review`. `--min-remaining` is a percentage of
quota that must remain; without it, only exhaustion blocks. `--config-dir` narrows the check to one
configured Claude Code or OpenAI Codex account by its configuration directory.

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
  "message": "Unknown quota window 'hourly' for --limit. Expected one of: session, weekly, code-review.",
  "error": {
    "code": "invalid_window",
    "message": "Unknown quota window 'hourly' for --limit. Expected one of: session, weekly, code-review.",
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
`overall` is `pass`. The report contains only the fields shown above; credential, token, password,
authorization, and secret-bearing fields are never emitted. Diagnostic messages may use standard
error, but standard output remains one JSON document.

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
| `GET /usage` | `provider` (optional, same matching as `meterbar usage --provider`) | Returns `UsageCLIJSONResponse` |
| `GET /cost` | `days` (optional, same matching as `meterbar cost --days`; non-positive or non-numeric values are ignored) | Returns `CostCLIJSONResponse` |

An unknown path returns `404` with the same generic error envelope. If the underlying cache is
empty (no metrics yet, or no cost scan yet), the endpoint returns `200` with the same
`usage_cache_missing` / `cost_cache_missing` error document `meterbar usage --json` /
`meterbar cost --json` already return in that situation — same codes, same messages.

**Headers.** Every response — data and error alike — sets `Cache-Control: no-store` and
`Content-Type: application/json; charset=utf-8`. Responses are never cached by clients or
intermediaries.

**Rate limiting.** Requests are bounded to `--max-requests-per-second` (default 5) per server
instance; requests beyond that return `429` with the standard error envelope (`too_many_requests`).
A malformed HTTP request returns `400` (`bad_request`).

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
