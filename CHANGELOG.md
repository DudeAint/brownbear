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

[Unreleased]: https://github.com/DudeAint/brownbear/commits/main
