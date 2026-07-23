# MeterBar CLI JSON schema

`meterbar usage --json`, `meterbar cost --json`, and `meterbar refresh --json` emit stable,
versioned JSON for menu bars, shell prompts, dashboards, and other third-party integrations.
Human-readable output remains the default when `--json` is absent.

## Compatibility contract

- Every document contains `schemaVersion`. The current version is `1`.
- Fields may be added without changing the version. Existing fields will not be removed, renamed,
  or change type within version 1.
- Consumers should reject unsupported major schema versions rather than guessing their shape.
- Dates use UTC ISO 8601 strings. Provider arrays and usage windows have deterministic ordering.
- Optional values are omitted when the provider or cached source did not supply them.
- JSON is the only content written to standard output for these commands.

Provider identifiers are stable tokens: `claude`, `codex`, `cursor`, and `openrouter`.

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
