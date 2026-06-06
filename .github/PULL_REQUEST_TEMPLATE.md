<!-- PR title MUST be a Conventional Commit, e.g. feat(browser): add rounded omnibox -->

## What & Why
<!-- What does this change do, and why is it needed? Link the issue: Closes #___ -->

## Module / Scope
<!-- browser | engine | sandbox | background | storage | dashboard | editor | repo -->

## How It Was Tested
<!-- Commands run, unit tests added, device behavior observed. Paste real output. -->

## Definition of Done (CLAUDE.md §9)
- [ ] Full implementation — no stubs, mocks, or truncated code
- [ ] Builds (or environment limitation stated explicitly)
- [ ] Unit tests added/updated and passing
- [ ] No new SwiftLint violations
- [ ] Security trust boundaries upheld (CLAUDE.md §5) for any new JS↔native surface
- [ ] Docs updated (README / ARCHITECTURE / CHANGELOG as applicable)
- [ ] Conventional-commit title

## Security Considerations
<!-- Does this touch the JS↔native bridge, GM_xmlhttpRequest, the value store, or background
     execution? If yes, describe how the trust boundary is preserved. If no, write "none". -->

## Screenshots / Recordings
<!-- For UI changes. Delete if not applicable. -->
