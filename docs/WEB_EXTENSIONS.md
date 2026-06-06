# Web Extensions in BrownBear (Module 6)

BrownBear can install and run **browser extensions** (Chrome/Firefox `.crx`/`.zip`), the way
[Orion](https://kagi.com/orion/) and [Gear Browser](https://gear4.app/) do — not just userscripts.
**Phase 1** delivered the foundation (manifest parsing, packaging, install/management, content-script
injection, a core `chrome.*` surface). **Phase 2** adds the things that make extensions actually
*do* something in the background: `declarativeNetRequest` content blocking, headless background
service workers, content↔background messaging, `chrome.alarms`, `storage.onChanged`, and one-tap
install straight from the Chrome Web Store. Deeper Chromium-internal APIs are constrained by what
WebKit exposes; we document exactly what's supported and degrade honestly.

## iOS reality check

Apple mandates WebKit, so BrownBear cannot run Chromium's extension engine. Instead it provides a
**compatibility layer**: content scripts run in an isolated `WKContentWorld` (same mechanism as our
userscript sandbox), and `chrome.*` calls bridge to native Swift services. Many content-script /
storage / i18n extensions work; APIs that require deep network or browser-process integration are
partial or unsupported below.

## Install

- Dashboard → **Extensions** → **+** → **Install from file…** (pick a `.crx` or `.zip`), or
- **+** → **From Chrome Web Store…** → paste a `chromewebstore.google.com` link (or a bare 32-char
  extension id). BrownBear pulls the `.crx` from Google's public on-demand CRX endpoint (the same one
  Chrome uses) and installs it.
- `.crx` (CRX2 and CRX3) headers are stripped automatically; the embedded ZIP is unpacked with a
  dependency-free reader (system `Compression` framework for DEFLATE).
- `manifest.json` (manifest_version **2 or 3**) is validated before anything is written to disk.

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
| `chrome.runtime` | `id`, `getManifest()`, `getURL()`, `getPlatformInfo()`, `onInstalled`/`onStartup` (fired on worker boot), `lastError` |
| `chrome.i18n` | `getMessage()` (default-locale `_locales/.../messages.json` preloaded), `getUILanguage()`, `getAcceptLanguages()` |
| `chrome.extension.getURL` | legacy alias for `runtime.getURL` |
| **Direct Chrome Web Store install** ⟶ **Phase 2** | Paste a store link or extension id; the `.crx` is fetched and installed. |
| **Popup & options pages** ⟶ **Phase 3** | `action.default_popup` and `options_ui`/`options_page` render in a real WKWebView over the `chrome-extension://` scheme (a `WKURLSchemeHandler` serves the extension's packaged files). The page gets a **synchronous** `chrome.*` surface — `storage` (+ live `onChanged`), `runtime` (`id`/`getManifest`/`getURL`/`sendMessage`→background/`getPlatformInfo`/`openOptionsPage`), `i18n`, `extension`. Open it from Dashboard → Extensions → long-press an extension. |

## Module 6 is complete

Phases 1–3 deliver the install/manage pipeline, content scripts, `declarativeNetRequest` blocking,
background service workers, messaging, alarms, storage (+ events), Chrome Web Store install, and
popup/options UI. The remaining gaps below are **not "todo"** — they're the hard edges of running an
extension model inside WebKit (no extension process, no privileged network layer) on iOS. We
implement the compatibility layer and degrade honestly; an unimplemented `chrome.*` method gets a
rejected/no-op call rather than a crash.

| Area | Why it stays a no-op on iOS/WebKit |
|---|---|
| `chrome.webRequest` (blocking/redirect) | WebKit exposes no synchronous request-interception API to extensions; `declarativeNetRequest` → `WKContentRuleList` is the only blocking primitive and it's ahead-of-time only. |
| `declarativeNetRequest` `redirect` / `modifyHeaders` / `requestMethods` / `requestDomains` | No `WKContentRuleList` equivalent — skipped-and-counted at compile so a ruleset never over-blocks. |
| Background **→ content** messaging (`tabs.sendMessage`) and long-lived **ports** (`runtime.connect`) | Content→background (and popup→background) is the supported direction; the reverse needs per-tab routing WebKit doesn't expose to the extension layer. |
| `chrome.tabs` / `webNavigation` / `scripting` write APIs, `chrome.commands` dispatch | No extension-facing tab/scripting control surface; `commands` is parsed and `chrome.commands`/`chrome.action.onClicked` exist as never-firing events (no keyboard/toolbar source on iOS). |
| `chrome.alarms` while the app is **suspended/closed** | Timers are foreground-lifetime; durable wake-ups would ride the BGTask path (Module 4) and aren't guaranteed by iOS. |
| `storage.onChanged` in **content scripts** | Fires in background workers and extension pages; content scripts have no per-tab push channel in the shared content world. |
| Native messaging, devtools pages, `chrome.proxy`, `chrome.privacy`, etc. | No host/native counterpart on iOS. |

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
  shared `URLMatcher`), `chrome.storage.*`, and `runtime.sendMessage` (→ `WebExtensionRuntime`).

Tracked as the north-star epic in [`ARCHITECTURE.md`](../ARCHITECTURE.md) and GitHub issue #7.
