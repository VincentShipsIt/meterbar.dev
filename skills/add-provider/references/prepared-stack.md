# Prepared provider stack: conditional examples

Checked 2026-09-30 against master `ede52a7` and the open PR stack. Re-read the complete PR bodies and current source before using these examples; they contain the support matrix and residual risks. None of these seams was on master at this verification point.

| PR / branch | State at verification | Conditional seams and contract lessons |
|---|---|---|
| [#602 Kimi Code](https://github.com/VincentShipsIt/meterbar.dev/pull/602), `feature/kimi-code-provider` | Open, targets master | `MeterBar/Services/ProviderAPIKeyStore.swift`; `MeterBar/Views/Settings/SingleKeyProviderSettingsSection.swift`; `UsageDataManager.simpleProviders`; `ServiceType.simpleProviderCases`; `ProviderSnapshot.Input.simpleProviderAccess` and `LastErrors.simpleProviders`. Kimi first-party client usage shapes changed; prefer current quota model, fixture-test legacy rows, report drift. OAuth files are read-only, expired tokens are not sent/refreshed, optional key fallback is explicit. |
| [#604 Z.ai](https://github.com/VincentShipsIt/meterbar.dev/pull/604), `feature/zai-coding-plan-provider` | Open, stacked on #602; merge #602 first | `MeterBar/Services/ProviderSharedSettings.swift` shares only non-secret region/account choices with CLI. Official-plugin endpoint is not a versioned REST contract. Closed region host selection; envelope auth failures may arrive as HTTP 200. Unknown unit codes stay neutral; uncapped MCP limits disappear. Peak/off-peak schedule belongs in dated data, not guessed quota math. |
| [#606 GitHub Copilot](https://github.com/VincentShipsIt/meterbar.dev/pull/606), `feature/github-copilot-provider` | Open, stacked on #604/#602; merge in that order | `ProviderSnapshot.Input.simpleProviderNotes`; `Packages/MeterBarShared/Sources/MeterBarShared/GitHubCopilot.swift` support classification. Versioned first-party billing API gives no personal-plan denominator. Only proven applicable organization user budgets become quota bars; usage-only and unsupported get precise notes in app, Settings, diagnostics and doctor. PAT only in Keychain; never reuse Copilot CLI OAuth. Classification persists, billing figures do not. |

Inspect candidate implementations and tests using the actual fetched PR ref, without editing another owner's worktree:

```sh
gh pr view 602 --json state,baseRefName,headRefName,headRefOid,body
gh pr view 604 --json state,baseRefName,headRefName,headRefOid,body
gh pr view 606 --json state,baseRefName,headRefName,headRefOid,body
git show <verified-ref>:MeterBar/Services/ProviderAPIKeyStore.swift
git show <verified-ref>:MeterBar/Services/ProviderSharedSettings.swift
```

Kimi's `KimiCodeUsageParserTests`/`KimiCodeCredentialReaderTests`, Z.ai's `ZaiCodingPlanUsageParserTests`/`ZaiPeakScheduleTests`, and Copilot's `GitHubCopilotBillingParserTests`/`GitHubCopilotSupportTests` are useful conditional witnesses. They are not proof of a live response or of merged availability. If dependencies remain open, either use the declared stacked base or work with current master seams inside the authorized scope; don't assume the abstractions shipped. Their old shim-based validation reports are not substitutes for real toolchain builds/tests.
