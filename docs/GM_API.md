# GM API Support in BrownBear

BrownBear aims for Tampermonkey/Violentmonkey/ScriptCat compatibility so real-world userscripts —
including obfuscated, library-dependent, and fetch-then-`eval` scripts — run unmodified. Both the
classic callback APIs (`GM_*`) and the Promise APIs (`GM.*`) are wired.

How scripts run (why complex scripts work):
- Each script executes in an **isolated content world** via `new Function(...)`, with its granted
  `GM_*` functions passed in as scope variables. **Direct `eval()` inside the script keeps access to
  `GM_*`** — so a script that fetches code (via `GM_xmlhttpRequest` or `@resource`/`@require`) and
  `eval`s it can still call the GM API. Obfuscated bodies are just JavaScript and run as-is.
- `@require` and `@resource` are **fetched natively** (through the bridge, not page `fetch`), so they
  **bypass CORS** — the usual reason library-heavy/obfuscated scripts fail elsewhere.
- Background `@crontab`/`@background` scripts run in a headless `JSContext` with a DOM-less GM surface.

## Fully supported

| API / directive | Notes |
|---|---|
| `GM_getValue` / `GM_setValue` / `GM_deleteValue` / `GM_listValues` | Per-script namespaced; typed (objects/arrays/numbers/bools round-trip via JSON) |
| `GM_getValues` / `GM_setValues` / `GM_deleteValues` | Batch |
| `GM_addValueChangeListener` / `GM_removeValueChangeListener` | Local (same context) — see Partial for cross-tab |
| `GM_xmlhttpRequest` | Native `URLSession` (CORS-free), streaming `onloadstart/progress/load/error/timeout/loadend`, base64 for binary, **binary request bodies** (ArrayBuffer/typed array) + **`overrideMimeType`** (incl. the `charset=x-user-defined` byte-string trick), gated by `@connect` |
| `GM_addStyle` / `GM_addElement` | DOM injection in the isolated world |
| `GM_setClipboard` | |
| `GM_openInTab` | Opens a real new tab; returns a handle whose `onclose` fires + `.closed` flips when the tab closes, and `.close()` dismisses it |
| `GM_download` | Native fetch into Downloads (`@connect`-gated); streaming `onprogress/onload/onerror`, real `abort()` |
| `GM_notification` | Local banner attributed to the script; `onclick`/`ondone`; in-app toast fallback if the OS suppresses it |
| `GM_registerMenuCommand` / `GM_unregisterMenuCommand` | Surfaced in the browser "•••" menu; a tap fires the script's callback |
| `GM_cookie` (`GM.cookie.list/set/delete`) | `@connect`-gated cookie I/O |
| `GM_getTab` / `GM_saveTab` / `GM_listTabs` | Per-tab, per-script object (namespaced by script UUID) |
| `window.onurlchange` | SPA URL tracking — fires on `pushState`/`replaceState`/`popstate`/`hashchange` (also a `urlchange` event) |
| `GM_getResourceText` / `GM_getResourceURL` | `@resource` fetched natively; URL served as a `data:` URL |
| `GM_log` | Routed to the dashboard log viewer |
| `GM_info` | `scriptHandler: "BrownBear"`, metadata block, parsed script object |
| `unsafeWindow` | The page window. For `@grant none` **and** a granted script whose grants are all page-world-safe (the common Violentmonkey case), the script runs in the page's REAL main world, so `unsafeWindow === window ===` the page's own globals. Only a script taking a not-yet-page-routed grant (`GM_notification`) stays isolated (see `@inject-into`) |
| `GM.*` (Promise variants) | `GM.getValue/setValue/…/xmlHttpRequest/addStyle/…` |
| `@require` / `@resource` | Native fetch (no CORS) |
| `@match` / `@include` / `@exclude` / `@exclude-match` | Chrome match patterns + glob/regex |
| `@run-at` | `document-start` / `document-end` / `document-idle` |
| `@inject-into` | `page` / `content` / `auto` (default). `content` = our isolated world. `page`/`auto` run in the page's REAL main world (CSP-immune native eval). This applies to `@grant none` **and** to granted scripts whose grants are all page-world-safe — those reach native through a pristine, page-unreadable document-start **vault** (`window.__bbPageGM`) instead of the isolated GM bridge (Violentmonkey parity). A script taking a not-yet-page-routed grant (`GM_notification`) stays in the isolated world |
| `@grant` (incl. `none`) | Native + JS-enforced |
| `@connect` | Enforced for `GM_xmlhttpRequest` |
| `@noframes` | |
| `@crontab` / `@background` | Background execution via `BGTaskScheduler` |

## Page-world GM surface (Violentmonkey parity)

A granted script whose grants are **all page-world-safe** runs in the page's real main world, yet its
GM surface still works — value/resource **reads** are served synchronously from a cache pre-seeded into
the script's closure; own-data **writes** and the streaming/cross-origin APIs go through the pristine,
non-configurable, page-unreadable document-start **vault** (`window.__bbPageGM`) to a *restricted* native
handler, and results/events stream back native→page via `window.__bbPageXHR(id, …)` — never a
page-readable DOM channel. Page-world-safe today:

`GM_getValue`/`setValue`/`deleteValue`/`listValues` (+ batch + `GM_addValueChangeListener`) ·
`GM_getResourceText`/`URL` · `GM_addStyle`/`GM_addElement` · `GM_setClipboard` · `GM_log` ·
`GM_xmlhttpRequest` · `GM_download` · `GM_registerMenuCommand`/`Unregister` · `GM_openInTab` ·
`GM_cookie` · `GM_getTab`/`saveTab`/`listTabs` · `window.onurlchange` · `unsafeWindow`.

## Partial

| API | Limitation |
|---|---|
| `GM_notification` (page world) | Works in the isolated world; not yet streamed to the page world, so a script taking `@grant GM_notification` (with page-world-safe grants otherwise) still runs **isolated**. |
| `GM_addValueChangeListener` `remote` | A change made in another tab/the dashboard broadcasts `remote: true` to **isolated-world** scripts; delivery to a **page-world** script (its listener fires same-context only) is not yet wired. |
| `@run-at document-idle` | Simulated via the `window` load event (WebKit has no native document-idle). |
| `GM_xmlhttpRequest` `responseType` | `text`/`json`/`arraybuffer`/`blob` supported; `document`/`stream` are best-effort. |
| **`document-start` timing** | Our injection runs one async `getScripts` hop after WebKit's `document-start` (the native bridge resolves a script's identity/grants before the body runs). For virtually every script this is imperceptible; but a script that *races the page's very first inline script* (e.g. to shadow a global before the page reads it) may run a microtask later than a static MV2 content script (Violentmonkey). Closing this fully needs a static pre-compiled `WKUserScript` document-start path — tracked, not yet built. The `@require` disk cache already removes the larger per-asset round-trip. |

## Not yet implemented (planned)

`GM_notification` in the page world · `remote: true` value-change delivery to page-world scripts ·
`@run-at document-idle` native timing.

A script that calls an unimplemented API will get a rejected bridge call (or a no-op for the
JS-only ones) rather than crashing.

## Verification

`BrownBearTests/GMRuntimeCompatibilityTests.swift` runs the **real** `brownbear-runtime.js` in a
`JSContext` against a mock bridge and asserts: typed storage round-trips, async `GM.*`, value-change
listeners firing, `@require` code with GM access, a natively-fetched resource **eval'd** with GM
access, and base64+`eval` ("obfuscated") code — all keeping `GM_*` in scope.
