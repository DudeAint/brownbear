# Security Policy

BrownBear executes **untrusted JavaScript** (userscripts) on the user's device, proxies
network requests natively, and runs scheduled code in the background. Security is core, not
peripheral. This document covers our threat model and disclosure process.

## Supported Versions

While in pre-alpha, only the `main` branch receives security fixes.

| Version | Supported |
|---------|-----------|
| `main`  | ✅ |
| tagged pre-releases | ⚠️ best-effort |

## Threat Model (summary)

The trust boundaries we defend (full detail in [`ARCHITECTURE.md`](ARCHITECTURE.md) §5):

1. **Hostile web page → injected userscript runtime.** Pages may try to hijack the GM bridge
   by overriding prototypes/globals. We capture clean references at injection time.
2. **Userscript → native bridge.** Every `WKScriptMessageHandler` envelope is untrusted input;
   we validate shape/type/bounds and fail closed.
3. **Userscript → network.** `GM_xmlhttpRequest` is gated by the script's `@connect` allowlist.
   No exfiltration to undeclared hosts.
4. **Script ↔ script.** GM values are namespaced per-script UUID; no cross-script reads.
5. **Background execution.** The headless `JSContext` has no DOM, is isolated from foreground
   web views, and every scheduled job is user-visible and user-stoppable.
6. **Secrets.** Auth headers/tokens are scrubbed from logs.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, report privately via one of:
- GitHub's **private vulnerability reporting** (Security → Report a vulnerability) on this repo, or
- email the maintainers (address listed on the repo profile).

Include: affected component, reproduction steps, impact, and any PoC. We aim to acknowledge
within **72 hours** and provide a remediation timeline after triage. We practice coordinated
disclosure and will credit reporters who wish to be credited.

## Out of Scope

- Vulnerabilities in third-party userscripts a user chooses to install (we sandbox them, but
  cannot vouch for their behavior).
- Issues requiring a jailbroken device or physical access with the device unlocked.
