# BrownBear Architecture

This document is the technical blueprint. It is normative: code is expected to conform to
it, and changes that diverge must update it in the same PR.

> Audience: engineers (human and AI) implementing the five modules. Read
> [`CLAUDE.md`](CLAUDE.md) first for the operating rules, then this for the design.

---

## 1. System Overview

BrownBear is a single iOS app composed of four runtime planes:

1. **Foreground browser plane** — the visible browser: tabs, omnibox, `WKWebView`s, and the
   live userscript injection that happens as the user navigates.
2. **Engine plane** — pure logic that parses userscript metadata and decides *which* scripts
   match *which* URLs at *which* lifecycle moment. No UIKit, no WebKit; fully unit-testable.
3. **Sandbox/bridge plane** — the trust boundary. Injected JavaScript talks to native Swift
   through a single message channel; native services (network, storage, clipboard) answer.
4. **Background plane** — `BGTaskScheduler` wakes the app, a crontab evaluator finds due
   scripts, and a headless `JSContext` executes them with the same GM API surface, no UI.

```
            ┌────────────────────────── Foreground ──────────────────────────┐
 user ──▶ Omnibox ──▶ BrowserVC ──▶ WKWebView(tab) ──▶ injected runtime ──┐   │
            ▲              │                                               │   │
         TabGrid ◀─────────┘                                              GM calls
                                                                          │   │
            └─────────────────────── Bridge (WKScriptMessageHandler) ─────┘   │
                                            │                                  │
   Engine: ScriptMetadata · URLMatcher · InjectionPlanner  ◀── decides what injects
                                            │                                  │
   Native GM services: Network(URLSession) · GMValueStore · Clipboard · Tabs   │
                                            │                                  │
            ┌──────────────────────── Background ─────────────────────────────┘
            BGTaskScheduler ──▶ CrontabEvaluator ──▶ headless JSContext ──▶ Logs
                                            │
   Storage: Core Data (Script, Schedule, LogEntry) + UserDefaults (GM values, namespaced)
```

---

## 2. Module Roadmap (build order)

The app is built in five sequenced modules. Each is shippable and verifiable on its own.

### Module 1 — Chromium-style Browser Foundation
**Goal:** a usable multi-tab browser.

- `BrownBearBrowserViewController` (UIKit) owns the tab model and the active `WKWebView`.
- `OmniboxView` — rounded address bar; classifies input as URL vs. search; shows TLS state;
  exposes back/forward/reload/stop. While editing it drives a live autocomplete dropdown
  (`OmniboxSuggestionsView`) built by the pure `OmniboxSuggestionEngine` from `HistoryStore`
  matches + the typed action; top sites show on focus.
- `BrownBearTabGridController` — a `UICollectionView` square grid; create/close/select tabs,
  drag-to-reorder (drag & drop, coexisting with the cells' context menu); snapshots for previews.
- `Tab` model wraps one `WKWebView` + its `WKWebViewConfiguration` (shared process pool,
  shared `WKUserContentController` so scripts inject consistently).
- Navigation state captured through `WKNavigationDelegate`:
  `didStartProvisionalNavigation`, `didCommit`, `didFinish`, `didFail`.

**Reference:** Chromium `/ios` omnibox + tab grid controllers and WebState lifecycle.

### Module 2 — Metadata Parser & Injection Bridge
**Goal:** parse userscripts and inject them at the right moment on matching pages.

- `brownbear-core.js` — parses the `// ==UserScript== … // ==/UserScript==` block into a
  structured header. Mirrored by a Swift `ScriptMetadataParser` for native-side decisions.
- Header fields: `@name`, `@namespace`, `@version`, `@description`, `@match`, `@include`,
  `@exclude`, `@run-at`, `@grant`, `@require`, `@resource`, `@connect`, `@crontab`, `@inject-into`.
- `URLMatcher` — converts `@match` patterns (Chrome match-pattern grammar) and `@include`/
  `@exclude` globs into anchored regexes. Caches compiled regexes per script.
- `InjectionPlanner` — given a navigation URL + lifecycle phase, returns the ordered list of
  scripts to inject (respecting `@run-at` and `@weight`).
- `WKUserContentController` wiring installs `WKUserScript`s at `.atDocumentStart` and
  `.atDocumentEnd`; the injected runtime then schedules each script at its `@run-at` moment:
  `document-end` at `DOMContentLoaded`, and `document-idle` one macrotask after `DOMContentLoaded`
  (Violentmonkey/Tampermonkey parity) — **not** at the window `load` event, which would wait for
  every image and subresource and fire seconds later.
- **Per-script overrides** (`ScriptOverrides` on `UserScript`) layer user choices over the parsed
  metadata without editing source: `@run-at`, `@inject-into`, and auto-update participation. The
  runtime gates on `UserScript.effectiveRunAt`/`effectiveInjectInto` (override ?? metadata), edited
  from the dashboard's `ScriptSettingsCard`. The field is optional and pruned to `nil` when empty so
  old records decode unchanged.

**Reference:** quoid/userscripts metadata + WKUserScript injection timing; Tampermonkey/ScriptCat
per-script settings.

### Module 3 — Sandbox & GM API Bridge
**Goal:** a hostile-page-resistant runtime exposing native-backed GM APIs.

- `brownbear-sandbox.js` — wraps each userscript in an IIFE with a captured-reference GM
  surface; the page cannot tamper with the bridge by overriding prototypes.
- One `WKScriptMessageHandler` named `brownbear` receives `{id, api, payload}` envelopes and
  replies by evaluating a resolver keyed on `id` (request/response correlation).
- Native GM handlers:
  - `GM_xmlhttpRequest` → `URLSession` (CORS-free), enforcing the script's `@connect` allowlist. A
    request to an **undeclared** host raises a ScriptCat-style prompt ("«script» wants to connect to
    «host»"); Allow persists an always-allow for that script (`ConnectGrantStore`), Block denies and
    logs. Redirects to an undeclared+ungranted host are blocked mid-flight (never prompted). Declared
    hosts proceed silently; grants are revocable per host in Script detail. Fail-closed by default.
  - `GM_setValue/getValue/deleteValue/listValues` → `GMValueStore`, namespaced by script UUID.
  - `GM_addStyle`, `GM_setClipboard`, `GM_openInTab`, `GM_notification`, `GM_log`.
- Every inbound message is validated (shape, types, bounds) before any native effect.

**Reference:** ScriptCat GM event loop + sandbox isolation model.

### Module 4 — Background & @crontab Queue
**Goal:** run `@background`/`@crontab` scripts while the app is closed.

- `BrownBearBackgroundScheduler` registers `BGAppRefreshTask` + `BGProcessingTask` ids.
- `CrontabEvaluator` parses 5-field crontab (`min hour dom mon dow`) plus ScriptCat's
  `once`/`@every` extensions; computes next-fire and "is due now".
- Core Data `Schedule` rows persist next-fire times; on wake, the scheduler loads due rows.
- `HeadlessScriptRunner` boots a `JSContext` (no `WKWebView`), installs a background-safe GM
  surface (network + storage + log; no DOM), runs the script body, captures `console.*` and
  return value into `LogEntry`, then tears the context down within the OS time budget.
- The headless context is fully isolated from any foreground `WKWebView`.

**Reference:** ScriptCat background-script framework + crontab queue.

### Module 5 — Dashboard & Editor
**Goal:** manage everything from a polished UI.

- `BrownBearDashboardView` (SwiftUI) — installed scripts list with enable/disable toggles,
  per-script detail (matches, grants, last run, next run), and a live log viewer.
- Background-task monitor showing scheduled jobs and recent executions.
- `ScriptEditorView` — a Runestone-backed editor (line numbers, JS syntax highlighting,
  bracket matching) wrapped for SwiftUI, with a save pipeline that re-parses metadata and
  rejects invalid headers before persisting. A `KeyboardAccessoryBar` adds quick-insert keys
  for code punctuation and a Find button (Runestone's `UIFindInteraction`, iOS 16+).

**Reference:** **Runestone** (simonbs/Runestone, MIT) for the code editor — integrate directly
or mirror its Tree-sitter highlighting + line management; `quoid/userscripts` for the manager
dashboard UX; Gear's settings ergonomics. (Stay is now closed-source — screenshots only.)

### Module 6 — Web Extensions (Chrome Web Store) · north-star epic
**Goal:** install and run real browser extensions from the Chrome Web Store / Firefox AMO,
the way **Orion** and **Gear Browser** do — not just userscripts.

This is a large, multi-release epic, deliberately sequenced after the userscript engine because
it reuses the same trust boundary and injection plumbing.

- **Manifest support:** parse MV2/MV3 `manifest.json`; map `content_scripts`, `background`
  (service worker / event page), `permissions`, `host_permissions`, `web_accessible_resources`,
  `action`/`browser_action` popups, and `options_ui`.
- **WebExtension API surface:** implement the `chrome.*` / `browser.*` namespaces the same way
  we implement `GM_*` — a `WKScriptMessageHandler` bridge to native Swift services
  (`storage`, `tabs`, `runtime`, `webRequest`-lite, `scripting`, `i18n`, `alarms`). The existing
  sandbox (Module 3) and background scheduler (Module 4) are the foundation.
  - `chrome.tabs` (create/query/get/update/remove/reload) reaches `TabManager` via
    `WebExtensionBridgeHost` (the extension analog of the userscript `ScriptBridgeHost`),
    implemented by the browser VC and forwarded by `InjectionOrchestrator` to all three surfaces:
    the content/popup `WebExtensionMessageRouter` and the headless background workers (which hop to
    the main actor). chrome tab ids are integers, so `WebExtensionTabRegistry` maps `Tab.id` (UUID)
    to a stable Int. windowId is always 1 (iOS is single-window).
- **CRX ingestion:** accept `.crx`/`.zip` extension bundles and Chrome Web Store URLs; unpack,
  validate, and store like a script package.
- **Reality check (iOS constraints):** Apple mandates WebKit, so we cannot run Chromium's
  extension engine. We provide a *compatibility layer* — many content-script/storage/action
  extensions will work; deeply Chromium-internal APIs (e.g. full `webRequest` blocking,
  `declarativeNetRequest` at scale) are constrained by what WKWebView exposes. We document
  exactly which APIs are supported, partial, or unsupported, and degrade honestly.

**Reference:** Orion's WebExtensions compatibility approach (product study), Gear's
"add extensions directly" UX, and the official Chrome/Firefox WebExtensions API docs.
**Maps to:** `BrownBear/Extensions/` (new module), reusing `Sandbox/` and `Background/`.

**Status — Phase 1 (shipped):** MV2/MV3 manifest parsing, CRX2/CRX3 + ZIP unpack, install/manage,
content-script injection in the isolated world, and `chrome.storage`/`runtime`/`i18n`/`extension`.

**Status — Phase 2 (shipped):**
- **`declarativeNetRequest`** static rulesets compiled to `WKContentRuleList` and applied to every
  tab (`DeclarativeNetRequest` pure compiler + `WebExtensionContentBlocker`), recompiled live on
  change. Fidelity-over-coverage: unrepresentable rules (redirect/modifyHeaders/requestMethods/
  requestDomains) are skipped and counted, never approximated.
- **Background service workers / event pages** run headless in a per-extension `JSContext`
  (`WebExtensionBackgroundContext` + `WebExtensionRuntime` + `brownbear-webext-background.js`) with
  `chrome.runtime`/`storage`/`alarms`/`i18n`, `console.*`, `setTimeout`/`setInterval`, web globals
  (`fetch`/`URL`/`navigator`/`location`/Web Crypto), and **IndexedDB**.
- **`chrome.offscreen` (MV3 real-DOM documents)**: a service worker has no DOM, so DOM work runs in an
  offscreen document — hosted faithfully in a hidden, off-screen `WKWebView` (a `JSContext` can't *be*
  a DOM) reusing the popup/options engine (`WebExtensionOffscreenManager` + `WebExtensionPageSession`).
  One per extension; the document URL is package-contained; the worker drives it over `chrome.runtime`
  messaging (worker→page `sendMessage` is wired, reply `await`-able).
- **ES-module service workers** (`"background": { "type": "module" }`, e.g. uBlock Origin Lite):
  JavaScriptCore on iOS has no native ES-module loader, and its private loader SPI (`JSScript`,
  `moduleLoaderDelegate`) is absent from the public SDK, so we link the module graph in pure JS.
  `brownbear-acorn.js` (vendored acorn) parses each module and `brownbear-esm-linker.js` AST-rewrites
  its `import`/`export` into calls against a synchronous registry, resolving sibling modules from the
  package on demand via a native reader (`WebExtensionStore.fileSync`, path-contained). The graph runs
  inside the ordinary classic-script context — no private API. See `WebExtensionBackgroundContext+`
  `ModuleWorker.swift`. Limitations: named-import cycles snapshot (CommonJS-cycle semantics; namespace
  imports and re-exports stay live), and top-level `await` is unsupported (fails closed).
- **IndexedDB in headless contexts**: JavaScriptCore ships no IndexedDB, so both the extension worker
  and the userscript background runner load an in-memory engine (`brownbear-indexeddb.js`, a vendored
  fake-indexeddb IIFE) plus a snapshot/rehydrate layer (`brownbear-idb-persist.js`). The JS side
  snapshots the store to JSON (debounced on write) and hands it to `BrownBearIDBStore`, which persists
  it per-namespace under Application Support (one file per extension / per userscript — strict
  isolation, §5); at boot the last snapshot is replayed through the public IndexedDB API. This lets
  Dexie/ScriptCat-style background storage work and survive worker restarts.
- **Messaging**: content → background `runtime.sendMessage`/`onMessage` with sync **and** async
  `sendResponse` (and Promise-returning listeners), over the same native-bound-token bridge. A
  `runtime.sendMessage` from a content script or extension page also fans out to the extension's open
  popup/options **pages** (`WebExtensionRuntime.sendRuntimeMessage` → each page's
  `chrome.runtime.onMessage`), skipping the sender; the first context to answer wins.
- **`chrome.alarms`**, **`storage.onChanged`** (in workers), and **direct Chrome Web Store install**
  (`ChromeWebStore` — paste a link or id, fetch the CRX). Surfaced **in-page** two ways: a banner
  above the toolbar (`+ExtensionInstall`), and — primary — the store's **own install button rewired**
  in place. `brownbear-webstore.js` (PAGE world, store hosts only) makes the store believe it's
  desktop Chrome (`navigator.userAgentData`/`vendor` spoof + a forced desktop Chrome UA at the nav
  layer) so the real enabled button renders with no "you're not on Chrome" banner, then relabels it to
  **"Add to BrownBear"** / **"Remove from BrownBear"** (state from `WebExtensionStore.installed(forStoreID:)`)
  and routes the click to `WebStoreInstallHandler` (origin-gated `WKScriptMessageHandlerWithReply`),
  which runs the real install/remove. The store id is recorded on the `WebExtension` record so add/remove
  state round-trips.
- **Edge Add-ons + Firefox (AMO)** install the same way: `ExtensionStoreSource` unifies detection +
  download across all three — `EdgeAddons` pulls a Chromium CRX from Edge's on-demand endpoint;
  `FirefoxAddons` resolves the current XPI (a ZIP, so `WebExtensionArchive` unpacks it unchanged) via
  AMO's API. The in-page banner appears on Edge/Firefox store detail pages, and the dashboard's
  paste-a-link accepts any of the three. Firefox extensions run on the same surface (their `browser.*`
  Promise API is already aliased to `chrome`).

**Status — Phase 3 (shipped, final):**
- **Popup & options pages** render in a real WKWebView over a `chrome-extension://` scheme
  (`WebExtensionSchemeHandler` serves the packaged files; `WebExtensionPageViewController` hosts the
  page). The page gets a synchronous `chrome.*` surface — storage (+ live `onChanged`), runtime
  (`sendMessage`→background, `getManifest`/`getURL`/`getPlatformInfo`/`openOptionsPage`), i18n,
  extension — via `brownbear-webext-page.js` with identity baked in at document-start. Reachable
  from Dashboard → Extensions (long-press).

**Status — Phase 4 (shipped): broad `chrome.*` + web-platform parity.** Beyond the above, the runtime
now exposes `chrome.tabs`/`windows` (read + write, via `WebExtensionBridgeHost`), `webNavigation`,
`scripting` (+ MV2 `tabs.executeScript`), `cookies` (+ `onChanged`), `notifications`, `contextMenus`,
`identity` (incl. `launchWebAuthFlow`), `permissions`, `action`, `userScripts`, **background↔content
messaging + long-lived ports** (both directions, via a token-bound port hub), and the web-platform
APIs JavaScriptCore lacks — `fetch`/`Headers`/`Request`/`Response`, `AbortController`, `FormData`,
`Blob`/`File`/`FileReader`, `XMLHttpRequest`, `structuredClone`, `Event`/`EventTarget`, and
`crypto.subtle` (HMAC/AES/PBKDF2/ECDSA). MV2 background *pages* get a `window` alias and a minimal
`document`. A `.user.js` navigation can be handed off to an installed userscript-manager extension
(e.g. ScriptCat) by evaluating its `declarativeNetRequest` redirect rule (`UserScriptInstallRouter`),
since WebKit can't redirect a main-frame request.

**The remaining no-ops** (blocking `webRequest`, `commands` dispatch, suspended-app alarms, native
messaging, devtools/`proxy`/`privacy`) are the hard edges of WebKit's extension-less model on iOS;
they degrade to honest rejections rather than fakes. Real-extension hardening (Violentmonkey's Dexie
store + MV2 import hand-off, userscript-manager import polish) is ongoing. See `docs/WEB_EXTENSIONS.md`.

---

## 3. Data Model (Core Data)

| Entity | Key fields | Notes |
|---|---|---|
| `Script` | `id: UUID`, `name`, `source`, `enabled`, `metadataJSON`, `createdAt`, `updatedAt` | `source` is the full text; parsed metadata cached as JSON |
| `Schedule` | `id`, `scriptId`, `crontab`, `nextFireAt`, `lastFireAt`, `enabled` | one per `@crontab` directive |
| `LogEntry` | `id`, `scriptId`, `level`, `message`, `createdAt`, `context` (fg/bg) | execution + GM_log output, secrets scrubbed |
| GM values | stored in `UserDefaults` suite `group.brownbear.gm`, key = `\(scriptId).\(key)` | not Core Data; fast KV, per-script namespace |

---

## 4. Threading & Concurrency

- UI: `@MainActor`. WebKit delegate callbacks arrive on main; keep them light.
- `GMValueStore`, `ScriptStore`, and `BrownBearBackgroundScheduler` are `actor`s.
- The headless `JSContext` runs on a dedicated serial queue; one script at a time per wake.
- The bridge resolves GM requests asynchronously and posts results back to the JS resolver
  on the web view's thread.

---

## 5. Trust Boundaries (see CLAUDE.md §5)

1. **Page → injected runtime:** the page is hostile. Capture references at start.
2. **Injected runtime → native bridge:** every envelope is untrusted; validate and fail closed.
3. **Script → network:** gated by `@connect`; no undeclared hosts.
4. **Script ↔ script:** isolated GM namespaces; no cross-read.
5. **Background context:** no DOM, isolated from foreground web views, user-stoppable.

---

## 6. iOS Platform Constraints (design within these)

- WebKit is the only engine; we cannot ship V8. The injected runtime is JavaScriptCore-grade.
- WKWebView RegExp lookbehind/lookahead requires **iOS 16.4+** — hence the deployment target.
- Background execution is **best-effort and budgeted** by `BGTaskScheduler`; `@crontab` is a
  *target* schedule, not a hard real-time guarantee. The UI communicates this honestly.
- App Review: background network must be justified and user-visible; the dashboard makes all
  scheduled activity inspectable and stoppable.

---

## 7. Testing Strategy

- **Pure-logic units** (highest value): metadata parser, URL matcher, crontab evaluator,
  GM value namespacing. Table-driven, including malformed input.
- **Bridge contract tests:** malformed envelopes must not crash; allowlist enforcement holds.
- **Integration (device):** background wake actually executes a scheduled script and logs it.

See `CLAUDE.md` §6 for the verification bar.
