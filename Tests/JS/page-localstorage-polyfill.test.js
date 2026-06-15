//
//  page-localstorage-polyfill.test.js
//  BrownBear
//
//  WKWebView gives the chrome-extension:// PAGE origin no DOM storage, so window.localStorage is
//  undefined and a page that touches it throws "null is not an object" at init and never renders
//  (ScriptCat's editor: `localStorage.getItem` / `localStorage.lightMode = …`; Momentum:
//  `localStorage.firstSynchronized`). The page shim installs a synchronous Storage polyfill so those
//  pages run. This boots the REAL page shim over a window WITHOUT localStorage and asserts the polyfill
//  provides a working Storage — both the method API and direct property access — and that it does NOT
//  override a real, working localStorage.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/page-localstorage-polyfill.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const PAGE_SRC = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-page.js"), "utf8");
const ID = "dhdgffkkebhmkfjojejmpbldmpobfkfo";

// Boot the page shim over a minimal extension-page window. `realLocalStorage` (optional) installs a working
// Storage to verify the polyfill leaves it alone. `opts` can supply { seed } (the native localStorage
// rehydrate, window.__bb_ls_seed) and { onSave } (the native save sink, window.__bb_ls_save). Timers and
// event listeners are CAPTURED (not run), so the debounced flush + pagehide force-flush are deterministic:
// win.__runTimers() fires the debounce; win.__fire(type) dispatches a captured listener.
function bootPageShim(realLocalStorage, opts) {
    opts = opts || {};
    const win = {};
    win.window = win; win.self = win; win.globalThis = win;
    win.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    win.navigator = { language: "en-US", userAgent: "Mozilla/5.0", serviceWorker: undefined };
    win.location = new URL("chrome-extension://" + ID + "/options.html");
    win.URL = URL; win.JSON = JSON; win.Object = Object; win.Array = Array;
    win.Promise = Promise; win.Error = Error; win.Proxy = Proxy; win.Reflect = Reflect; win.Symbol = Symbol;
    win.structuredClone = (x) => JSON.parse(JSON.stringify(x));
    const timers = [];
    win.setTimeout = (fn) => { timers.push(fn); return timers.length; };
    win.clearTimeout = (id) => { if (id >= 1 && id <= timers.length) { timers[id - 1] = null; } };
    const listeners = {};
    win.addEventListener = (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); };
    win.removeEventListener = function () {}; win.dispatchEvent = function () { return false; };
    win.document = { addEventListener: function () {}, removeEventListener: function () {},
                     readyState: "complete", currentScript: null, visibilityState: "visible" };
    win.fetch = undefined;
    win.webkit = { messageHandlers: { brownbearWebext: { postMessage: function () { return Promise.resolve({}); } } } };
    if (realLocalStorage) { win.localStorage = realLocalStorage; }
    if (opts.seed) { win.__bb_ls_seed = opts.seed; }
    if (opts.onSave) { win.__bb_ls_save = opts.onSave; }
    win.__bbExtPage = {
        token: "tok-test", extensionId: ID, baseURL: "chrome-extension://" + ID + "/",
        manifestJSON: JSON.stringify({ manifest_version: 3, name: "t", version: "1" }), messages: {}
    };
    vm.createContext(win);
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js" });
    win.__runTimers = () => { const t = timers.splice(0); for (const fn of t) { if (fn) { fn(); } } };
    win.__fire = (type) => { (listeners[type] || []).forEach((fn) => fn()); };
    return win;
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

// No localStorage on the origin → the shim installs a working polyfill.
try {
    const win = bootPageShim();
    const ls = win.localStorage;
    assert.ok(ls && typeof ls.getItem === "function", "localStorage polyfill is installed");
    // method API
    assert.strictEqual(ls.getItem("missing"), null, "getItem of a missing key returns null (not undefined)");
    ls.setItem("a", "1");
    assert.strictEqual(ls.getItem("a"), "1", "setItem/getItem round-trips");
    ls.setItem("n", 42);
    assert.strictEqual(ls.getItem("n"), "42", "values are coerced to strings (per spec)");
    ok("method API: getItem/setItem round-trip + string coercion");
} catch (e) { bad("method API", e); }

// Direct property access — ScriptCat does `localStorage.lightMode = …`.
try {
    const win = bootPageShim();
    const ls = win.localStorage;
    ls.lightMode = "dark";
    assert.strictEqual(ls.getItem("lightMode"), "dark", "property set is visible via getItem");
    assert.strictEqual(ls.lightMode, "dark", "property get reflects the stored value");
    ls.setItem("viaApi", "yes");
    assert.strictEqual(ls.viaApi, "yes", "setItem is visible via property access");
    ok("direct property access (localStorage.lightMode = …) works");
} catch (e) { bad("property access", e); }

// length / key / removeItem / clear / enumeration.
try {
    const win = bootPageShim();
    const ls = win.localStorage;
    ls.setItem("x", "1"); ls.setItem("y", "2");
    assert.strictEqual(ls.length, 2, "length reflects item count");
    assert.ok([ls.key(0), ls.key(1)].sort().join() === "x,y", "key(i) enumerates the stored keys");
    assert.deepStrictEqual(Object.keys(ls).sort(), ["x", "y"], "Object.keys enumerates the items");
    ls.removeItem("x");
    assert.strictEqual(ls.getItem("x"), null, "removeItem deletes the key");
    assert.strictEqual(ls.length, 1, "length drops after removeItem");
    ls.clear();
    assert.strictEqual(ls.length, 0, "clear empties the store");
    ok("length / key / removeItem / clear / Object.keys");
} catch (e) { bad("length/key/remove/clear", e); }

// PERSISTENCE: localStorage seeds from native's last snapshot (window.__bb_ls_seed) so the first
// synchronous read already sees prior writes — without this, every page-load started empty ("reads don't work").
try {
    const win = bootPageShim(null, { seed: { foo: "bar", n: "42" } });
    const ls = win.localStorage;
    assert.strictEqual(ls.getItem("foo"), "bar", "seed value readable immediately (synchronous rehydrate)");
    assert.strictEqual(ls.n, "42", "seed value readable via property access");
    assert.strictEqual(ls.length, 2, "length reflects the seeded items");
    ok("localStorage seeds from window.__bb_ls_seed");
} catch (e) { bad("seed", e); }

// A write hands a debounced full-store snapshot back to native (window.__bb_ls_save).
try {
    const saved = [];
    const win = bootPageShim(null, { onSave: (j) => saved.push(j) });
    const ls = win.localStorage;
    ls.setItem("k", "v");
    assert.strictEqual(saved.length, 0, "write is debounced, not saved synchronously");
    win.__runTimers();
    assert.strictEqual(saved.length, 1, "the debounce flushes exactly one snapshot");
    assert.deepStrictEqual(JSON.parse(saved[0]), { k: "v" }, "snapshot is the full store, serialized");
    ok("setItem flushes a debounced snapshot to __bb_ls_save");
} catch (e) { bad("flush", e); }

// A burst of writes (incl. direct property + removeItem) coalesces into ONE native round-trip.
try {
    const saved = [];
    const win = bootPageShim(null, { onSave: (j) => saved.push(j) });
    const ls = win.localStorage;
    ls.setItem("a", "1"); ls.b = "2"; ls.setItem("c", "3"); ls.removeItem("a");
    win.__runTimers();
    assert.strictEqual(saved.length, 1, "a burst debounces into a single flush");
    assert.deepStrictEqual(JSON.parse(saved[0]), { b: "2", c: "3" }, "final snapshot reflects all mutations");
    ok("a burst of writes coalesces into one flush");
} catch (e) { bad("debounce-coalesce", e); }

// The popup may be torn down before the debounce fires — pagehide forces a final flush so the last write sticks.
try {
    const saved = [];
    const win = bootPageShim(null, { onSave: (j) => saved.push(j) });
    win.localStorage.setItem("late", "1");
    assert.strictEqual(saved.length, 0, "debounce still pending");
    win.__fire("pagehide");
    assert.strictEqual(saved.length, 1, "pagehide forces an immediate final flush");
    assert.deepStrictEqual(JSON.parse(saved[0]), { late: "1" }, "the last write is persisted on dismiss");
    ok("pagehide force-flushes the last write");
} catch (e) { bad("pagehide-flush", e); }

// sessionStorage is session-scoped — it must NOT be persisted to native.
try {
    const saved = [];
    const win = bootPageShim(null, { onSave: (j) => saved.push(j) });
    win.__runTimers(); saved.length = 0;   // drain the runtime's boot-time localStorage self-check flush
    win.sessionStorage.setItem("s", "1");
    win.__runTimers();
    assert.strictEqual(saved.length, 0, "sessionStorage writes are never sent to __bb_ls_save");
    assert.strictEqual(win.sessionStorage.getItem("s"), "1", "sessionStorage still works in-memory");
    ok("sessionStorage stays in-memory (not persisted)");
} catch (e) { bad("session-no-persist", e); }

// A real, working localStorage must NOT be overridden.
try {
    const backing = {};
    const real = {
        getItem: (k) => (k in backing ? backing[k] : null),
        setItem: (k, v) => { backing[k] = String(v); },
        removeItem: (k) => { delete backing[k]; },
        clear: () => { for (const k in backing) delete backing[k]; },
        key: () => null, get length() { return Object.keys(backing).length; },
        __real: true
    };
    const win = bootPageShim(real);
    assert.strictEqual(win.localStorage.__real, true, "a working localStorage is left untouched");
    ok("does not override a working localStorage");
} catch (e) { bad("no-override", e); }

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
