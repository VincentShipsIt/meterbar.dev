---
name: add-provider
description: Plan or implement a MeterBar provider integration with verified source contracts, safe credentials, offline fixtures, and app/widget/CLI parity. Use for adding a provider or auditing a provider addition; does not authorize a new provider, credential access, or unsupported integrations.
---

# Add a MeterBar provider

Deliver a provider whose supported account shapes, quota meaning and failure states agree across MeterBar's surfaces. A provider service that fetches successfully is only one part of this outcome.

## Establish the contract before code

Read `AGENTS.md`, `.agents/memory/MEMORY.md`, `providers.md`, `conventions.md` and the complete issue contract. Provider additions need explicit task authorization; the repository's default deferral still applies. For a decision-complete issue, implement its settled choices and escalate gaps rather than redesigning the feature.

Research the provider's **first-party documentation, official client/plugin source and API schema first**. Record source URLs, revision/API version, verification date, auth scopes, request/response shape, account coverage, quota/reset units, pagination bounds and rate limits on the issue. Distinguish a documented public API from a first-party internal endpoint. A provider marketing plan is not proof of an API allowance.

Compare the relevant [CodexBar integration](https://github.com/steipete/CodexBar) as a secondary implementation witness after establishing the first-party contract. Note disagreements and fixture coverage; do not copy its credentials, assume its endpoint is supported, or treat its denominator/reset assumptions as evidence. If only an unofficial endpoint exists, state the maintenance risk and resolve feasibility in the issue before implementation.

Produce a support matrix for personal/managed/organization plans, documented quota, usage-only, unsupported account shape, missing permission, missing/expired/rejected credentials and malformed/drifted payloads. If no denominator is documented, report usage-only or unavailable with an authored reason. Never invent a cap from pricing, CLI/TUI prose or another account's entitlement. Unsupported optional integrations must be explicit capability decisions, not placeholders promising future support.

Set the credential/storage boundary now: approved credential source and precedence, provider-owned login/refresh, minimum scopes, allowed hosts, non-secret settings needed by CLI, and fields permitted in shared cache. Keep secrets in Keychain or read-only provider-owned storage; never write tokens, raw bodies or billing detail to fixtures, logs, diagnostics, errors or app-group state. Don't scan unrelated credentials or initiate login/refresh to prove feasibility. Credential-gated live probes require existing authorization and an available test account; record absence honestly.

## Choose a current implementation lane

Search open issues/PRs before claiming the surface. Record owned paths on the issue and use a separate `git wt` tree under `.worktrees/`; preserve active work. Before adding a pattern, read three comparable service/parser/settings implementations on the chosen base and their tests. On master, start with `CursorLocalService`, `OpenRouterService` and `GrokCLIUsageService`; their credential and account models differ, so copy only the applicable seam.

Read [the prepared stack](references/prepared-stack.md) when Kimi, Z.ai, Copilot or their reusable seams are relevant. Verify merge state and actual source at use time. **Unmerged code is a dependency, not an available master API.** Name required PRs, base branch and merge order; do not transplant a sibling's entire implementation or silently build against absent symbols. Resolve consequential support/auth choices before writing code.

## Implement and prove parity

Use [the parity map](references/parity.md) during implementation and again before delivery. Record each row as implemented with evidence, already covered by a generic path with a focused assertion, or unavailable with a capability/reason. Explicitly unavailable wake/reset/history/status integrations do not justify omitting the core app/widget/CLI/diagnostic/settings/notification surfaces.

Keep parsing pure and fixture-tested. Tolerate optional fields and documented numeric variants, reject unreadable shapes as parse drift, leave unknown cadence neutral, and omit uncapped/invalid limits. Maintain last-good metrics on refresh failure; distinguish auth rejection from parsing, transient transport and unsupported accounts. Disabled providers must perform no credential reads or network requests. New providers are opt-in, including existing installations whose stored hidden-provider set predates the new case.

Use `ServiceSupport` transport/isolation patterns and injectable dependencies. Apply `@Published` state on the main actor; do I/O/parsing off it. Preserve shared cache encoding/date strategy and stable CLI JSON tokens. Additional quota windows must survive generic row planning rather than disappearing behind a primary-window assumption. Safe errors and parse health must explain drift without including provider text.

Build redacted, deterministic fixtures from the first-party schema or authorized captures; label documented/synthetic versus live-captured provenance. Cover complete, missing, null, numeric-string, unknown enum/unit, invalid denominator/nonfinite values, malformed JSON, empty/unreadable payloads, reset boundaries, credential expiry, auth/envelope errors, rate limits, pagination and foreign-account/unit filtering as applicable. Service tests assert host/headers/request bounds, secret redaction, disabled-provider behavior and stale-cache preservation. Fixtures cannot prove live account entitlement.

## Verify and report delivery gates

Identify the host from `$HOME`. Run tests on Mac Studio (`/Users/decod3rslabs`), or reach it via `ssh mac-studio-2022`; unknown/MacBook homes must not run tests/typechecks. Never replace XCTest, SwiftUI or the toolchain with shims to turn an unavailable verification gate into a pass.

Use the repository's installed format/lint tools without reformatting unrelated files. Review `.swiftformat`, `.swiftlint.yml`, `Package.swift`, `MeterBarCLI/Package.swift` and `.github/workflows/ci.yml` for current commands/toolchain. On Studio, run:

```sh
swiftformat --lint <changed Swift paths>
swiftlint lint --strict --quiet
swift test --filter <affected test class or regex>
swift build
swift build --package-path MeterBarCLI
xcodebuild -project MeterBar.xcodeproj -scheme MeterBar -configuration Debug \
  -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY='-' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MeterBar.xcodeproj -scheme MeterBar -configuration Release \
  -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

The Xcode scheme builds the real app and widget extension; confirm both in build output. Run `scripts/verify-build-identities.sh`, `scripts/test-cli-json-smoke.sh` and `scripts/verify-cli-json-smoke.sh <built CLI>` as relevant. Exercise provider-filtered usage/refresh/doctor JSON with isolated test state and safe credentials; do not refresh a real account as an unapproved smoke test. Report tool absence, license failures, skipped live tests and unavailable accounts as blockers/limitations. CI's real tests, coverage and builds remain mandatory at the final head.

After focused verification, commit intended files only, push a scoped ready PR and attach it to the chat. Record the exact head SHA, implementation lab, reviewer lab and actual review state, local verification, required CI at that SHA, dependency state and remaining blockers. OpenAI implementation needs independent read-only `claude-review-gen` review (Sonnet high, gen); a same-lab self-check is not that gate. If capacity is unavailable or calls are prohibited, record the blocked gate without probing accounts, substituting a reviewer or claiming approval. Recheck exact-head review and required CI after any fixes. Done requires the repository's merge/deployment evidence; publishing a PR does not authorize an independent merge, release or install.
