# Contributing to BrownBear

Thanks for helping build the first ScriptCat-class userscript browser on iOS. This guide
covers the workflow, standards, and commit conventions. AI agents must **also** follow
[`CLAUDE.md`](CLAUDE.md), which is the binding operating manual.

---

## Ground Rules

- **No mock/stub/truncated code.** Ship complete, working implementations (see `CLAUDE.md` §0).
- **`main` is always green.** All work happens on branches and lands via PR.
- **Security first.** This app runs untrusted JavaScript; respect the trust boundaries in
  [`ARCHITECTURE.md`](ARCHITECTURE.md) §5.
- **License hygiene.** We learn from GPL/AGPL references but never copy their source.

---

## Development Setup

```bash
git clone https://github.com/DudeAint/brownbear.git
cd brownbear
# Open in Xcode 15+ once the project file lands:
open BrownBear.xcodeproj
```

Tooling we use:
- **SwiftLint** — run before committing: `swiftlint` (config: `.swiftlint.yml`).
- **EditorConfig** — your editor should honor `.editorconfig` automatically.

---

## Branching Model

- `main` — protected, always releasable.
- `feat/<scope>-<short-desc>` — new features.
- `fix/<scope>-<short-desc>` — bug fixes.
- `docs/…`, `refactor/…`, `chore/…`, `ci/…` — as appropriate.

Example: `feat/engine-glob-url-matcher`.

---

## Commit Convention — Conventional Commits 1.0.0

Every commit message MUST follow:

```
<type>(<scope>): <subject>

<body — what & why, wrapped at 72 cols>

<footer — BREAKING CHANGE / refs>
```

**Types:** `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`, `revert`.

**Scopes** (mirror the modules): `browser`, `engine`, `sandbox`, `background`, `storage`,
`dashboard`, `editor`, `repo`, `deps`.

**Rules:**
- Subject ≤ 72 chars, imperative mood, no trailing period.
- One logical change per commit.
- Breaking changes: add `!` after the scope (`feat(sandbox)!: …`) and a `BREAKING CHANGE:` footer.

**Examples:**
```
feat(browser): add rounded omnibox with URL/search classification
fix(engine): anchor @match globs so example.com/* doesn't over-match
refactor(sandbox): capture clean GM references at injection time
docs(repo): document the five-module roadmap in ARCHITECTURE.md
test(background): add table-driven crontab next-fire cases
```

### Co-authorship trailer
When an AI agent authors or co-authors a commit, include the trailer:
```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

---

## Pull Requests

1. Branch from up-to-date `main`.
2. Keep PRs focused — one module slice or one fix.
3. Fill out the PR template (`.github/PULL_REQUEST_TEMPLATE.md`).
4. Ensure: builds, SwiftLint clean, tests pass, docs updated.
5. Reference issues with `Closes #123`.
6. A green CI run is required before merge. Squash-merge with a Conventional-Commit title.

---

## Code Standards

See [`CLAUDE.md`](CLAUDE.md) §4 for the full Swift / Objective-C++ / JavaScript standards.
Highlights:
- No force-unwraps or `try!` in non-test code.
- Swift Concurrency (`async/await`, `actor`) for shared mutable state.
- Injected JS assumes a hostile page; capture references at injection time.
- Typed errors (`enum BrownBearError: Error`), never ad-hoc `NSError`.

---

## Testing

- Pure-logic modules (parser, matcher, crontab, GM namespacing) **must** have unit tests,
  including malformed-input cases.
- Report real results. A failing test is information, not something to hide.

---

## Reporting Bugs / Requesting Features

Use the issue templates in `.github/ISSUE_TEMPLATE/`. For security issues, **do not** open a
public issue — follow [`SECURITY.md`](SECURITY.md).

---

## Code of Conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Be excellent to each other.
