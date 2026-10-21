---
name: verify-meterbar
description: Verify MeterBar quota, cache, cost, routing, UI, and CLI changes with source invariants, offline contracts, and native app checks.
---

# Verify MeterBar

Run from the repository root on the configured execution host. Read `.agents/memory/conventions.md` and the issue's acceptance criteria first.

## Establish the toolchain

Use full Xcode for XCTest and app/widget builds. Record `xcodebuild -version` and the selected developer directory. CI's release toolchain is defined in `.github/actions/select-xcode/action.yml`; local results on another version do not replace that CI evidence. If full Xcode or native UI access is unavailable, report that portion as unverified and complete the checks that are available. Do not substitute an XCTest shim.

## Choose the evidence

Start with the checks that enforce the affected invariants:

```sh
python3 scripts/test-agent-invariants.py
scripts/check-agent-invariants.sh
swiftlint lint --strict
```

Then read only the relevant feature guide:

| Change | Guide |
|---|---|
| Provider payload, quota, cache, card, widget, or hover | [Quota and native UI](references/quota.md) |
| Token accumulation, cost scan, persisted totals | [Cost](references/cost.md) |
| CLI output, workload routing, packaging | [CLI and routing](references/cli.md) |
| Public-profile state, publishing, deletion | [Public profile](references/public-profile.md) |

For shared model or refresh-owner changes, run the full `swift test` suite and build the app/widget through Xcode. For a bounded change, use the affected tests identified in the guide; expand only for an unresolved concern or a new failure. Documentation-only edits need valid references and runnable instructions, not an unrelated full rebuild.

## Record the result

Keep the head SHA, actual commands, pass/fail counts, skipped checks and reasons, and the observed UI/CLI outcome in the PR. Distinguish synthetic fixtures, real account checks, local builds, and signed release artifacts. Required CI must pass on the current head before merge. Build success alone does not prove native interaction, signing, notarization, production profile deletion, or a published release.
