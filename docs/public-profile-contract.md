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

- `provider` is the app's provider id: `Claude Code`, `Codex CLI`, `Cursor`,
  `OpenRouter`, `Grok`. The site maps it to a logo and color. Unknown ids
  should render with a neutral mark.
- `name` is the provider's display name, with an ordinal for a second account
  of the same provider (`OpenAI Codex 2`), or `<pool> on <parent>` for a
  sub-pool (`Grok Bot on Cursor`). It is never an account name.
- `plan`, `pace` and `resetsAt` may be `null` or absent. `resetsAt` is rounded
  to the minute.
- `usedPercent` is 0-100. The card shows "left", which is `100 - usedPercent`.
- `receipt` is this Mac's local scan and is absent when there is nothing to
  show. `dailyTokens` is oldest first, 7 entries, most recent day last.
- Only the keys above exist. The site must ignore unknown keys, and the app's
  tests fail if a key is added without updating the allowlist.

## Never published

Names, emails, account names or ids, device names, folders, project or session
names, credentials, and dollar amounts. Labels and model ids pass a character
allowlist; anything else (an email, a path, a fine-tune id) is dropped rather
than sent.

## Site requirements

- `/u/<slug>` renders from the stored document and shows "updated <time>" from
  `updatedAt`. An unknown or expired slug renders a plain not-found page with
  `noindex`. Set `robots: noindex` on profile pages unless indexing is chosen
  deliberately.
- `/u/<slug>/opengraph-image` (and a `twitter:image`) renders the card in the
  share-card look: near-black surface, MeterBar mark, provider colors, and the
  green/amber/red severity ramp from `SocialCardChrome.swift`, 1200x630.
- Read paths are cached for about a minute so page views do not touch storage.
- Update the privacy copy that says "no server" to say it is true unless the
  user turns on Public profile.
