# Project Map - MeterBar

**Purpose:** Quick reference for project structure and responsibilities.
**Last Updated:** 2026-07-02 (synced to the actual tree; see `docs/audits/00-repo-map.md`)

---

## Directory Overview

```
meterbar/
├── .agents/                    # AI documentation (SESSIONS/, SYSTEM/, docs/, skills/)
├── .claude/ .codex/ .cursor/   # Per-agent tool config (commands, hooks, skills)
├── .github/workflows/          # ci.yml, release.yml, update-homebrew.yml, secret-scan.yml
├── MeterBar/                   # Main app target
│   ├── App/MeterBarApp.swift   # @main + AppDelegate (status item, popover, notifications)
│   ├── Models/                 # ServiceType, UsageMetrics, UsageLimit, TokenCost,
│   │                           # RefreshInterval, ClaudeCodeAccount, UsageFormatting
│   ├── Services/               # 16 singleton services (fetch/parse/cache/log)
│   ├── Views/                  # MenuBarView, SettingsView, UsageDashboardView,
│   │                           # MeterBarTheme, RefreshingIcon
│   └── Resources/, Assets.xcassets, Info.plist, MeterBar.entitlements
├── MeterBarWidget/             # WidgetKit extension (duplicated model structs)
├── MeterBarCLI/                # Separate SwiftPM package → `meterbar` executable
├── MeterBarTests/              # XCTest suite — runs via `swift test` (root Package.swift)
├── MeterBar.xcodeproj/         # App + widget targets (no test target)
├── Package.swift               # SwiftPM manifest for library + tests
├── scripts/                    # Bun asset generators, check-coverage.sh, API smoke test
├── docs/                       # Logo, screenshots, audits/
└── assets/                     # Social preview
```

## Where things live

| Concern | File(s) |
|---|---|
| Provider fetch logic | `MeterBar/Services/{ClaudeCodeCLIUsageService,ClaudeCodeLocalService,CodexCliLocalService,CursorLocalService,ClaudeService,OpenAIService}.swift` |
| Refresh orchestration + cache | `MeterBar/Services/UsageDataManager.swift` |
| Cost estimation | `MeterBar/Services/CostTracker.swift` (+ `Models/TokenCost.swift`) |
| Widget data handoff | `MeterBar/Services/SharedDataStore.swift` → app group `group.dev.meterbar.app` |
| Admin API keys | `MeterBar/Services/{AuthenticationManager,KeychainManager}.swift` |
| Notifications | `MeterBar/App/MeterBarApp.swift` (AppDelegate) |
| UI | `MeterBar/Views/` |
| CLI | `MeterBarCLI/Sources/MeterBarCLI.swift` |
| Coverage gate | `scripts/check-coverage.sh` (threshold via `COVERAGE_THRESHOLD`) |
| Lint/format config | `.swiftlint.yml`, `.swiftformat` |

## Build/test invocations

- App/widget build: `xcodebuild -project MeterBar.xcodeproj -scheme MeterBar build` (needs full Xcode)
- Tests: `swift test` at repo root (needs full Xcode for the XCTest module — Command Line Tools alone cannot run tests)
- CLI: `cd MeterBarCLI && swift build`
- Coverage: `scripts/check-coverage.sh` (wraps `swift test --enable-code-coverage` + llvm-cov)
