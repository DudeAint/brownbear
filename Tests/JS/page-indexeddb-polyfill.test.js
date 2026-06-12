//
//  page-indexeddb-polyfill.test.js
//  BrownBear
//
//  WKWebView gives the chrome-extension:// PAGE origin no DOM storage, so window.indexedDB is missing —
//  a page that opens an IndexedDB database (Momentum's Dexie data layer, ScriptCat, …) throws
//  "IndexedDB API missing" or hangs. WebExtensionPageSession injects our in-memory IndexedDB engine
//  (brownbear-indexeddb.js) at document-start, wrapped in a guard so it installs ONLY when the page has
//  no working indexedDB and never overrides a real one. This test reproduces that exact guard wrapper and
//  asserts both behaviours, and that the engine exposes the IndexedDB surface (indexedDB + IDB* globals).
//
//  Keep the wrapper here in sync with WebExtensionPageSession.idbPolyfillSource.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/page-indexeddb-polyfill.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const ENGINE = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-indexeddb.js"), "utf8");
// The guard wrapper WebExtensionPageSession.idbPolyfillSource builds around the engine source.
const WRAPPED = "(function(){try{if(self.indexedDB&&typeof self.indexedDB.open==='function'){return;}}catch(e){}\n"
    + ENGINE + "\n})();";

function run(ctxSeed) {
    const ctx = Object.assign({}, ctxSeed);
    ctx.self = ctx; ctx.globalThis = ctx; ctx.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    vm.createContext(ctx);
    vm.runInContext(WRAPPED, ctx, { filename: "idb-guarded.js" });
    return ctx;
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

// No indexedDB on the origin → the engine installs a working IndexedDB surface.
try {
    const ctx = run({});
    assert.strictEqual(typeof ctx.indexedDB, "object", "indexedDB is installed");
    assert.strictEqual(typeof ctx.indexedDB.open, "function", "indexedDB.open is a function");
    assert.strictEqual(typeof ctx.IDBKeyRange, "function", "IDBKeyRange is installed");
    assert.strictEqual(typeof ctx.IDBDatabase, "function", "IDBDatabase is installed");
    ok("no-IDB page origin → in-memory IndexedDB engine installs");
} catch (e) { bad("installs when missing", e); }

// A real, working indexedDB must NOT be overridden.
try {
    const sentinel = { open: function () {}, __real: true };
    const ctx = run({ indexedDB: sentinel });
    assert.strictEqual(ctx.indexedDB.__real, true, "a working indexedDB is left untouched");
    ok("working IndexedDB → engine does not override it");
} catch (e) { bad("no-override", e); }

// The engine can actually open a database (open returns an IDBOpenDBRequest).
try {
    const ctx = run({});
    const req = ctx.indexedDB.open("__bb_test_db__", 1);
    assert.ok(req && typeof req === "object", "indexedDB.open returns a request object");
    assert.ok("onupgradeneeded" in req || "onsuccess" in req || "result" in req, "the request has the IDBOpenDBRequest shape");
    ok("indexedDB.open returns a usable request");
} catch (e) { bad("open works", e); }

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
