# Public profile contract

**Share → Public profile** publishes an anonymous, live copy of your limits to
`https://meterbar.dev/u/<slug>`. It is off by default; MeterBar sends nothing
until you turn it on, and turning it off deletes the published copy.

This file is the contract between the app (this repo) and the site
(`VincentShipsIt/landings`, `apps/meterbardev`). Decision record:
`.agents/memory/decisions.md`, "Public profile is the one opt-in exception to
no backend".

## Identity

- `slug`: 10 characters of lowercase Crockford base32 (`[0-9a-hjkmnp-tv-z]`),
  generated on the Mac. It is the only thing in the public URL.
- `publishKey`: 32 random bytes, base64url, kept in the Keychain. It is never
  in a URL. The server stores only its SHA-256.
- The first `PUT` for a slug claims it. Every later `PUT` and the `DELETE`
  must present the same key. A different key gets `401`, `403` or `409`.
- Reset deletes the old profile before minting a replacement slug and key.
  A failed deletion keeps reset pending across relaunches; the old identity
  is retained for deletion retries and cannot be republished. Sharing actions
  resume only after deletion succeeds and the replacement key is stored.
- If the deletion key is unavailable, reset remains pending and offers an
  explicit recovery action. After confirming that the old URL may remain public
  until server expiry (up to 7 days after its last upload), the user can abandon
  that deletion and create a replacement. This never claims the old profile was
  deleted. Restoring the key instead allows the ordinary deletion retry to finish.

## Endpoints (served by the site)

```
PUT    /api/profile/<slug>   Authorization: Bearer <publishKey>   body: document
DELETE /api/profile/<slug>   Authorization: Bearer <publishKey>
```

- `PUT` upserts. `200`, `201` or `204` on success.
- `DELETE` removes the record and is idempotent: `200`, `204` or `404` all
  mean "gone". The app retries a failed delete until it gets one of these.
- The site must expire a record **7 days after its last `PUT`**, so a lost key
  or a Mac that never returns cannot leave data up forever.
- The site must not follow or emit redirects on these routes (the app refuses
  to follow them), and must not log the `Authorization` header.
- Reject bodies over 16 KB, a `schema` it does not know, and a `slug` that is
  not 10 characters of the alphabet above.
- The app writes at most once per 15 minutes while values change, and once an
  hour otherwise.

## Document (`schema: 1`)

```json
{
  "schema": 1,
  "updatedAt": "2026-09-29T20:00:00Z",
  "providers": [
    {
      "provider": "Claude Code",
      "name": "Claude Code",
      "plan": "Max 20x",
      "windows": [
        { "label": "Session", "usedPercent": 42, "resetsAt": "2026-09-29T23:00:00Z", "pace": "On pace" },
        { "label": "Weekly", "usedPercent": 17, "resetsAt": "2026-10-03T08:00:00Z", "pace": null }
      ]
    }
  ],
  "receipt": {
    "tokens30d": 84200000,
    "sessions": 312,
    "models": [{ "provider": "Claude Code", "name": "claude-opus-5-5", "tokens": 51000000 }],
    "dailyTokens": [1200000, 900000, 0, 3100000, 2800000, 4100000, 2200000]
  }
}
```

- `provider` is the app's exact `ServiceType.rawValue`: `Claude Code`,
  `Codex CLI`, `Cursor`, `OpenRouter`, `Grok`, `Kimi Code`, `Z.ai Coding Plan`,
  or `GitHub Copilot`. The site maps it to a logo and color. Unknown ids
  should render with a neutral mark. Only quota windows are published;
  currency budgets are omitted, including Copilot's monthly dollar budget.
  A currency-only provider does not acquire an invented quota window.
- `name` is the provider's display name, with an ordinal for a second account
  of the same provider (`OpenAI Codex 2`), or `<pool> on <parent>` for a
  sub-pool (`Grok Bot on Cursor`). It is never an account name.
- `plan`, `pace` and `resetsAt` may be `null` or absent. `resetsAt` is rounded
  to the minute. `plan` is included only when its account ownership is
  unambiguous across the full snapshot input, before window sanitization or
  provider caps. Multiple account cards suppress the provider-wide plan;
  sub-pools never count as accounts or carry a plan. Claude, Codex and Grok
  custom accounts cannot inherit the default account's plan. A sole default
  account or legacy provider-wide snapshot without an account id may retain it.
- `usedPercent` is 0-100. The card shows "left", which is `100 - usedPercent`.
- Optional availability metadata in schema 1: each window has `role`
  (`provider` or `secondary`) and `isEstimated` (boolean). Each provider has
  `primaryWindowIndex` (an index into its sanitized windows, omitted if the
  primary window was filtered out) and `isBlocked` (boolean). These come from
  the app's provider availability policy, including Cursor's included-pool
  spillover and paid extra usage; model-specific limits do not block the parent.
  Older documents remain valid. When a provider is blocked, the app publishes
  only blocking windows; the site uses the same compact presentation. Exhausted
  measured rows show their reset without a progress bar, and reset dates older
  than the five-minute due grace period are omitted. Amount-only credit balances
  remain private and never become an invented percentage.
- `receipt` is this Mac's local scan and is absent when there is nothing to
  show. It contains 30-day token and session totals, top models, and daily
  tokens for the last 7 days. `dailyTokens` is oldest first, 7 entries, most
  recent day last.
- Only the keys above exist. The site must ignore unknown keys, and the app's
  tests fail if a key is added without updating the allowlist.

## Never published

Names, emails, account names or ids, device names, folders, project or session
names, credentials, and dollar amounts. Labels and model ids pass a character
allowlist; anything else (an email, a path, a fine-tune id) is dropped rather
than sent.

## Site behaviour (implemented in `landings`, PR 17)

- `PUT` answers `204`; `400` invalid body or key, `401` no bearer, `403`/`409`
  wrong key or slug lost, `413` over 16 KB, `429` (with `Retry-After`) when a
  slug is written more than once per 30 s or one address claims more than 10
  new slugs an hour, `503` when storage is not configured. `DELETE` answers
  `204`, or `403` for a wrong key. Both are `no-store` with no body.
- `/u/<slug>` renders from the stored document, is `noindex, nofollow`, and
  shows "updated <time>" from `updatedAt`. An unknown, expired or deleted slug
  is a plain 404.
- `/u/<slug>/og` is the 1200x630 card (share-card look: near-black surface, the
  icon mark, provider colors, the green/amber/red ramp). Successful and missing
  cards are `no-store`; page HTML/RSC is also served without shared caching.
- Page/card reads are fresh on each request (metadata and page reads may be
  deduplicated within one server render). Deletion and seven-day storage expiry
  take effect on the next request. A write/delete also invalidates application
  entries made by the older cached implementation.
- Social platforms may retain independent previews. We cannot revoke those
  copies by deleting a profile or invalidating our own caches.
- The site's privacy copy says "no server" is true unless the user turns on
  Public profile.
