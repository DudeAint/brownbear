# Releasing BrownBear

BrownBear ships on two channels, both fully automated by GitHub Actions.

| Channel | Tag | Stability | Trigger | Workflow |
|---|---|---|---|---|
| **Nightly** | `nightly` (rolling) | 🌙 bleeding edge, may break | every push to `main` + daily 07:00 UTC | [`.github/workflows/nightly.yml`](../.github/workflows/nightly.yml) |
| **Stable** | `vX.Y.Z` | ✅ released | you push a SemVer tag | [`.github/workflows/release.yml`](../.github/workflows/release.yml) |

## Nightly (automatic — do nothing)

Every merge to `main` republishes the `nightly` pre-release: the `nightly` tag is moved to the
new `HEAD`, notes are auto-generated from every commit since the last stable `vX.Y.Z`, and (once
the Xcode project exists) an unsigned `.ipa` is attached. Nightly is always marked **pre-release**.

## Stable (cut a versioned release)

We follow [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

- **PATCH** — bug fixes only (`fix:` commits)
- **MINOR** — new, backward-compatible features (`feat:` commits)
- **MAJOR** — breaking changes (`feat!:` / `BREAKING CHANGE:`)

To release:

```bash
git checkout main && git pull
# pick the version per the commits since the last tag
git tag v0.1.0
git push origin v0.1.0
```

The `release` workflow then:
1. Builds the Release configuration (when the Xcode project exists) and attaches the `.ipa`.
2. Reads every commit since the previous stable tag and **categorizes by Conventional Commit
   type** into ✨ Features / 🐛 Fixes / ⚡ Performance / ⚠️ Breaking / 🔧 Other.
3. Publishes a GitHub Release `BrownBear vX.Y.Z` with those patch notes.

Release candidates use a hyphen and are auto-marked pre-release:

```bash
git tag v0.1.0-rc.1 && git push origin v0.1.0-rc.1
```

## Why this works without manual patch notes

Because every commit follows [Conventional Commits](../CONTRIBUTING.md#commit-convention--conventional-commits-100),
the release notes write themselves. Keep commit subjects clean and the changelog is free.
