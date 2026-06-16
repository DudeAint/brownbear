//
//  page-scuttle-survival.test.js
//  BrownBear
//
//  A hardened bundle (MetaMask via LavaMoat's scuttleGlobalThis) walks every own window property at
//  boot and replaces each non-allowlisted one with a THROWING accessor — IF it is configurable; a
//  throwing Proxy IF non-configurable-but-writable; and SKIPS it only when it is BOTH non-configurable
//  AND non-writable (`if (desc.writable !== true) return`). BrownBear's native→page bridge global
//  `window.__brownbearExtPage` used to be a plain (configurable) assignment, so it was scuttled into a
//  getter that threw "property … is inaccessible under scuttling mode" the instant native evaluated
//  `window.__brownbearExtPage.dispatchX(...)` — killing every push into the wallet UI (the exact
//  MetaMask device failure). The fix defines it (and __brownbearExtPageReady) as non-configurable,
//  non-writable own data properties so the scuttle SKIPS them — the same reason `chrome`/`browser`
//  survive.
//
//  This boots the REAL page shim, replays LavaMoat's scuttle branch VERBATIM over the page window, and
//  asserts the bridge survives (a control plain property is proven to get scuttled, so the replay is
//  faithful and the test would fail without the fix).
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/page-scuttle-survival.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const PAGE_SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-page.js"), "utf8");
const ID = "scuttletestidaaaaaaaaaaaaaaaaaaaa";

function bootPageShim() {
    const win = {};
    win.window = win; win.self = win; win.globalThis = win;
    win.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    win.navigator = { language: "en-US", userAgent: "Mozilla/5.0", serviceWorker: undefined };
    win.location = new URL("chrome-extension://" + ID + "/popup.html");
    win.URL = URL; win.JSON = JSON; win.Object = Object; win.Array = Array;
    win.Promise = Promise; win.Error = Error; win.TypeError = TypeError;
    win.Proxy = Proxy; win.Reflect = Reflect; win.Symbol = Symbol;
    win.structuredClone = (x) => JSON.parse(JSON.stringify(x));
    win.setTimeout = () => 0; win.clearTimeout = () => {};
    win.addEventListener = () => {}; win.removeEventListener = () => {}; win.dispatchEvent = () => false;
    win.document = { addEventListener() {}, removeEventListener() {}, readyState: "complete",
                     currentScript: null, visibilityState: "visible" };
    win.fetch = undefined;
    win.webkit = { messageHandlers: { brownbearWebext: { postMessage: () => Promise.resolve({}) } } };
    win.__bbExtPage = {
        token: "tok-test", extensionId: ID, baseURL: "chrome-extension://" + ID + "/",
        manifestJSON: JSON.stringify({ manifest_version: 3, name: "t", version: "1" }), messages: {}
    };
    vm.createContext(win);
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js" });
    return win;
}

// A faithful replay of LavaMoat scuttleGlobalThis's per-property branch (MetaMask runtime chunk):
//   configurable        -> throwing getter
//   non-config, writable -> throwing Proxy value
//   non-config, non-writable -> SKIP (left untouched)   <-- the survival path
// `exceptions` are property names left alone (LavaMoat allowlist); we keep it minimal so our globals
// are NOT excepted — survival must come from the descriptor, not an allowlist.
function scuttle(win, exceptions) {
    const except = new Set(exceptions || []);
    for (const name of Object.getOwnPropertyNames(win)) {
        if (except.has(name)) { continue; }
        const desc = Object.getOwnPropertyDescriptor(win, name);
        if (!desc) { continue; }
        const thrower = { get() { throw new Error('property "' + name + '" of globalThis is inaccessible under scuttling mode.'); },
                          set() { throw new Error('property "' + name + '" cannot be set under scuttling mode.'); } };
        let next;
        if (desc.configurable === true) {
            next = { configurable: false, get: thrower.get, set: thrower.set };
        } else {
            if (desc.writable !== true) { continue; }   // the SKIP branch
            next = { configurable: false, writable: false,
                     value: new Proxy(function () {}, { get: thrower.get, apply: thrower.get }) };
        }
        try { Object.defineProperty(win, name, next); } catch (e) { /* built-in non-config; ignore */ }
    }
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

// The fix installs the bridge as a non-configurable, non-writable, non-enumerable own data property.
try {
    const win = bootPageShim();
    const d = Object.getOwnPropertyDescriptor(win, "__brownbearExtPage");
    assert.ok(d, "__brownbearExtPage exists");
    assert.strictEqual(d.configurable, false, "non-configurable");
    assert.strictEqual(d.writable, false, "non-writable");
    assert.strictEqual(d.enumerable, false, "non-enumerable");
    assert.strictEqual(typeof d.value.dispatchStorageChanged, "function", "bridge methods are present");
    const dr = Object.getOwnPropertyDescriptor(win, "__brownbearExtPageReady");
    assert.ok(dr && dr.configurable === false && dr.writable === false, "__brownbearExtPageReady is locked too");
    ok("bridge globals are installed as non-configurable, non-writable own data properties");
} catch (e) { bad("descriptor flags", e); }

// THE FIX: after a faithful scuttle, the native→page bridge is still readable and callable.
try {
    const win = bootPageShim();
    // a control plain-data property (configurable+writable) — must get scuttled, proving the replay works
    win.__bbControlPlain = { ping() { return "pong"; } };
    scuttle(win, []);
    // control: reading the scuttled plain property throws
    let controlThrew = false;
    try { void win.__bbControlPlain.ping; } catch (e) { controlThrew = /scuttling mode/.test(String(e && e.message)); }
    assert.ok(controlThrew, "the scuttle replay is faithful (a plain property gets a throwing getter)");
    // the fix: __brownbearExtPage survived and is still callable
    assert.strictEqual(typeof win.__brownbearExtPage, "object", "__brownbearExtPage survived scuttling");
    assert.strictEqual(typeof win.__brownbearExtPage.dispatchStorageChanged, "function",
        "native can still read window.__brownbearExtPage.dispatchX after scuttling");
    // native push still works end to end (deliver a storage change → no throw)
    win.__brownbearExtPage.dispatchStorageChanged("local", JSON.stringify({}));
    ok("__brownbearExtPage survives LavaMoat-style scuttling (the bridge keeps working)");
} catch (e) { bad("survives scuttle", e); }

// bfcache replay: re-running the document-start IIFE hits the __brownbearExtPageReady guard and must
// not throw (it would, if it tried to redefine the now-non-configurable property).
try {
    const win = bootPageShim();
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js#replay" });   // must not throw
    assert.strictEqual(win.__brownbearExtPageReady, true, "ready guard intact after replay");
    ok("re-running the page runtime (bfcache) hits the ready guard without redefining the locked prop");
} catch (e) { bad("bfcache replay", e); }

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
