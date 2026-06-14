<div align="center">

<img src="https://raw.githubusercontent.com/DudeAint/brownbear/main/docs/assets/banner.png" alt="BrownBear — Userscripts & Power Browser for iOS" width="100%" />

<br/>

**The first iOS browser to bring ScriptCat-class power to userscripts — background execution, `@crontab` scheduling, and a sandboxed GM API — _and_ run real Chrome Web Store extensions, all wrapped in a Chromium-inspired interface.**

<br/>

[![Platform](https://img.shields.io/badge/platform-iOS%2016.4%2B-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.8%2B-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![WebKit](https://img.shields.io/badge/WebKit-WKWebView-1589F0?style=for-the-badge&logo=safari&logoColor=white)](https://developer.apple.com/documentation/webkit)
[![License](https://img.shields.io/badge/License-MIT-3DA639?style=for-the-badge&logo=opensourceinitiative&logoColor=white)](LICENSE)

[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-FE5196?style=flat-square&logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org)
[![Code Style: SwiftLint](https://img.shields.io/badge/code%20style-SwiftLint-43B02A?style=flat-square)](.swiftlint.yml)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square)](CONTRIBUTING.md)
[![Status](https://img.shields.io/badge/status-pre--alpha-yellow?style=flat-square)](#-project-status)

<br/>

[**Features**](#-features) · [**Why BrownBear**](#-why-brownbear) · [**How It Compares**](#-how-it-compares) · [**Architecture**](#-architecture) · [**Contributing**](#-contributing)

</div>

---

## 🐻 Why BrownBear

iOS has never had a true *power* userscript runtime. Safari extensions like
[**Userscripts**](https://github.com/quoid/userscripts) and [**Stay**](https://apps.apple.com/app/stay-for-safari/id1591620171)
brought Greasemonkey-style injection to mobile, and [**Gear Browser**](https://gear4.app/) proved a
dedicated userscript browser can ship on the App Store. But none of them deliver the one thing
[**ScriptCat**](https://github.com/scriptscat/scriptcat) gives desktop users:

> **Scripts that keep working in the background — on a schedule — without a tab open.**

BrownBear is that missing piece. A standalone browser that pairs a clean, Chromium-style
interface with a sandboxed engine that runs `@background` userscripts driven by `@crontab`,
all within the constraints Apple's WebKit and background-execution model allow — honestly and
transparently, with every scheduled job visible and stoppable.

---

## ✨ Features

<table>
<tr>
<td width="50%" valign="top">

### 🌐 Chromium-style Browser
- Multi-tab architecture on `WKWebView`
- **Square tab grid** with live snapshots
- Custom **rounded omnibox** — URL/search detection, TLS indicator
- **Quick-search bangs** — `!yt cats`, `swift docs !gh` jump straight to YouTube, GitHub, Wikipedia, …
- Full back / forward / refresh / stop
- Precise lifecycle via `WKNavigationDelegate`

</td>
<td width="50%" valign="top">

### 📜 Userscript Engine
- Tampermonkey / Greasemonkey / Violentmonkey-compatible headers
- `@name` · `@match` · `@include` · `@exclude` · `@run-at` · `@grant` · `@connect` · `@crontab`
- Glob → regex URL matcher (WebKit-tuned)
- Inject at **document-start / end / idle**

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🧪 Sandbox & GM API
- Hostile-page-resistant runtime (clean refs captured at injection)
- `GM_xmlhttpRequest` via native `URLSession` (**CORS-free**, `@connect`-gated)
- `GM_setValue` / `getValue` — per-script namespaced store
- `GM_addStyle`, `GM_setClipboard`, `GM_openInTab`, `GM_log`

</td>
<td width="50%" valign="top">

### ⏰ Background & @crontab
- `BGTaskScheduler` (app-refresh + processing)
- Persisted schedule store (Core Data)
- 5-field crontab evaluator + `@every`
- Headless `JSContext` runs scripts **while the app is closed**

</td>
</tr>
<tr>
<td colspan="2" valign="top">

### 📊 Manager Dashboard & Editor
A polished SwiftUI dashboard to install, toggle, and inspect scripts · live execution logs ·
background-task monitor · an in-app code editor with **line numbers, JS syntax highlighting,
and save-time metadata validation**.

</td>
</tr>
<tr>
<td colspan="2" valign="top">

### 🧩 Browser Extensions (Chrome · Edge · Firefox)
Install and run **real browser extensions** (MV2 **and** MV3) from the Chrome Web Store, Edge
Add-ons, or Firefox AMO. Browse any of the three stores in-app and their install button becomes
**Add to BrownBear** (it survives the store's single-page navigation), or use a curated one-tap
**recommended** list, paste a link, or open a `.crx`/`.zip`/`.xpi`. A broad native-backed
`chrome.*` / `browser.*` surface: **service workers** (classic *and* ES-module, e.g. uBlock Origin
Lite) in a headless `JSContext`, **content scripts**, **popup / options / side-panel pages** over a
`chrome-extension://` scheme, `storage` · `tabs` · `windows` · `webNavigation` · `scripting` ·
`cookies` · `notifications` · `contextMenus` · `identity` · `alarms` · `idle` · `downloads` ·
`sidePanel` · `i18n` · `runtime` messaging + long-lived ports, **`declarativeNetRequest`** ad-blocking
via `WKContentRuleList` **plus `webRequest` frame-navigation blocking**, an extension **New Tab page**
(`chrome_url_overrides`), a polyfilled **IndexedDB**, and web platform APIs JavaScriptCore lacks
(`fetch`/`Headers`/`Request`/`Response`/`AbortController`/`FormData`/`Blob`/`File`/`XMLHttpRequest`/
Web Crypto/`structuredClone`). Userscript-manager extensions (e.g. **ScriptCat**) are first-class — a
`.user.js` link can be handed off to them. Constrained, partial, and unsupported APIs are
[documented honestly](docs/WEB_EXTENSIONS.md).

</td>
</tr>
</table>

---

## 🆚 How It Compares

| Capability | **🐻 BrownBear** | Gear Browser | Userscripts (Safari) | Stay (Safari) | ScriptCat (desktop) |
|---|:---:|:---:|:---:|:---:|:---:|
| Standalone iOS browser | ✅ | ✅ | ❌ (extension) | ❌ (extension) | ❌ (desktop) |
| Tampermonkey-style metadata | ✅ | ✅ | ✅ | ✅ | ✅ |
| `GM_xmlhttpRequest` (CORS-free) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Per-script value store | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Background scripts (no tab)** | ✅ | ⚠️ limited | ❌ | ❌ | ✅ |
| **`@crontab` scheduling** | ✅ | ❌ | ❌ | ❌ | ✅ |
| Built-in code editor | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Chrome Web Store extensions** | ✅ MV2/MV3 | ✅ | ❌ | ❌ | ❌ |
| Open source | ✅ MIT | ❌ | ✅ GPL | ✅ | ✅ GPL |

> ⚠️ iOS background execution is **budgeted and best-effort** by design — `@crontab` is a
> *target* schedule, not a hard real-time guarantee. BrownBear surfaces this honestly in the UI.

---

## 🧱 Architecture

BrownBear is one app composed of four runtime planes — a foreground browser, a pure-logic
engine, a security bridge, and a background scheduler:

```
            ┌────────────────────────── Foreground ──────────────────────────┐
 user ──▶ Omnibox ──▶ BrowserVC ──▶ WKWebView(tab) ──▶ injected runtime ──┐   │
            ▲              │                                               │   │
         TabGrid ◀─────────┘                                          GM calls │
            └─────────────────────── Bridge (WKScriptMessageHandler) ─────┘   │
                                            │                                  │
   Engine: ScriptMetadata · URLMatcher · InjectionPlanner  ◀── decides injection
                                            │                                  │
   Native GM services: Network(URLSession) · GMValueStore · Clipboard · Tabs   │
                                            │                                  │
            ┌──────────────────────── Background ─────────────────────────────┘
            BGTaskScheduler ──▶ CrontabEvaluator ──▶ headless JSContext ──▶ Logs
                                            │
   Storage: Core Data (Script, Schedule, LogEntry) + UserDefaults (GM values, namespaced)
```

📐 Full technical blueprint: [**ARCHITECTURE.md**](ARCHITECTURE.md)

---

## 🚀 Project Status

🚧 **Pre-alpha — actively being built.** All six modules have landed — the Chromium-style browser,
the userscript engine + sandbox, the `@crontab` background runner, the dashboard/editor, and the
Chrome Web Store extension runtime (Module 6) — and the focus now is real-world hardening against
shipping extensions (ScriptCat, uBlock Origin Lite, Violentmonkey, Grammarly, …). The engineering
bar is App-Store-shippable code: no stubs, no mocks, no truncation (see [`CLAUDE.md`](CLAUDE.md) and
[`AGENTS.md`](AGENTS.md)). Where WebKit's extension-less model forces a limit, we degrade honestly
and [document it](docs/WEB_EXTENSIONS.md).

---

## 🛠️ Getting Started

**Requirements:** Xcode 15+ · iOS/iPadOS 16.4+ deployment target · an Apple Developer account
for on-device background-task testing.

**Recommended: let GitHub Actions build it.** CI on free macOS runners is the canonical build
path — open a PR and it's built + tested automatically. To build locally, the Xcode project is
generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonsm/XcodeGen):

```bash
git clone https://github.com/DudeAint/brownbear.git
cd brownbear
brew install xcodegen          # one-time
xcodegen generate              # creates BrownBear.xcodeproj from project.yml
open BrownBear.xcodeproj
```

Full instructions (CI, local, tests, lint): [`docs/BUILDING.md`](docs/BUILDING.md).

> Reference repositories are documented in [`References/REFERENCES.md`](References/REFERENCES.md).
> We study their architecture; we never vendor their (GPL/AGPL) source.

---

## 🤝 Contributing

We use [Conventional Commits](https://www.conventionalcommits.org), feature branches, and
green-`main` discipline. **AI agents working in this repo must follow [`CLAUDE.md`](CLAUDE.md)
and [`AGENTS.md`](AGENTS.md).** Start with [`CONTRIBUTING.md`](CONTRIBUTING.md).

## 🔒 Security

This app executes untrusted JavaScript. Found a vulnerability? Follow the responsible-disclosure
process in [`SECURITY.md`](SECURITY.md) — please don't open a public issue.

---

## 💛 Contributors

Every PR, script, and bug report makes BrownBear better. Thank you.

<a href="https://github.com/DudeAint/brownbear/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=DudeAint/brownbear" alt="BrownBear contributors" />
</a>

<sub>Avatar wall auto-generated by <a href="https://contrib.rocks">contrib.rocks</a> — new contributors appear here after their first merged PR.</sub>

## ⭐ Star History

If BrownBear is useful to you, a star helps others find it.

<a href="https://star-history.com/#DudeAint/brownbear&Date">
  <img src="https://api.star-history.com/svg?repos=DudeAint/brownbear&type=Date" alt="Star History Chart" width="600" />
</a>

---

## 📄 License

[MIT](LICENSE) © BrownBear contributors. BrownBear is an independent implementation; it learns
architectural patterns from the projects in [`References/REFERENCES.md`](References/REFERENCES.md)
but contains no copied source from GPL/AGPL-licensed projects.

## 🙏 Acknowledgements

Inspired by [ScriptCat](https://github.com/scriptscat/scriptcat) ·
[Userscripts](https://github.com/quoid/userscripts) · [Stay](https://github.com/mapleDistant/Stay) ·
[Gear Browser](https://gear4.app/) · and the iOS layer of [Chromium](https://github.com/chromium/chromium).

<div align="center"><br/><sub>Built with 🐻 and an intolerance for stubbed code.</sub></div>
