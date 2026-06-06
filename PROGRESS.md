# BrownBear — Autonomous Build Progress

> Living doc. Each loop iteration: read this, check CI, do the next task to a senior
> production bar, ship it (branch → PR → green CI → merge), tick it here, push.
> Continuity lives in git + this file, not context.

## Loop window
- Started **2026-06-06 ~08:37Z**, target end **~18:37Z** (10h). Re-driven by ScheduleWakeup.
- Mechanism note: continuity is the ScheduleWakeup autonomous loop (re-invokes this agent) +
  this file. `run-loop.sh` exists per the directive but is NOT run (it would spawn competing
  lower-quality `claude -p` iterations; the ScheduleWakeup loop ships proper reviewed PRs instead).

## Hard rules
- **Pure programmatic UIKit + Auto Layout. NO SwiftUI, NO Storyboards/XIBs.** Migrate existing
  SwiftUI to UIKit as touched; never add new SwiftUI.
- **Never leave CI red.** Latest CI run is the source of truth. Red ⇒ fixing it is the next task.
- Build/test only on GitHub CI (no local toolchain). Verify locally with `xcrun swiftc -parse`
  + `node --check`. PRs authored as DudeAint noreply; never expose machine PII.
- Adversarial review (find → refute → fix) before pushing substantive changes.

## State (as of d736713 on main, CI green)
- Modules 1–6 complete: browser shell (UIKit), metadata/injection engine, GM sandbox, background
  @crontab, dashboard+editor (SwiftUI — to migrate), Web Extensions (manifest/CRX, DNR blocking,
  background workers, messaging, alarms, storage, popup/options UI).
- Foreground console.log → Logs; Import-from-URL + one-tap `.user.js` install.
- 17 adversarial-hunt bugs fixed (@connect redirect SSRF, content-blocker race, cron miss, zip-bomb,
  setInterval spin, disabled-extension writes, …).
- Real-time cross-frame/tab GM value propagation (ScriptCat parity) via per-frame eval keystone.

## SwiftUI files to migrate to programmatic UIKit (12)
Dashboard/{BrownBearDashboardView, DashboardViewModel, DashboardComponents, DashboardTheme,
ScriptRowView, ScriptDetailView, LogsView, BackgroundMonitorView, ExtensionsView}.swift,
Editor/{CodeEditorView, ScriptEditorScreen}.swift, Install/ScriptInstallView.swift.

## NEXT TASK
Reference study workflow (firefox-ios / brave-ios / Orion / Gear / Focus UIKit patterns) → a
`reference/UIKIT_PATTERNS.md` digest (reference/ is gitignored), then begin the UIKit dashboard
migration (see ROADMAP.md → Phase B1: UIKit dashboard container replacing the SwiftUI TabView).

## Done log
- Scaffolding (this file, ROADMAP.md, DIRECTIVE.md, run-loop.sh, gitignore reference/).
