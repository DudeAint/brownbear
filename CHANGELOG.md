# Changelog

All notable changes to BrownBear are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Repository scaffolding: `CLAUDE.md` agent operating manual, `README.md`, `ARCHITECTURE.md`,
  `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`.
- Tooling config: `.gitignore` (Swift/Xcode), `.editorconfig`, `.swiftlint.yml`.
- GitHub automation: CI build/test via XcodeGen with SwiftPM + DerivedData caching, nightly &
  release IPA pipelines, CodeQL, Dependabot, auto-labeler, and a first-contributor greeter.
- Reference documentation in `References/REFERENCES.md` (Stay → Runestone for the editor).
- Module roadmap incl. Module 6 (Web Extensions / Chrome Web Store).
- **Module 1 — Browser foundation:** multi-tab `WKWebView`, rounded omnibox with URL/search
  classification, Chromium-style square tab grid, full `WKNavigationDelegate` lifecycle.
- **Module 2 — Userscript engine:** `ScriptMetadataParser` (`@name/@match/@run-at/@grant/…`),
  `URLMatcher` (Chrome match patterns + glob/regex includes/excludes), `ScriptStore`.
- **Module 3 — Sandbox & GM bridge:** isolated-world injected runtime (`brownbear-runtime.js`)
  with native-bound per-script identity, native `@grant` enforcement, per-script `GMValueStore`
  namespacing, and `GM_xmlhttpRequest` over native `URLSession` (CORS-free, `@connect`-gated).
- **Module 4 — Background & @crontab:** `CrontabSchedule` (5-field cron + `@every` + `once`),
  `HeadlessScriptRunner` (DOM-less `JSContext` with a background GM surface), and
  `BrownBearBackgroundScheduler` (`BGTaskScheduler` app-refresh + processing tasks) that runs
  `@crontab`/`@background` scripts while the app is closed, with durable logs and schedule state.
- **Module 5 — Dashboard & editor:** a SwiftUI manager (`BrownBearDashboardView`) to install,
  toggle, inspect, and delete scripts, view execution logs, and monitor background schedules;
  plus an in-app code editor (`ScriptEditorScreen`) built on Runestone (line numbers, gutter,
  auto-closing pairs, BrownBear theme) with live metadata parsing and save-time validation.
- **Module 6 — Web Extensions (foundation):** install Chrome/Firefox `.crx`/`.zip` extensions —
  dependency-free CRX/ZIP unpacker, MV2/MV3 manifest parser, on-disk store, `content_scripts`
  injection via the shared isolated world, and a `chrome.*`/`browser.*` surface
  (`storage.{local,sync,session}`, `runtime`, `i18n`, `extension`) with per-extension isolation.
  See `docs/WEB_EXTENSIONS.md` for the support matrix.
- **GM engine hardening:** native (CORS-free) `@require`/`@resource` fetch, value-change listeners,
  and verified `eval`-of-fetched/obfuscated code with `GM_*` in scope (`docs/GM_API.md`).

[Unreleased]: https://github.com/DudeAint/brownbear/commits/main
