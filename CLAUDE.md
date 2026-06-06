# CLAUDE.md — Engineering Operating Manual for AI Agents

> This file is loaded into context at the start of every Claude Code session in this
> repository. It is the **single source of truth** for how code is written here. Treat
> every rule below as a hard constraint, not a suggestion. If a request conflicts with
> this file, surface the conflict before proceeding.

BrownBear is a production iOS browser + userscript engine. The bar is **App-Store-shippable,
enterprise-grade code**. We do not ship demos.

---

## ⚠️ READ THIS BEFORE YOU TOUCH A SINGLE LINE

Look. I have reviewed enough AI-generated and junior-engineer pull requests to last three
lifetimes, and my patience is gone. I have watched `// TODO: implement later` get merged into
`main`. I have seen a "finished" feature that was three stubbed functions and a `return nil`
wearing a trench coat. I have read a 600-line file that ended in `// ... rest unchanged` when
the rest was very much NOT unchanged. I am tired. My laptop has been to the edge of the wall
more than once. We are not doing that here.

So before you start generating, internalize this:

- **If you don't understand the file, READ IT.** Open it. Read its neighbors. Do not pattern-
  match a vibe and hallucinate an API that doesn't exist. Guessing is how we get 2am pages.
- **"It compiles" is not "it works."** And "it looks done" is not "it's done." If you didn't
  run it, say you didn't run it. Do not lie to me with confidence.
- **Half-finished and HONEST beats finished and FAKE.** If you ran out of room, stop and tell
  me exactly what's left. I can work with that. I cannot work with a stub you called complete.
- **This app runs untrusted code from the internet.** Every shortcut you take at the JS↔native
  boundary is a CVE with my name on the commit blame. Slow down. Validate the input. Fail closed.
- **No slop. No filler. No "here's a basic implementation to get you started."** I didn't ask
  for a starting point. I asked for the thing. Build the thing.

If any of that stings, good. Channel it. Now read the rules below — they are not decoration.

---

## 0. Prime Directives (non-negotiable)

1. **No mock implementations.** Every function you write must do the real thing. No
   `// TODO: implement`, no `fatalError("not implemented")`, no stubbed return values
   standing in for logic.
2. **No truncation.** Never write `// ... rest of the code` or elide a method body. If a
   file is long, write the whole file. If you run low on room, split across messages but
   deliver the complete artifact.
3. **No placeholder comments as substitutes for code.** Comments explain *why*, never
   replace *what*.
4. **No silent scope cuts.** If you cannot finish something, say so explicitly and list
   exactly what remains. Never present partial work as complete.
5. **Security is a feature, not an afterthought.** This app executes untrusted JavaScript.
   Every boundary between a userscript and native code is a trust boundary. Treat it as one.
6. **Match the surrounding code.** Naming, comment density, file layout, and idiom must be
   indistinguishable from the existing module you are editing.

---

## 1. Project Identity

| | |
|---|---|
| **Name** | BrownBear — Userscripts & Power Browser |
| **Platform** | iOS 16.4+ / iPadOS 16.4+ (WKWebView RegExp lookbehind requires 16.4) |
| **Languages** | Swift (UI + native services), Objective-C++ (WebKit bridge where required), JavaScript (injected runtime) |
| **UI Stack** | SwiftUI for the dashboard/editor, UIKit for the browser chrome & tab grid |
| **Rendering** | WebKit `WKWebView` (the only engine Apple permits) |
| **Persistence** | Core Data (scripts, logs, schedules) + `UserDefaults` (GM value store namespaced per script) |
| **Background** | `BGTaskScheduler` (app refresh + processing) driving a headless `JSContext` |

### What we are building (the 5 modules)
1. **Chromium-style browser foundation** — multi-tab `WKWebView`, rounded omnibox, square tab grid.
2. **Metadata parser + injection bridge** — `@name/@match/@include/@exclude/@run-at` parsing, URL glob→regex matching, `WKUserContentController` injection at document-start/end.
3. **ScriptCat-style mobile sandbox** — `GM_xmlhttpRequest`, `GM_setValue/getValue`, message-passing bridge via `WKScriptMessageHandler`.
4. **Background + @crontab queue** — `BGTaskScheduler` + Core Data persisted schedules, headless `JSContext` execution loop.
5. **Manager dashboard + editor** — SwiftUI script library, toggles, logs, code editor with line numbers and syntax highlighting.

Read `ARCHITECTURE.md` before touching cross-module code.

---

## 2. Reference Repositories (study, do not copy verbatim)

We synthesize architecture from four projects. They live as documented references in
`References/REFERENCES.md`. **Understand the pattern, then write our own clean implementation.**
Never paste GPL/AGPL or incompatibly-licensed source into our tree.

| Repo | What we learn from it | License caution |
|---|---|---|
| `chromium/chromium` (`/ios`) | Omnibox, tab grid controllers, WebState lifecycle, browser chrome layout | BSD-3 — patterns OK, do not vendor code |
| `scriptscat/scriptcat` | Background script framework, crontab queue, sandbox runtime, GM event loop | GPLv3 — **architecture only, no code reuse** |
| `quoid/userscripts` | WebKit metadata parsing, document-start injection lifecycle | GPLv3 — **architecture only** |
| `shenruisi/Stay` | Mobile script-library dashboard layout (UX only) | ⚠️ **stale: last OSS 2022, now closed-source** — App Store screenshots for UX only |
| `simonbs/Runestone` | iOS code-editor engine: Tree-sitter syntax highlighting, line numbers | **MIT** — safe to reference *and* depend on directly |

> ⚠️ **License hygiene:** ScriptCat and Userscripts are GPL/AGPL. We learn *how the system
> behaves* and re-implement independently under our own MIT license. Do not copy functions,
> file structures verbatim, or comments. When in doubt, ask.

---

## 3. Repository Layout

```
BrownBear/
├── App/            App lifecycle, scene delegate, DI container
├── Browser/        BrownBearBrowserViewController, omnibox, navigation
├── ScriptEngine/   Metadata parser, URL matcher, injection orchestration
├── Sandbox/        WKScriptMessageHandler pipeline, GM API native handlers
├── Background/     BrownBearBackgroundScheduler, crontab evaluator, JSContext runner
├── Storage/        Core Data stack, models, GM value store
├── Dashboard/      SwiftUI manager dashboard
├── Editor/         Code editor (line numbers, syntax highlight, validation)
├── Models/         Shared value types (Script, ScriptMetadata, RunAt, Schedule, LogEntry)
└── Resources/JS/   brownbear-core.js, brownbear-sandbox.js, injected runtime
```

JavaScript runtime files live in `BrownBear/Resources/JS/`. They are bundled and read at
runtime — never inline large JS as Swift string literals.

---

## 4. Coding Standards

### Swift
- Swift 5.8+, `// swiftlint:disable` is forbidden without an inline justification comment.
- 4-space indentation. 120-column soft limit (see `.swiftlint.yml`).
- `final class` by default; prefer `struct` for value types. Protocol-oriented where it earns its keep.
- **No force-unwraps** (`!`) and **no `try!`** in non-test code. Use `guard let`/`guard try`.
- All async work uses Swift Concurrency (`async/await`, actors). No completion-handler pyramids in new code.
- Mark shared mutable state with an `actor` or confine it to `@MainActor`. The GM value
  store and the background scheduler are concurrency hot-spots — treat them carefully.
- Public types get doc comments (`///`). Explain *why*, document thread-safety expectations.
- Errors are typed (`enum BrownBearError: Error`). Never `throw NSError(...)` ad hoc.

### Objective-C++ (`.mm`)
- Only where the WebKit bridge genuinely needs it. Justify the file's existence in its header.
- ARC on. Bridge to Swift via clean `@interface` headers, not implementation details.

### JavaScript (injected runtime)
- Strict mode. No globals leaking into page scope except the deliberately exposed `GM_*`/`GM.*` surface.
- The sandbox runtime must assume the page is hostile. Never trust `window`, `document`,
  or prototypes that page scripts can tamper with — capture references at injection time.
- Communicate with native exclusively through the registered `WKScriptMessageHandler`
  channel with a request/response correlation id. No other side channels.

---

## 5. Security Rules (this app runs untrusted code)

1. **Every message from JS to native is untrusted input.** Validate type, shape, and bounds
   before acting. A malformed `GM_xmlhttpRequest` payload must fail closed, never crash.
2. **`GM_xmlhttpRequest` is a proxied network primitive.** Enforce the script's `@connect`
   allowlist. Do not let a script exfiltrate to arbitrary hosts without a declared grant.
3. **GM value store is namespaced per-script.** Script A must never read Script B's values.
   Keys are prefixed with the script's stable UUID.
4. **No `eval` of native-provided strings** and no `JSContext` exposed to page content —
   the headless background context is isolated from any live `WKWebView`.
5. **Secrets never logged.** Execution logs may contain script output; scrub auth headers
   and tokens passed through `GM_xmlhttpRequest`.
6. **Background execution respects the user.** Schedules are user-visible, pausable, and
   killable from the dashboard. Nothing runs that the user can't see and stop.

---

## 6. Testing & Verification

- Unit tests for: metadata parsing, glob→regex matching, crontab evaluation, GM value
  namespacing. These are pure logic — they have no excuse to be untested.
- Every parser change ships with table-driven test cases including malformed input.
- Before claiming a task done: build it, run the relevant tests, and report the actual
  result (including failures). Never report "done" on unverified code.
- If you cannot build (e.g. full Xcode not installed in this environment), say so and state
  what you *did* verify (syntax, logic review) versus what you *could not*.

---

## 7. Git & Commit Discipline

- **Conventional Commits** are mandatory: `type(scope): subject`.
  Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`.
  Scopes mirror modules: `browser`, `engine`, `sandbox`, `background`, `storage`,
  `dashboard`, `editor`, `repo`.
- Subject ≤ 72 chars, imperative mood ("add", not "added").
- One logical change per commit. No "wip" or "fix stuff" commits on `main`.
- Never commit secrets, `.xcuserstate`, build artifacts, or `DerivedData`.
- Work on feature branches (`feat/…`, `fix/…`); open a PR; `main` stays green.
- Commit/push only when the user asks. Co-author trailer is configured in CONTRIBUTING.md.

See `CONTRIBUTING.md` for the full workflow.

---

## 8. How to Work in This Repo (agent workflow)

1. **Read before you write.** Open the file and its neighbors; match their style.
2. **Plan multi-file changes** before editing. State the files you'll touch and why.
3. **Small, verifiable steps.** Land one module slice, verify, then continue.
4. **Update docs alongside code.** New GM API ⇒ update `ARCHITECTURE.md` and README feature list.
5. **When blocked on a real decision** (license, API design, a genuine fork in the road),
   ask — don't guess and bury the assumption.
6. **Faithful reporting.** Tests failing? Say so with output. Step skipped? Say which.

---

## 9. Definition of Done

A change is done when **all** of these hold:
- [ ] Implements the full behavior — no stubs, no truncation.
- [ ] Compiles (or, if the environment can't build, the limitation is stated explicitly).
- [ ] Relevant unit tests written and passing.
- [ ] No new SwiftLint violations.
- [ ] Security rules in §5 upheld for any new trust boundary.
- [ ] Docs updated.
- [ ] Conventional-commit message written.

If any box is unchecked, the work is **not** done — say so.
