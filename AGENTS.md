# MeterBar

This file is the agent entry point.

## Start here

Read [`.agents/memory/MEMORY.md`](.agents/memory/MEMORY.md), then only the topic file for the task.

## Commands

- Tests: `swift test` at repo root (requires full Xcode — Command Line Tools lack XCTest)
- App: `xcodebuild -project MeterBar.xcodeproj -scheme MeterBar build`
- CLI: `cd MeterBarCLI && swift build`

## Sessions

`.agents/sessions/YYYY-MM-DD.md` — local-only, gitignored. This repo is public. Durable decisions go in `.agents/memory/decisions.md`. Delivery state goes on the GitHub issue or PR. Never `git add -f` a session file.
