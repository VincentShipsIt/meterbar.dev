# Session Documentation Protocol

**Purpose:** Ensure consistent, useful session documentation.
**Last Updated:** 2025-12-29

---

## Core Principle

**Document as you work, not after.** Good documentation prevents context loss between sessions.

---

## Session File Format

### Location

`../../sessions/YYYY-MM-DD.md`

### Structure

```markdown
# Sessions: YYYY-MM-DD

**Summary:** 3-5 word summary of the day

---

## Session 1: Brief Description

**Duration:** ~X hours
**Status:** Complete / In Progress

### What was done
- Task 1
- Task 2

### Files changed
- `path/to/file.ts` - what changed

### Decisions
- **Decision:** What was decided
  - **Context:** Why this was needed
  - **Rationale:** Why this choice
  - **Impact:** How it affects the project

### Mistakes and fixes
- **Mistake:** What went wrong
- **Fix:** How it was resolved
- **Prevention:** How to avoid in future

### Next steps
- [ ] Next task 1
- [ ] Next task 2

---

## Session 2: Another Description

[Same structure]

---

**Total sessions today:** 2
```

---

## What to Document

### Always Document

- Decisions and rationale
- Files created/modified/deleted
- Patterns established
- Mistakes made and how fixed
- Next steps

### When to Document

- After completing a task
- After making a decision
- After fixing a mistake
- Before ending session

---

## Naming Rules

### Correct

```
sessions/2025-01-15.md
sessions/2025-01-16.md
```

### Wrong

```
sessions/2025-01-15-feature-name.md  ❌
sessions/FEATURE-IMPLEMENTATION.md   ❌
sessions/2025-01-15-session-1.md     ❌
```

---

## Multiple Sessions Same Day

Add to the SAME file:

```markdown
## Session 2: New Work Area

[Content]

---

## Session 1: Previous Work

[Previous content]

---

**Total sessions today:** 2
```

---

## Quality Checklist

Before ending a session, verify:

- [ ] Today's file uses `YYYY-MM-DD.md` format
- [ ] Only ONE file for today
- [ ] All decisions documented with rationale
- [ ] All files changed listed
- [ ] Mistakes documented (if any)
- [ ] Next steps noted
