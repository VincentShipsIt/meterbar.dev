# MeterBar

This file provides entry points for AI agents.

## Documentation

All documentation is in `.agents/`:
- `.agents/README.md` - Navigation hub
- `.agents/SYSTEM/RULES.md` - Coding standards
- `.agents/SYSTEM/ARCHITECTURE.md` - What is actually implemented
- `.agents/sessions/` - Session history (one file per day, gitignored/local-only)
- `.agents/docs/DEFERRED_WORK.md` - Known tech debt with pickup instructions
- `docs/audits/` - Audit reports (start with `00-repo-map.md`)

## Quick Start

Read `.agents/SYSTEM/ai/SESSION-QUICK-START.md` before starting work.

## Build/test notes

- Tests: `swift test` at repo root (requires full Xcode — Command Line Tools lack XCTest)
- App build: `xcodebuild -project MeterBar.xcodeproj -scheme MeterBar build`
- CLI: `cd MeterBarCLI && swift build`
