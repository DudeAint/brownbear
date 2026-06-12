# Web Extensions in BrownBear (Module 6)

BrownBear can install and run **browser extensions** (Chrome/Edge/Firefox `.crx`/`.zip`/`.xpi`), the
way [Orion](https://kagi.com/orion/) and [Gear Browser](https://gear4.app/) do — not just userscripts.
All build phases have shipped: the install/manage pipeline, content scripts, `declarativeNetRequest`
content blocking, **headless background service workers** (classic *and* ES-module), popup/options/
**side-panel** pages, content↔background **and** background↔content messaging + long-lived ports, and a
broad native-backed `chrome.*` surface (`tabs`/`windows`/`webNavigation`/`scripting`/`cookies`/
`notifications`/`contextMenus`/`identity`/`permissions`/`alarms`/`storage`/`runtime`/`i18n`/`idle`/
`downloads`/`userScripts`/`sidePanel`/`offscreen`/`action`), **`chrome.webRequest` blocking on frame
navigations** (the one request class WebKit lets an extension intercept), an extension **New Tab page**
(`chrome_url_overrides.newtab`), and one-tap install from the **Chrome / Edge / Firefox** stores (an
in-page **Add to BrownBear** button + paste-a-link), plus the web-platform APIs JavaScriptCore itself
lacks. The focus now is hardening against real shipping extensions (ScriptCat, uBlock Origin Lite,
Violentmonkey, Dark Reader, Grammarly). Deeper Chromium-internal APIs are constrained by what WebKit
exposes; we document exactly what's supported and degrade honestly.

## iOS reality check

Apple mandates WebKit, so BrownBear cannot run Chromium's extension engine. Instead it provides a
**compatibility layer**: content scripts run in an isolated `WKContentWorld` (same mechanism as our
userscript sandbox), and `chrome.*` calls bridge to native Swift services. Many content-script /
storage / i18n extensions work; APIs that require deep network or browser-process integration are
partial or unsupported below.

## Install

Four routes, all landing in the same validated pipeline:

- **In-page "Add to BrownBear".** Browse the **Chrome Web Store**, **Edge Add-ons**, or **Firefox
  (AMO)** inside BrownBear; on an extension page, that store's native "Add to *<Browser>*" button is
  rewritten to **Add to BrownBear** (→ **Remove from BrownBear** once installed) and re-applies as the
  store's single-page app navigates between listings without reloading. For Chrome and Edge, BrownBear
  spoofs their browser sniff (Edge-/Chrome-branded `userAgentData` + `window.chrome`) and forces the
  matching desktop UA so the enabled button renders; AMO is left on the default desktop UA (a forced
  Firefox UA makes it 500 under WebKit) and its "Download Firefox" button is rewritten directly.
- **Recommended extensions.** Dashboard → **Extensions** → a curated, categorized list (ad-blocking,
  privacy, productivity, …) with a one-tap **Get** — uBlock Origin Lite, Dark Reader, Bitwarden, and more.
- **From a web store…** → paste a Chrome Web Store / Edge Add-ons / Firefox (AMO) link, or a bare 32-char
  Chrome id. BrownBear pulls the package from that store's public on-demand endpoint and installs it.
- **Install from file…** → pick a `.crx`, `.zip`, or `.xpi`.

Under the hood: `.crx` (CRX2 and CRX3) headers are stripped automatically and the embedded ZIP is
unpacked with a dependency-free reader (system `Compression` framework for DEFLATE; a Firefox `.xpi` is
a plain ZIP). `manifest.json` (manifest_version **2 or 3**) is validated before anything is written to
disk. An installed extension's enabled/disabled state, options, and stored data all persist; uninstall
purges its files **and** its storage/DNR/userScript state. A pinnable **puzzle** button in the browser
toolbar surfaces installed extensions' actions (popup/options/side-panel, with live badges, and a
long-press menu to manage/uninstall).

## Supported

| Capability | Notes |
|---|---|
| Manifest v2 **and** v3 | incl. polymorphic fields: `web_accessible_resources` (string[] / object[]), `content_security_policy` (string / object), `default_icon` (string / object), `action`/`browser_action`/`page_action`; `declarative_net_request.rule_resources`; `commands` |
| `content_scripts` injection | `matches` / `exclude_matches` / `include_globs` / `exclude_globs`, `run_at` (start/end/idle), `all_frames`, `js` + `css` |
| **`declarativeNetRequest`** (static rulesets) ⟶ **Phase 2** | Each ruleset is compiled to a `WKContentRuleList` and applied to every tab. Supports `block`, `allow`/`allowAllRequests`, `upgradeScheme`; `urlFilter` (incl. `||` / `|` / `^` / `*`) and `regexFilter`; `initiatorDomains`/`excludedInitiatorDomains` → `if-domain`/`unless-domain`; `resourceTypes`/`excludedResourceTypes`; `domainType`; case sensitivity. Recompiles live on install/enable/disable. |
| **Background service worker / event page** ⟶ **Phase 2** | MV3 `service_worker` and MV2 `background.scripts` run headless in a per-extension `JSContext` with a native `chrome.*` surface. `console.*`, `setTimeout`/`setInterval` provided. |
| **Messaging** (`runtime.sendMessage` / `onMessage`) ⟶ **Phase 2** | Content script → its own background worker, with a response channel: synchronous `sendResponse`, async `sendResponse` (`return true` keeps the channel open), and `Promise`-returning listeners all work. |
| **`chrome.alarms`** ⟶ **Phase 2** | `create`/`clear`/`clearAll`/`get`/`getAll` + `onAlarm`, backed by GCD timers (foreground lifetime — see caveats). |
| **`chrome.storage.onChanged`** ⟶ **Phase 2** | Fires in background workers for changes from any source (content script, background, uninstall). |
| `chrome.storage.{local,sync,session}` | `get`/`set`/`remove`/`clear`, callback **and** Promise (`browser.*`) forms; isolated per-extension **and** per-area; no-op writes don't fire `onChanged` |
| `chrome.runtime` | `id`, `getManifest()`, `getURL()`, `getPlatformInfo()`, `getContexts()` (lists the worker + live popup/options/offscreen contexts), `onInstalled`/`onStartup` (fired on worker boot), `lastError` |
| `chrome.i18n` | `getMessage()` (default-locale `_locales/.../messages.json` preloaded), `getUILanguage()` (real device language), `getAcceptLanguages()` (callback + Promise), `detectLanguage()` (via `NLLanguageRecognizer`) |
| `chrome.extension.getURL` | legacy alias for `runtime.getURL` |
| **Direct store install** (Chrome · Edge · Firefox) | An in-page **Add to BrownBear** button on a store detail page, a one-tap **recommended** list, a pasted store link / bare Chrome id, or a `.crx`/`.zip`/`.xpi` file — all fetch from the store's public endpoint and run the same validated install. |
| **Popup & options pages** | `action.default_popup` and `options_ui`/`options_page` render in a real WKWebView over the `chrome-extension://` scheme (a `WKURLSchemeHandler` serves the extension's packaged files). The page gets a **synchronous** `chrome.*` surface — `storage` (+ live `onChanged`), `runtime` (`id`/`getManifest`/`getURL`/`sendMessage`→background/`getPlatformInfo`/`openOptionsPage`), `i18n`, `extension`. Opened in a real tab (Dashboard → Extensions → long-press, or `chrome.tabs.create` / `runtime.openOptionsPage`); query strings survive (`install.html?uuid=…`). |
| **ES-module service workers** | `"background": { "type": "module" }` (e.g. uBlock Origin Lite). JSC has no native ES-module loader, so a vendored acorn parser + an AST rewriter (`brownbear-esm-linker.js`) links the module graph against a synchronous registry, resolving sibling modules from the package on demand. Named-import cycles snapshot (CommonJS semantics); top-level `await` is unsupported (fails closed). |
| **`chrome.tabs`** | `query`/`get`/`getCurrent`/`create`/`update`/`remove`/`reload`/`sendMessage`/`captureVisibleTab` + `onCreated`/`onUpdated`/`onRemoved`/`onActivated`, bridged to `TabManager` via `WebExtensionBridgeHost`. Integer tab ids (UUID↔Int registry); single window (`windowId` 1). `captureVisibleTab` snapshots the active web view to a `data:` URL (png/jpeg), gated on `activeTab`/host permission. |
| **`chrome.windows`** | `get`/`getCurrent`/`getLastFocused`/`getAll`/`create`/`update`/`remove` — one window on iOS. |
| **`chrome.webNavigation`** | `onBeforeNavigate`/`onCommitted`/`onCompleted`/`onHistoryStateUpdated`/`onDOMContentLoaded` etc., gated by host permissions. |
| **`chrome.scripting`** (MV3) + **`tabs.executeScript`/`insertCSS`** (MV2) | `executeScript`/`insertCSS`/`removeCSS`, `registerContentScripts`/`getRegisteredContentScripts`/`updateContentScripts`/`unregister`, permission-gated. |
| **`chrome.cookies`** | `get`/`getAll`/`set`/`remove`/`getAllCookieStores` + `onChanged`, over `WKHTTPCookieStore`, host-permission-gated. |
| **`chrome.notifications`** | `create`/`update`/`clear`/`getAll`/`getPermissionLevel` + `onClicked`/`onClosed`/`onButtonClicked`, backed by `UNUserNotificationCenter`. |
| **`chrome.contextMenus`** | `create`/`update`/`remove`/`removeAll` + `onClicked`, surfaced in the page/long-press menu. |
| **`chrome.identity`** | `getRedirectURL`, `launchWebAuthFlow` (ASWebAuthenticationSession), `getAuthToken`, `onSignInChanged`. |
| **`chrome.permissions`** | `contains`/`getAll`/`request`/`remove` over declared + optional permissions. |
| **Background ↔ content messaging + ports** | `tabs.sendMessage` (background→content), `runtime.sendMessage` from the worker → its pages (popup/options/offscreen, with the reply `await`-able), and long-lived `runtime.connect`/`onConnect` ports in **both** directions via a token-bound port hub (`onDisconnect` fires on teardown). |
| **`chrome.action`** / **`chrome.pageAction`** (MV2) | action: `setIcon`/`setBadgeText`/`setBadgeBackgroundColor`/`setTitle`/`setPopup` + getters + `onClicked` (fires when the action has no popup). pageAction aliases the title/icon/popup setters + onClicked; `show`/`hide`/`isShown` are no-ops (no per-tab page-action button on iOS). |
| **`chrome.downloads`** | `download` (the transfer runs on a `URLSession` task into the app's Downloads folder, shown in the Downloads UI), `search`/`cancel`/`pause`/`resume`/`erase`/`removeFile`, + `onCreated`/`onChanged`/`onErased`. Gated on the `downloads` permission; the filename is sanitized to a single safe component and request headers reject CRLF/NUL injection + URLSession-owned headers. `open`/`show`/`showDefaultFolder` are no-ops (no iOS file-manager surface). |
| **`chrome.idle`** | `queryState`/`setDetectionInterval`/`onStateChanged`. iOS can't observe true user input, so state maps app/device condition — data-protected → `locked`, foreground-active → `active`, else `idle`; `onStateChanged` fires on app foreground/background + lock/unlock, coalesced. |
| **`chrome.userScripts`** (MV3) | `register`/`getScripts`/`update`/`unregister`/`configureWorld`/`resetWorldConfiguration` — the MV3 userScripts world API. |
| **`chrome.sidePanel`** (MV3) + **`sidebar_action`** (Firefox) | `setOptions`/`getOptions`/`setPanelBehavior`/`getPanelBehavior`/`open`. iOS has no docked side-panel surface, so the panel page is presented as a sheet (same per-extension scheme handler + page bridge as popup/options). Opens from the toolbar's long-press menu or `sidePanel.open()` / an action click when `openPanelOnActionClick` is set. |
| **`chrome.webRequest`** (frame navigations) | **Blocking** `onBeforeRequest` for MAIN- and SUB-FRAME navigations — the one request class `WKNavigationDelegate` lets us intercept — so an MV2 ad-blocker can cancel ad iframes / redirect-trackers. Sub-RESOURCE interception (scripts/XHR/images) stays unavailable (WebKit exposes no hook); use `declarativeNetRequest` for those. Also drives the `.user.js` install hand-off to a webRequest-based manager (Violentmonkey). |
| **`chrome_url_overrides.newtab`** | An extension can replace the New Tab page (e.g. **Momentum**). The override HTML is served over the extension's `chrome-extension://` scheme with the full page `chrome.*` surface + DOM-storage polyfills (`localStorage`/`sessionStorage`/in-memory `IndexedDB`), since a custom-scheme origin has no native DOM storage. |
| **Web-platform APIs in the worker** | JavaScriptCore ships none of these; we provide `fetch` + `Headers`/`Request`/`Response` (+ `.blob()`/`.json()`/`.arrayBuffer()`), `AbortController`/`AbortSignal`, `FormData`, `Blob`/`File`/`FileReader`, `XMLHttpRequest` (network via the gated fetch; `blob:` synchronously), `URL`/`URLSearchParams`, `TextEncoder`/`TextDecoder`, `btoa`/`atob`, `structuredClone`, `Event`/`EventTarget`/`CustomEvent`, `performance`, `queueMicrotask`, `crypto.getRandomValues`/`randomUUID` + `crypto.subtle` (digest/HMAC/AES-GCM/AES-CBC/PBKDF2/ECDSA + JWK), and `navigator`/`location`. All network egress is host-permission-gated (CORS-free, like Chrome). |
| **MV2 background-page environment** | An MV2 `background.scripts` bundle is a background *page* in Chrome, so for MV2 only we expose `window` (= the global) and a minimal non-rendering `document` (createElement, `<a>` URL parsing, fragments, event no-ops). An MV3 service worker has no DOM and uses `chrome.offscreen` (below) for real-DOM work instead. |
| **`chrome.offscreen`** (MV3) | `createDocument`/`hasDocument`/`closeDocument`. A DOM-less service worker gets a **real** offscreen document hosted in a hidden `WKWebView` (same engine as popup/options: per-extension scheme handler + page bridge), positioned off-screen so its JS/timers stay live. One document per extension (Chrome's rule); the document URL is sanitized to the extension's own package (no traversal / cross-extension / foreign scheme); torn down on disable/uninstall. The worker drives it over `chrome.runtime` messaging — `chrome.runtime.sendMessage` from the worker now fans out to its pages (popup/options/offscreen) and `await`s the reply. |
| **Userscript-manager extensions** | A `.user.js` navigation can be handed off to an installed manager that claims it via a `declarativeNetRequest` redirect rule (e.g. **ScriptCat** → its `install.html?url=…`), evaluated in the navigation delegate since WebKit can't redirect a main-frame request. BrownBear's own native userscript installer remains available; the user chooses. |

## Known gaps (honest no-ops)

All build phases shipped — install/manage, content scripts, `declarativeNetRequest` blocking,
classic **and** ES-module background service workers, two-way messaging + ports, `tabs`/`windows`/
`webNavigation`/`scripting`/`cookies`/`notifications`/`contextMenus`/`identity`/`alarms`/`storage`
(+ events), `chrome.webRequest` frame-navigation blocking, the web-platform/IndexedDB worker surface,
popup/options/**side-panel** UI, `chrome.offscreen` real-DOM documents, an extension **New Tab page**,
and **in-page "Add to BrownBear"** across the Chrome / Edge / Firefox stores. The gaps below are **not
"todo"** — they're the hard edges of running an extension model inside WebKit (no extension process, no
privileged synchronous network layer) on iOS. We degrade honestly; an unimplemented `chrome.*` method
gets a rejected/no-op call rather than a crash.

| Area | Why it stays a no-op on iOS/WebKit |
|---|---|
| `chrome.webRequest` for sub-RESOURCES (scripts / XHR / images / fonts …) | WebKit exposes no synchronous interception for sub-resource requests, so those `onBeforeRequest` listeners never fire — use `declarativeNetRequest` (→ `WKContentRuleList`) for that blocking. **FRAME navigations are different**: `WKNavigationDelegate` lets us intercept them, so blocking `onBeforeRequest` on main/sub-frame navigations *does* fire and cancel (see Supported). A `.user.js` main-frame navigation is also matched against extensions' DNR `redirect` rules so a userscript manager's install page opens. |
| `declarativeNetRequest` `modifyHeaders` / `requestMethods` / `requestDomains` filters | No `WKContentRuleList` equivalent — skipped-and-counted at compile so a ruleset never over-blocks. (`redirect` is unsupported for general blocking, but is honored for the `.user.js` hand-off above.) |
| `chrome.commands` dispatch | Parsed, and `chrome.commands`/`chrome.action.onClicked` exist, but there's no keyboard-shortcut/toolbar source on iOS to fire them. |
| `chrome.alarms` while the app is **suspended/closed** | Timers are foreground-lifetime; durable wake-ups would ride the BGTask path (Module 4) and aren't guaranteed by iOS. |
| `storage.onChanged` in **content scripts** | Fires in background workers and extension pages; content scripts have no per-tab push channel in the shared content world. |
| Native messaging, devtools pages, `chrome.proxy`, `chrome.privacy`, etc. | No host/native counterpart on iOS. |

### Being verified on-device
- **Edge Add-ons / Firefox AMO in-page install.** The in-page "Add to BrownBear" rewrite and the native
  install path are wired for all three stores and unit-tested against a mock DOM
  (`Tests/JS/webstore-button.test.js`), but each store's *hydrated* single-page-app rendering — which
  button it paints for a spoofed client — is verified on a real device and tuned per store.
- **MV2 ad-blocker coverage.** `declarativeNetRequest` + `chrome.webRequest` frame-navigation blocking
  cover most ads; sub-resource-level blocking that an extension would do via `webRequest` (unavailable
  on WebKit) is the known ceiling.

## DNR → WKContentRuleList: how rules translate

`declarativeNetRequest` is the one ad-blocking primitive iOS actually gives us (`WKContentRuleList`),
and DNR maps onto it well. The pure `DeclarativeNetRequest` compiler converts each rule:

- **`urlFilter`** → a WebKit `url-filter` regex: `||` anchors to the domain (any subdomain),
  leading/trailing `|` anchor start/end, `^` is the separator class, `*` is a wildcard, and literal
  metacharacters are escaped. `regexFilter` is passed through.
- **action**: `block` → `block`, `allow`/`allowAllRequests` → `ignore-previous-rules`,
  `upgradeScheme` → `make-https`.
- **conditions**: initiator domains → `if-domain`/`unless-domain` (subdomain-matching), resource
  types → WebKit `resource-type` (`stylesheet`→`style-sheet`, `xmlhttprequest`→`fetch`, …),
  `domainType` → `load-type`.
- **ordering**: WebKit applies the *last* matching action, so rules are sorted ascending by DNR
  priority and then by action rank (block before allow) — preserving "higher priority wins, allow
  beats block at a tie".

**Fidelity over coverage**: anything that can't be represented faithfully (a redirect, a header
rewrite, a method/request-domain filter) is **skipped and counted**, never approximated into a rule
that would block more than the author intended.

## Architecture

- `WebExtensionManifest` — MV2/MV3 parser (normalizes the polymorphic shapes; `declarative_net_request`, `commands`).
- `WebExtensionArchive` — dependency-free CRX/ZIP unpacker.
- `WebExtension` + `WebExtensionStore` — model + install/management (files on disk, metadata index).
- `WebExtensionStorage` — `chrome.storage`, isolated per extension + area; broadcasts changes for `onChanged`.
- `ChromeWebStore` — store-link/id parsing + CRX download (on-demand endpoint).
- `DeclarativeNetRequest` — **pure** DNR-rules → `WKContentRuleList`-JSON compiler.
- `WebExtensionContentBlocker` — compiles each enabled extension's rulesets and swaps them into the
  shared `WKUserContentController` on every change.
- `WebExtensionBackgroundContext` — one extension's headless background `JSContext` (chrome.* natives,
  alarms, timers, message bus); strictly single-queue.
- `WebExtensionRuntime` — owns the background contexts, reconciles them on change (single-flight),
  routes content/popup→background messages, and fans `storage.onChanged` to the right worker.
- `WebExtensionSchemeHandler` — `WKURLSchemeHandler` serving `chrome-extension://<id>/<path>` from an
  extension's packaged files (Phase 3, popup/options).
- `WebExtensionPageViewController` — renders a popup/options page in a WKWebView with the scheme
  handler + a synchronous `chrome.*` page surface; pushes `storage.onChanged` into the page.
- `brownbear-webext-runtime.js` / `brownbear-webext-background.js` / `brownbear-webext-page.js` — the
  injected content-side, headless background, and extension-page `chrome`/`browser` surfaces.
- `WebExtensionMessageRouter` — content-side native bridge: `getContentScripts` (URL matching via the
  shared `URLMatcher`), `chrome.storage.*`, `runtime.pageLog`, and `runtime.sendMessage` (→ `WebExtensionRuntime`).
- `WebExtensionBridgeHost` — the browser-VC-implemented bridge backing `chrome.tabs`/`windows`/
  `cookies`/`notifications` for content scripts, pages, **and** background workers.
- `WebExtensionPageSession` — builds the WKWebView configuration (scheme handler + page bridge + live
  storage/cookie/notification push) for a popup/options/install/**offscreen** page; host-agnostic, so
  the same engine drives a sheet, a real tab, or a hidden offscreen document.
- `WebExtensionOffscreenManager` — hosts an MV3 `chrome.offscreen` document in a hidden, off-screen
  WKWebView (one per extension); sanitizes the document URL to the extension's own package.
- `BrownBearIDBStore` — per-namespace snapshot persistence for the headless IndexedDB engine.
- `UserScriptInstallRouter` — pure matcher that resolves an extension's `declarativeNetRequest`
  `redirect` rule for a `.user.js` URL (regexFilter + `regexSubstitution`), so the navigation delegate
  can hand the install to a userscript-manager extension that claims it.
- `ExtensionStoreSource` + `ChromeWebStore` / `EdgeAddons` / `FirefoxAddons` — one unified type that
  detects a Chrome / Edge / Firefox store *detail* page, exposes the stable per-store install id, and
  downloads the package (CRX for Chrome/Edge, XPI for Firefox).
- `WebStoreInstallHandler` (+ `brownbear-webstore.js`) — backs the in-page **Add to BrownBear** button.
  The PAGE-world script detects the store, spoofs its browser sniff, rewrites the install button and
  re-applies across the store's SPA route changes; the native handler resolves the store + extension
  from the page URL (gated to a store frame that owns it) and runs the real install/remove/query.
- `WebExtensionBackgroundContext+SidePanel` — the `chrome.sidePanel` / `sidebar_action` native
  (`__bb_sidepanel`), driving per-extension panel state and presenting the panel as a sheet.
- `WebExtensionBackgroundContext+WebRequest` — dispatches blocking `webRequest.onBeforeRequest` for
  frame navigations into the worker (the WebKit-interceptable request class) and the `.user.js` hand-off.

Tracked as the north-star epic in [`ARCHITECTURE.md`](../ARCHITECTURE.md) and GitHub issue #7.
