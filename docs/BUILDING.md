# Building BrownBear

> **Recommended path: GitHub Actions.** CI on free macOS runners is the canonical, always-clean
> way to build and test BrownBear. Every push and PR is built automatically by
> [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). If you don't have a Mac with Xcode
> handy, **just open a PR and let Actions build it** — that's a fully supported workflow.

## The project is generated, not committed

BrownBear's Xcode project is defined declaratively in [`project.yml`](../project.yml) and
generated with [XcodeGen](https://github.com/yonsm/XcodeGen). We do **not** commit
`BrownBear.xcodeproj` — this keeps diffs reviewable and avoids merge conflicts in an opaque
`.pbxproj`. The project file is in `.gitignore`.

## Build in CI (recommended)

Nothing to do — it's automatic:

- **Every push / PR** → lint, commit-lint, JS syntax check, and a full **build + test** on an
  iOS Simulator (`ci.yml`).
- **Security** → CodeQL scans Swift + the injected JS (`codeql.yml`).
- **Releases** → nightly + stable channels (`nightly.yml`, `release.yml`, see
  [RELEASING.md](RELEASING.md)).

You can also trigger CI by hand from the **Actions** tab (the `CI` workflow has
`workflow_dispatch`).

## Build locally (optional)

Requires macOS with **Xcode 15+**.

```bash
# 1. Install the project generator
brew install xcodegen

# 2. (Optional) clone the study references — git-ignored, never vendored
./scripts/fetch_references.sh

# 3. Generate the Xcode project from project.yml
xcodegen generate

# 4. Open and run, or build from the CLI:
open BrownBear.xcodeproj
# or:
xcodebuild build \
  -project BrownBear.xcodeproj -scheme BrownBear \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

## Run the tests

```bash
xcodebuild test \
  -project BrownBear.xcodeproj -scheme BrownBear \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest'
```

## Linting

```bash
brew install swiftlint
swiftlint lint --config .swiftlint.yml
```

## Notes

- **Deployment target is iOS 16.4** (WKWebView RegExp lookbehind requires it — see ARCHITECTURE.md §6).
- Dependencies are resolved by SPM automatically (`Runestone` for the Module 5 editor).
- If a simulator name/OS in the commands above doesn't exist on your machine, run
  `xcrun simctl list devices` and substitute an available one.
