# Deferred Work / Tech Debt

Items intentionally **not** done in the 2026-06-26 cleanup pass, with enough
detail to pick up later (e.g. on a machine with full Xcode). See
`.agents/SESSIONS/2026-06-26.md` for the broader context.

---

## 1. Extract a `MeterBarShared` package (end the struct drift)

**Status:** done (2026-07-02) — `Packages/MeterBarShared` created and consumed by
the app, widget, and CLI targets; the three forked copies were deleted and the
Xcode project links the local package. Local verification: `swift build` on the
package/root/CLI + widget typecheck + live CLI smoke test; the xcodebuild
app+widget build is exercised by CI (no full Xcode on the dev machine). See
`.agents/SESSIONS/2026-07-02.md`. Original problem statement kept below for
context.

### Problem

`ServiceType`, `UsageLimit`, `UsageMetrics`, and `UsageStatus` are **copied** into
three targets and have already diverged:

| Type | App (`MeterBar/Models`) | Widget (`MeterBarWidget/UsageWidget.swift`) | CLI (`MeterBarCLI/Sources/MeterBarCLI.swift`) |
|---|---|---|---|
| `UsageLimit.used/total` | `Double` + `windowSeconds: TimeInterval?` | `Double`, no `windowSeconds`, adds `clampedUsed/clampedTotal` | was `Int` (fixed → `Double`); no `windowSeconds` |
| `ServiceType.iconName` | SF Symbol names | asset-catalog names (`ClaudeIcon`…) | n/a |
| `ServiceType.sortOrder` | absent | present | absent |
| `UsageMetrics` | has `extraUsage`, `resetCreditsAvailable` | missing both (silently dropped on decode) | partial (`ServiceMetrics`) |

Because `JSONDecoder` ignores unknown keys, the drift is silent today, but any new
shared field is a latent decode bug across targets.

### Proposed fix

1. Create a local Swift package target `MeterBarShared` (e.g. `Packages/MeterBarShared`
   or a target inside `MeterBar.xcodeproj`).
2. Move the canonical `ServiceType`, `UsageLimit`, `UsageMetrics`, `UsageStatus`
   (+ `UsagePace`/duration helpers) into it. Before moving, reconcile:
   - keep `windowSeconds: TimeInterval?` on the canonical `UsageLimit`;
   - move `sortOrder` onto the canonical `ServiceType`;
   - decide one `iconName` story (e.g. `iconName` = SF Symbol, plus a separate
     `assetName` for the widget) rather than two conflicting `iconName`s;
   - keep `extraUsage` / `resetCreditsAvailable` on the canonical `UsageMetrics`.
3. Add `MeterBarShared` as a dependency of the `MeterBar`, `MeterBarWidget`, and
   `MeterBarCLI` targets and delete the three forked copies.
4. Verify with `xcodebuild` (app + widget) and `swift build` (CLI), and run the
   XCTest suite (needs full Xcode).

### Why it's worth it

One source of truth for the wire format ⇒ no silent decode drift, and the
widget/CLI automatically gain fields the app adds.

---

## 2. `OAuthTokenExpiry.isExpired(jwt:)` on malformed tokens — left as-is (by design)

**Status:** intentional, documented in code (`MeterBar/Services/OAuthTokenExpiry.swift`).

A code reviewer flagged that `isExpired(jwt:)` returns `false` (not-expired) when
the token can't be parsed (no `exp` claim / bad base64).

**Decision:** keep returning `false`. If we cannot introspect a token we should
**not** lock the user out of a session whose format we don't fully understand —
the server is the source of truth and will `401` a genuinely invalid token on the
next request (which the services already handle). Flipping this to "malformed ⇒
expired" risks regressing real Codex setups whose token isn't a standard JWT, and
that regression can't be reproduced/tested locally without live credentials.

If we ever want the stricter behavior, gate it behind telemetry first (count how
often `expirationDate(fromJWT:)` returns `nil` for live tokens) before changing
the default.
