# Reference Repositories

BrownBear synthesizes architecture from four projects. We **study their design and behavior,
then write our own clean implementation** under BrownBear's MIT license. We do **not** vendor
or copy source from GPL/AGPL-licensed projects. This file documents what each reference
teaches us and exactly which subsystems map to it.

> ⚠️ **License hygiene.** ScriptCat and Userscripts are GPL/AGPL-licensed. Learn the *pattern*,
> re-implement independently. Never paste their functions, file structures, or comments into
> this tree. When unsure, ask before referencing.

---

## 1. chromium/chromium — `/ios` directory

- **URL:** https://github.com/chromium/chromium (path: `ios/chrome/browser/ui`)
- **License:** BSD-3-Clause (permissive — patterns may be referenced; still re-implement)
- **What we learn:**
  - Omnibox structure and editing/refresh state machine.
  - Tab grid controller layout, selection, and snapshotting.
  - `WebState` lifecycle and how navigation events drive UI state.
- **Maps to:** Module 1 — `BrownBearBrowserViewController`, `OmniboxView`,
  `BrownBearTabGridController`.
- **Note:** Chromium is multi-gigabyte; we deliberately do **not** clone it in full. Consult
  it online or via a sparse checkout of `ios/` only if needed.

## 2. scriptscat/scriptcat

- **URL:** https://github.com/scriptscat/scriptcat
- **Docs:** https://docs.scriptcat.org/en/docs/dev/background/
- **License:** GPLv3 — **architecture only, no code reuse.**
- **What we learn:**
  - Background script execution framework (scripts that run without an open tab).
  - `@crontab` scheduling syntax and the task queue model.
  - Sandbox runtime isolation and the GM event loop / API surface.
- **Maps to:** Module 3 (sandbox + GM bridge) and Module 4 (background + `@crontab`).

## 3. quoid/userscripts

- **URL:** https://github.com/quoid/userscripts
- **License:** GPLv3 — **architecture only, no code reuse.**
- **What we learn:**
  - WebKit-optimized userscript metadata parsing (`@match`, `@include`, `@exclude`,
    `@run-at`, `@grant`, `@require`, `@inject-into`, `@weight`).
  - Document-start vs. document-end injection lifecycle on Safari/WebKit.
  - The async `GM.*` storage/tabs/utility API shape.
- **Maps to:** Module 2 — `brownbear-core.js`, `ScriptMetadataParser`, `URLMatcher`,
  `WKUserContentController` injection wiring.

## 4. mapleDistant/Stay

- **URL:** https://github.com/mapleDistant/Stay (verify availability; repo may be
  renamed/private — fall back to the App Store listing for UX study)
- **App Store:** https://apps.apple.com/app/stay-for-safari/id1591620171
- **License:** review before any direct reference.
- **What we learn:**
  - Mobile-friendly script library/manager dashboard.
  - Settings toggles and per-script controls.
  - In-app code editor UX.
- **Maps to:** Module 5 — `BrownBearDashboardView`, `ScriptEditorView`.

---

## Product Inspirations (UX, not code)

- **Gear Browser** — https://gear4.app/ · https://gear4.app/doc — the first iOS browser to
  ship a userscript engine compatible with Tampermonkey/Greasemonkey/Violentmonkey. Studied
  for browser ergonomics, settings, and the "userscripts as a first-class browser feature"
  product framing. (Note: WKWebView RegExp lookbehind requires iOS 16.4+ — informs our
  deployment target.)
- **Focus / Player-style userscript managers** — studied for clean, minimal library UX.

---

## On cloning these references locally

For practical, license-safe work we recommend **not** committing reference source into this
repository. If you want them locally for study, clone them *outside* the BrownBear tree, e.g.:

```bash
# study copies — keep these OUTSIDE the BrownBear repo
mkdir -p ~/brownbear-references && cd ~/brownbear-references
git clone --depth 1 https://github.com/scriptscat/scriptcat.git
git clone --depth 1 https://github.com/quoid/userscripts.git
# Chromium: sparse-checkout just the iOS UI, it is huge:
git clone --depth 1 --filter=blob:none --sparse https://github.com/chromium/chromium.git
cd chromium && git sparse-checkout set ios/chrome/browser/ui
```

This keeps GPL/AGPL source out of our MIT-licensed tree while letting you read the patterns.
