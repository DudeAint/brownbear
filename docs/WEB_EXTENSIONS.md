# Web Extensions in BrownBear (Module 6)

BrownBear can install and run **browser extensions** (Chrome/Firefox `.crx`/`.zip`), the way
[Orion](https://kagi.com/orion/) and [Gear Browser](https://gear4.app/) do — not just userscripts.
This is the **foundation** (Phase 1): manifest parsing, packaging, install/management, content-script
injection, and a core `chrome.*`/`browser.*` surface. Deeper Chromium-internal APIs are constrained
by what WebKit exposes; we document exactly what's supported and degrade honestly.

## iOS reality check

Apple mandates WebKit, so BrownBear cannot run Chromium's extension engine. Instead it provides a
**compatibility layer**: content scripts run in an isolated `WKContentWorld` (same mechanism as our
userscript sandbox), and `chrome.*` calls bridge to native Swift services. Many content-script /
storage / i18n extensions work; APIs that require deep network or browser-process integration are
partial or unsupported below.

## Install

- Dashboard → **Extensions** → **+** → pick a `.crx` or `.zip`.
- `.crx` (CRX2 and CRX3) headers are stripped automatically; the embedded ZIP is unpacked with a
  dependency-free reader (system `Compression` framework for DEFLATE).
- `manifest.json` (manifest_version **2 or 3**) is validated before anything is written to disk.

## Supported (Phase 1)

| Capability | Notes |
|---|---|
| Manifest v2 **and** v3 | incl. polymorphic fields: `web_accessible_resources` (string[] / object[]), `content_security_policy` (string / object), `default_icon` (string / object), `action`/`browser_action`/`page_action` |
| `content_scripts` injection | `matches` / `exclude_matches` / `include_globs` / `exclude_globs`, `run_at` (start/end/idle), `all_frames`, `js` + `css` |
| `chrome.storage.{local,sync,session}` | `get`/`set`/`remove`/`clear`, callback **and** Promise (`browser.*`) forms; isolated per-extension **and** per-area |
| `chrome.runtime` | `id`, `getManifest()`, `getURL()`, `getPlatformInfo()`, `lastError`; `sendMessage`/`onMessage`/`connect` are no-op stubs |
| `chrome.i18n` | `getMessage()` (default-locale `_locales/.../messages.json` preloaded), `getUILanguage()`, `getAcceptLanguages()` |
| `chrome.extension.getURL` | legacy alias for `runtime.getURL` |

## Partial / Not yet (Phase 2+)

| Area | Status |
|---|---|
| Background **service worker / event page** | Not yet run. Planned via the headless `JSContext` path (Module 4 infra). |
| **Popups** (`action.default_popup`) / options pages | Parsed but no UI surface yet. |
| Messaging (`runtime.sendMessage`/`onMessage`, ports, `tabs.sendMessage`) | Stubs (no cross-context delivery yet). |
| `chrome.tabs`, `chrome.webNavigation` | Not yet. |
| `chrome.webRequest` / `declarativeNetRequest` | Constrained by WebKit; not yet. |
| **Direct Chrome Web Store install** (by URL) | Not yet; install via downloaded `.crx`/`.zip`. |
| `storage.onChanged` events | Stub. |

A content script that calls an unimplemented `chrome.*` method gets a rejected/no-op call rather
than a crash.

## Architecture

- `WebExtensionManifest` — MV2/MV3 parser (normalizes the polymorphic shapes).
- `WebExtensionArchive` — dependency-free CRX/ZIP unpacker.
- `WebExtension` + `WebExtensionStore` — model + install/management (files on disk, metadata index).
- `WebExtensionStorage` — `chrome.storage`, isolated per extension + area.
- `brownbear-webext-runtime.js` — the injected `chrome`/`browser` surface + content-script loader
  (isolated world, native-bound per-injection token).
- `WebExtensionMessageRouter` — native bridge: `getContentScripts` (URL matching via the shared
  `URLMatcher`) + `chrome.storage.*`.

Tracked as the north-star epic in [`ARCHITECTURE.md`](../ARCHITECTURE.md) and GitHub issue #7.
