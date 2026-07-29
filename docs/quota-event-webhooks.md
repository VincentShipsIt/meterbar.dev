# Quota event webhook contract

MeterBar can deliver quota transitions to one user-configured webhook from
**Settings → General → Event Integrations**. Webhooks are disabled by default.
Delivery starts only after the user separately opts into the webhook lane, a
public HTTPS URL, one or more events, providers, and accounts.

## Version 1 request

MeterBar sends an HTTP `POST` with `Content-Type: application/json`. Dates are
UTC ISO 8601 strings. The response body is ignored; any `2xx` status succeeds.

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
  "percentage": 100,
  "band": "exhausted",
  "timestamp": "2027-01-15T08:00:00Z"
}
```

Fields:

| Field | Type | Values / meaning |
|---|---|---|
| `schema_version` | integer | Current major version: `1` |
| `provider` | string | `Claude Code`, `Codex CLI`, `Cursor`, `OpenRouter`, or `Grok` |
| `account.id` | string | Account UUID, or `default` for a single-account provider |
| `account.name` | string | The user-visible account or provider name |
| `event` | string | `warning`, `critical`, `exhausted`, or `recovered` |
| `window` | string | `session`, `weekly`, or `code_review` |
| `percentage` | number | Provider usage percentage clamped to `0...100` |
| `band` | string | `healthy`, `tight`, `critical`, or `exhausted` |
| `timestamp` | string | Time the transition was observed |

Version 1 fields will not be removed, renamed, or change type. New fields may
be added without changing the version, so consumers should ignore unknown
fields. A breaking change increments `schema_version`.

## Transition semantics

MeterBar derives events from its shared quota bands:

- `warning`: enters Tight (25% or less remaining).
- `critical`: enters Critical (10% or less remaining).
- `exhausted`: reaches 0% remaining.
- `recovered`: returns to Healthy (more than 25% remaining).

Each provider/account/window is tracked independently. The first observation
primes state; it does not replay cached status as a new event. Repeated states
are deduplicated, rapid same-event flapping is debounced, and dropping out of a
band re-arms the next genuine crossing.

## Privacy and network boundary

The payload never contains provider credentials, API keys, tokens,
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, or other configuration paths. MeterBar sends
only the fields documented above.

Webhook URLs must use HTTPS on port 443 with no embedded credentials or
fragment. Literal loopback, link-local, private, multicast, single-label LAN,
and common local-service hosts are rejected. MeterBar also resolves the host
immediately before delivery and refuses it if any resolved address is
non-public. Redirects are never followed. Requests use an ephemeral,
cookie-free, credential-free session with bounded timeouts; failures are
nonfatal and do not block other events or the local-command lane.

## Local command environment

The optional local lane invokes an absolute executable directly with literal
argv entries—there is no shell, interpolation, placeholder expansion, or
command-string parsing. Quota events receive this fixed, secret-free
environment in addition to a minimal `HOME`, `PATH`, `TMPDIR`, `LANG`, and
`NO_COLOR`:

```text
METERBAR_EVENT
METERBAR_PROVIDER
METERBAR_ACCOUNT_ID
METERBAR_ACCOUNT_NAME
METERBAR_WINDOW
METERBAR_PERCENTAGE
METERBAR_BAND
METERBAR_TIMESTAMP
```

Existing Session Wake hooks migrated into Event Integrations keep their
unchanged `METERBAR_WAKE_EVENT` and `METERBAR_WAKE_PROVIDER` contract.
