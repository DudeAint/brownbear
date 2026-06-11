# Extension boot test

A headless harness that boots a Chrome/Firefox extension's **background moving part** (MV3 service
worker, or MV2 background page / scripts) through BrownBear's **real** runtime — the same
`brownbear-indexeddb.js` + `brownbear-webext-background.js` (+ acorn/esm-linker for module workers)
the app loads into the background `JSContext` — and reports every boot error and every `chrome.*`
surface the extension touched that the shim doesn't provide.

It exists to answer one question without a device: *does this extension's background actually start,
or does it throw / reference an API we don't ship?* That's the difference between an extension that
is "installable" and one that is **usable**.

## What it catches (and what it can't)

Catches, faithfully:
- module **link failures** (a module-worker graph that won't link → the worker never starts);
- top-level **throws** during background evaluation;
- **unhandled rejections** during async init;
- access to `chrome.<ns>` / `chrome.<ns>.<method>` the shim leaves **undefined** (the #1 cause of a
  silently dead background), via a recording proxy over `chrome`/`browser`.

It deliberately mirrors the device environment: the bg context is a bare `JSContext` (not a
WKWebView), so `indexedDB` comes from the bundled `fake-indexeddb` engine — the harness loads it
first, exactly like `WebExtensionBackgroundContext.boot`, so an `indexedDB is not defined` here would
be a real gap, not an artifact. Native bridges (`__bb_*`) are mocked with neutral shapes.

It does **not** render popups/options pages (that needs a DOM — see the page-boot harness) and does
not exercise real network/tabs.

## Usage

1. Unpack the extensions you want to test to `/tmp/crx/<id>/unpacked/` (each with its `manifest.json`).
2. Run the whole set:

   ```sh
   node Tools/ExtensionBootTest/run-bg.mjs            # defaults to /tmp/crx
   node Tools/ExtensionBootTest/run-bg.mjs /path/to/crx-root
   ```

   or one extension (prints a single JSON verdict line, prefixed `BBVERDICT:`):

   ```sh
   node Tools/ExtensionBootTest/boot-bg.mjs /tmp/crx/<id>/unpacked <id>
   ```

The runtime JS is resolved relative to the repo (`../../BrownBear/Resources/JS`); override with
`BB_APP_JS_DIR=/abs/path/to/Resources/JS` for an out-of-tree run.

## Reading the report

`run-bg.mjs` prints a per-extension table (✅/❌, background kind, MV, vendor) and a **root-cause
rollup**: the `chrome.*` surface touched-but-missing across the whole set (sorted by how many
extensions hit it) and the distinct boot-error signatures. Fix the top of the missing rollup in
`brownbear-webext-background.js`, re-run, watch it shrink.
