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
| `GM_xmlhttpRequest` | Native `URLSession` (CORS-free), streaming `onloadstart/progress/load/error/timeout/loadend`, base64 for binary, gated by `@connect` |
| `GM_addStyle` / `GM_addElement` | DOM injection in the isolated world |
| `GM_setClipboard` | |
| `GM_openInTab` | Opens a real new tab |
| `GM_getResourceText` / `GM_getResourceURL` | `@resource` fetched natively; URL served as a `data:` URL |
| `GM_log` | Routed to the dashboard log viewer |
| `GM_info` | `scriptHandler: "BrownBear"`, metadata block, parsed script object |
| `unsafeWindow` | The page window |
| `GM.*` (Promise variants) | `GM.getValue/setValue/…/xmlHttpRequest/addStyle/…` |
| `@require` / `@resource` | Native fetch (no CORS) |
| `@match` / `@include` / `@exclude` / `@exclude-match` | Chrome match patterns + glob/regex |
| `@run-at` | `document-start` / `document-end` / `document-idle` |
| `@grant` (incl. `none`) | Native + JS-enforced |
| `@connect` | Enforced for `GM_xmlhttpRequest` |
| `@noframes` | |
| `@crontab` / `@background` | Background execution via `BGTaskScheduler` |

## Partial

| API | Limitation |
|---|---|
| `GM_addValueChangeListener` | Fires for changes in the **same execution context**. Cross-tab `remote: true` broadcast is not yet wired (each tab is a separate WebKit content process). |
| `@run-at document-idle` | Simulated via the `window` load event (WebKit has no native document-idle). |
| `GM_xmlhttpRequest` `responseType` | `text`/`json`/`arraybuffer`/`blob` supported; `document`/`stream` are best-effort. |

## Not yet implemented (planned)

`GM_registerMenuCommand` / `GM_unregisterMenuCommand` · `GM_notification` · `GM_cookie` ·
`GM_download` · `GM_getTab` / `GM_saveTab` / `GM_getTabs` · cross-tab value-change broadcast.

A script that calls an unimplemented API will get a rejected bridge call (or a no-op for the
JS-only ones) rather than crashing.

## Verification

`BrownBearTests/GMRuntimeCompatibilityTests.swift` runs the **real** `brownbear-runtime.js` in a
`JSContext` against a mock bridge and asserts: typed storage round-trips, async `GM.*`, value-change
listeners firing, `@require` code with GM access, a natively-fetched resource **eval'd** with GM
access, and base64+`eval` ("obfuscated") code — all keeping `GM_*` in scope.
