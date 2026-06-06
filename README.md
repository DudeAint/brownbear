<div align="center">

# 🐻 BrownBear

### Userscripts & Power Browser for iOS

**A Chromium-inspired mobile browser with a ScriptCat-class userscript engine —
background scripts, `@crontab` scheduling, and a sandboxed GM API, brought to iOS for the first time.**

[![Platform](https://img.shields.io/badge/platform-iOS%2016.4%2B-black.svg)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.8%2B-orange.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

</div>

---

## Why BrownBear

iOS has never had a true *power* userscript runtime. Safari extensions like
[Userscripts](https://github.com/quoid/userscripts) and [Stay](https://apps.apple.com/app/stay-for-safari/id1591620171)
brought Greasemonkey-style injection to mobile, and [Gear Browser](https://gear4.app/) proved a
dedicated userscript browser can ship on the App Store. But none of them deliver what
[ScriptCat](https://github.com/scriptscat/scriptcat) gives desktop users: **scripts that keep
working in the background, on a schedule, without a tab open.**

BrownBear is that missing piece — a standalone browser that pairs a clean, Chromium-style
interface with a sandboxed engine capable of running `@background` userscripts driven by
`@crontab`, all within the constraints Apple's WebKit and background-execution model allow.

## Features

### 🌐 The Browser
- Multi-tab architecture on `WKWebView` with a Chromium-style **square tab grid**.
- A custom **rounded omnibox** with smart URL/search detection, secure-state indicator, and full back/forward/refresh navigation.
- Precise page-lifecycle tracking via `WKNavigationDelegate` (`didStartProvisionalNavigation` → `didFinish`).

### 📜 The Userscript Engine
- Tampermonkey/Greasemonkey/Violentmonkey-compatible metadata parsing:
  `@name`, `@namespace`, `@match`, `@include`, `@exclude`, `@run-at`, `@grant`, `@require`, `@connect`, `@crontab`.
- A glob→regex URL matcher tuned for WebKit's RegExp engine (lookbehind requires iOS 16.4+).
- Document-start / document-end / document-idle injection via `WKUserContentController`.

### 🧪 The Sandbox & GM API
- A hostile-page-resistant JavaScript sandbox that captures clean references at injection time.
- Native-backed GM primitives:
  - `GM_xmlhttpRequest` — proxied through native `URLSession` to bypass CORS, gated by the script's `@connect` allowlist.
  - `GM_setValue` / `GM_getValue` / `GM_deleteValue` / `GM_listValues` — per-script namespaced store.
  - `GM_addStyle`, `GM_setClipboard`, `GM_openInTab`, `GM_log`, and friends.
- A `WKScriptMessageHandler` request/response pipeline with correlation ids.

### ⏰ Background & @crontab (the headline)
- `BGTaskScheduler`-driven execution (app refresh + processing tasks).
- A persisted schedule store (Core Data) and a `@crontab` evaluator.
- A headless `JSContext` runner that boots, executes the due script, logs output, and tears down — **while the app is closed.**

### 📊 The Dashboard & Editor
- A SwiftUI manager to install, toggle, and inspect scripts.
- Live execution logs and background-task monitoring.
- An in-app code editor with line numbers, syntax highlighting, and save-time validation.

## Architecture at a Glance

```
┌──────────────────────────────────────────────────────────────┐
│                         BrownBear App                          │
├───────────────┬───────────────┬──────────────┬────────────────┤
│   Browser     │ Script Engine │   Sandbox    │   Dashboard     │
│  (UIKit)      │  (parse/match)│  (GM bridge) │   (SwiftUI)     │
├───────────────┴───────────────┴──────────────┴────────────────┤
│        WKWebView · WKUserContentController · WKScriptMsg        │
├────────────────────────────────────────────────────────────────┤
│  Background: BGTaskScheduler → crontab eval → headless JSContext│
├────────────────────────────────────────────────────────────────┤
│        Storage: Core Data (scripts/logs/schedules) + GM store   │
└────────────────────────────────────────────────────────────────┘
```

Full design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Project Status

🚧 **Pre-alpha — actively being built.** This repository is currently being scaffolded
module by module (see the 5-module roadmap in [`ARCHITECTURE.md`](ARCHITECTURE.md)).
Follow the commit history for progress.

## Requirements

- Xcode 15+
- iOS / iPadOS 16.4+ deployment target
- An Apple Developer account for on-device background-task testing

## Getting Started

```bash
git clone https://github.com/<owner>/brownbear.git
cd brownbear
open BrownBear.xcodeproj   # generated once the Xcode project lands
```

> The reference repositories are documented in [`References/REFERENCES.md`](References/REFERENCES.md).
> We study their architecture; we do not vendor their (GPL/AGPL) source. See the license note there.

## Contributing

We use [Conventional Commits](https://www.conventionalcommits.org), feature branches, and
green-`main` discipline. AI agents working in this repo must follow [`CLAUDE.md`](CLAUDE.md).
Start with [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security

This app executes untrusted JavaScript. If you find a vulnerability, please follow the
responsible-disclosure process in [`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE) © BrownBear contributors. BrownBear is an independent implementation; it
learns architectural patterns from the projects in [`References/REFERENCES.md`](References/REFERENCES.md)
but contains no copied source from GPL/AGPL-licensed projects.

## Acknowledgements

Inspired by [ScriptCat](https://github.com/scriptscat/scriptcat),
[Userscripts](https://github.com/quoid/userscripts), [Stay](https://github.com/mapleDistant/Stay),
[Gear Browser](https://gear4.app/), and the iOS layer of [Chromium](https://github.com/chromium/chromium).
