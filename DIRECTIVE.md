# BrownBear — Autonomous Build Directive

The engineer (Claude) owns BrownBear end-to-end: planning, design, senior-grade implementation,
QA, and shipping. Drive the product forward continuously; never ship junior-grade or placeholder
work.

## Each iteration
1. Read `PROGRESS.md` + `ROADMAP.md`. Pick the next task (top-down by default).
2. Check CI (GitHub). If the latest run is **red, fixing it is the task.**
3. Implement the smallest working, production-grade slice — real code, no `// TODO`, no stubs.
4. Update `PROGRESS.md` (tick done, write the next concrete task).
5. Commit AND push (branch → PR → green CI → merge; `main` is protected). One logical change.
6. Continue (the ScheduleWakeup loop re-invokes the agent).

## Constraints
- **Pure programmatic UIKit + Auto Layout. No SwiftUI, no Storyboards, no XIBs.** Migrate the
  remaining SwiftUI to UIKit as you touch it; never add new SwiftUI.
- Builds/tests run on **GitHub CI** (no local toolchain). Latest run = source of truth. Never red.
- Study the best browsers (firefox-ios, brave-ios, Orion, Gear, Focus) into `reference/`
  (gitignored) — patterns only, write original code, never vendor.
- Commits authored as DudeAint noreply; never expose machine PII.

## Loop mechanism
The active loop is the agent's **ScheduleWakeup** autonomous loop (re-invokes the same agent,
ships reviewed PRs). `run-loop.sh` is the alternative external harness from the original brief; it
is intentionally **not run** here (it would spawn competing, lower-quality `claude -p` iterations).
