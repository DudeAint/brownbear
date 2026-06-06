# AGENTS.md — Rules for Every AI Agent in This Repo

> This file exists so that **any** coding agent — Claude Code, Codex, Cursor, Copilot
> Workspace, Gemini, whatever tool is fashionable next month — gets the same non-negotiable
> rules the moment it opens this repository. If you are an AI and you are reading this:
> congratulations, you are now on the hook. The authoritative, full manual is
> [`CLAUDE.md`](CLAUDE.md). This file is the short, blunt version. Read both.

---

## Listen to me. I'm only saying this once.

I have lost the will to gently coach another autocomplete engine through basic professional
standards. The honeymoon is over. Here is what happens in this repo:

### You do NOT, under any circumstances:
1. Write `// TODO`, `// implement this`, `fatalError("unimplemented")`, or a function that
   returns a fake value to make the types line up. **If it's not real, it doesn't ship.**
2. Write `// ... existing code ...` or `// rest unchanged` and call a file "done." Output the
   **whole** file. Every line. I will diff it. I always diff it.
3. Tell me something is finished, tested, or working when you did not finish, test, or run it.
   Lying to me is the single fastest way to get every one of your commits reverted on sight.
4. Invent an API, a method, or a config key because it "should" exist. Open the file. Check.
5. Paste GPL/AGPL source from our reference repos (ScriptCat, Userscripts) into this MIT tree.
   Learn the pattern, write it yourself. Copy-paste is how we get sued, not shipped.
6. Take a shortcut at the JavaScript ↔ native bridge. That boundary runs untrusted code.
   Validate every message. Fail closed. No exceptions, no "I'll harden it later."

### You absolutely DO:
1. **Read before you write.** Understand the module, match its style exactly (naming, spacing,
   comment density, error handling). New code should be invisible in a blame view.
2. **Finish what you start, or say precisely what's left.** Honest and partial > fake and whole.
3. **Verify, then report the truth.** Ran the tests? Show the output — pass *or* fail. Couldn't
   build in this environment? Say that, and say what you *did* check (syntax, logic).
4. **One logical change per commit**, Conventional Commits format (`type(scope): subject`),
   imperative mood, ≤72 chars. See [`CONTRIBUTING.md`](CONTRIBUTING.md).
5. **Update the docs in the same change.** New GM API → update `ARCHITECTURE.md` and the README
   feature list. Stale docs are a bug.
6. **Ask when it's a real fork in the road** (license question, public API shape, security
   trade-off). Don't bury a guess and hope nobody notices. I notice.

---

## The 10-second checklist before you hand me anything

- [ ] No stubs, no mocks, no truncation. The code does the real thing.
- [ ] I read the surrounding code and matched its style.
- [ ] It builds — or I clearly stated why I couldn't build and what I verified instead.
- [ ] Tests exist for the logic and I'm reporting their real result.
- [ ] No new SwiftLint violations. No force-unwraps, no `try!` in non-test code.
- [ ] Any JS↔native surface validates its input and fails closed.
- [ ] Conventional-commit message, docs updated.

If even one box is empty, the work is **not done** — and you will tell me that, in plain words,
instead of dressing it up.

---

## Where to look
- Full operating manual & coding standards: [`CLAUDE.md`](CLAUDE.md)
- System design & module roadmap: [`ARCHITECTURE.md`](ARCHITECTURE.md)
- Workflow, branches, commit format: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Threat model & disclosure: [`SECURITY.md`](SECURITY.md)
- What the reference repos teach us (and the license rules): [`References/REFERENCES.md`](References/REFERENCES.md)

Now go do good work. I'm rooting for you. Don't make me regret it.
