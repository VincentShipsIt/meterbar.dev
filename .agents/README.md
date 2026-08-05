# MeterBar - Agent Documentation Hub

**Welcome to the MeterBar workspace!**

This is the `.agents/` folder containing AI agent documentation, session tracking, and project rules.

## Quick Start

**READ FIRST:** `SYSTEM/ai/SESSION-QUICK-START.md`

## Directory Structure

```
.agents/
├── README.md                    # This file - Navigation hub
├── SYSTEM/
│   ├── RULES.md                 # Coding standards (READ THIS)
│   ├── ARCHITECTURE.md          # What's implemented
│   ├── SUMMARY.md               # Current state
│   ├── ai/                      # AI agent protocols
│   ├── architecture/            # ADRs and project map
│   ├── critical/                # Critical rules (NEVER DO)
│   └── quality/                 # Security and quality
├── TASKS/
│   ├── README.md                # Task management guide
│   └── INBOX.md                 # Quick task capture
├── PRDs/
│   ├── README.md                # PRD format guide
│   └── *.md                     # Product Requirements Documents
├── sessions/
│   ├── README.md                # Session format guide
│   └── TEMPLATE.md              # Session file template
├── SOP/                         # Standard operating procedures
├── EXAMPLES/                    # Code patterns
└── FEEDBACK/                    # Improvement tracking
```

## For AI Agents

### Before Starting Work

1. Read `SYSTEM/ai/SESSION-QUICK-START.md`
2. Check `SYSTEM/critical/CRITICAL-NEVER-DO.md`
3. Read today's session file (if exists): `sessions/2025-12-29.md`

### During Work

- Follow patterns in `SYSTEM/RULES.md`
- Track tasks in `TASKS/`
- Reference PRDs in `PRDs/` when implementing features
- Document decisions

### After Work

- Update session file in `sessions/`
- Mark completed tasks
- Note next steps

## Session Files

**ONE FILE PER DAY:** `sessions/YYYY-MM-DD.md`

Multiple sessions on the same day go in the same file as Session 1, Session 2, etc.

**Local-only.** `sessions/` is gitignored and never committed — this repo is
public and session logs carry internal QA and unreleased design detail. The
directory will not exist in a fresh clone; create it on first use.

## Tech Stack

swift,swiftui,macos,widgetkit

---

**Last Updated:** 2026-01-10
