# MeterBar

Claude-specific entry point. Documentation in `.agents/`.

## Commands

Check `.agents/SYSTEM/RULES.md` for coding standards.
Architecture reality-check: `.agents/SYSTEM/ARCHITECTURE.md` and `docs/audits/00-repo-map.md`.

## Sessions

Document all work in `.agents/sessions/YYYY-MM-DD.md` (one file per day).

`.agents/sessions/` is **local-only working notes** — gitignored, never committed.
This repo is public; session logs carry internal QA and unreleased design detail.
Durable decisions belong in `.agents/SYSTEM/architecture/DECISIONS.md`, delivery
state on the GitHub issue or PR. Never `git add -f` a session file.

## Testing Policy
- Write tests FIRST before implementation (TDD)
- All new features must include tests before code
- Aim for 80%+ coverage on new code
- Run tests before committing (`swift test`; requires full Xcode — CLT alone lacks XCTest)
