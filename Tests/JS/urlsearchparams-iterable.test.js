//
//  urlsearchparams-iterable.test.js
//  BrownBear
//
//  The background shim polyfills URL / URLSearchParams (JSC has neither in a bare JSContext). This
//  asserts the URLSearchParams polyfill is ITERABLE — `[...params]` and `for…of` must yield
//  [key, value] pairs, the same as the platform default iterator.
//
//  Regression: ClearURLs' countFields does `[...new URL(url).searchParams].length` on every request.
//  The polyfill had keys/values/entries/forEach but no Symbol.iterator, so the spread threw
//  "Spread syntax requires …[Symbol.iterator] to be a function" and ClearURLs died at request time.
//
//  Pure Node. The shim only installs its polyfill when globalThis.URLSearchParams is absent, so we
//  boot it in a sandbox WITHOUT a native URL/URLSearchParams to exercise the polyfill path. Run by CI
//  (globs Tests/JS/*.test.js) and locally with `node Tests/JS/urlsearchparams-iterable.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SHIM = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-background.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// Boot the shim with NO native URL/URLSearchParams so its polyfills install.
const sandbox = {};
sandbox.globalThis = sandbox; sandbox.self = sandbox;
sandbox.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
sandbox.setTimeout = setTimeout; sandbox.clearTimeout = clearTimeout;
sandbox.setInterval = setInterval; sandbox.clearInterval = clearInterval;
Object.assign(sandbox, {
    JSON, Math, Object, Array, Error, Symbol, Promise, String, Number, Boolean, RegExp,
    encodeURIComponent, decodeURIComponent, TextEncoder, TextDecoder, Date,
});
const cb = function () { const a = arguments; const c = a[a.length - 1]; if (typeof c === "function") { try { c(JSON.stringify(null)); } catch (e) { /* noop */ } } };
for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set", "__bb_storage_remove",
    "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr", "__bb_action", "__bb_scripting",
    "__bb_permissions", "__bb_alarm_create", "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get",
    "__bb_alarm_get_all", "__bb_fetch"]) { sandbox[n] = cb; }
sandbox.__bb_set_timeout = (fn, ms, r) => r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0);
sandbox.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
sandbox.__bbBgExtId = "x"; sandbox.__bbBgBaseURL = "chrome-extension://x/";
sandbox.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1", background: { service_worker: "sw.js" } });
sandbox.__bbBgMessages = "{}"; sandbox.__bbUserAgent = "UA"; sandbox.__bbLanguage = "en-US";
vm.createContext(sandbox);
vm.runInContext(SHIM, sandbox, { filename: "brownbear-webext-background.js" });
const run = (expr) => vm.runInContext(expr, sandbox);

test("the shim's URLSearchParams polyfill is installed", () => {
    assert.strictEqual(run("typeof URLSearchParams"), "function");
});

test("[...new URLSearchParams(str)] yields [key, value] pairs (countFields path)", () => {
    assert.strictEqual(run('[...new URLSearchParams("a=1&b=2&a=3")].length'), 3, "spread must see every pair, incl. duplicates");
    assert.deepStrictEqual(JSON.parse(run('JSON.stringify([...new URLSearchParams("a=1&b=2")])')), [["a", "1"], ["b", "2"]]);
});

test("[...new URL(url).searchParams] works (ClearURLs countFields)", () => {
    assert.strictEqual(run('[...new URL("http://h/p?x=1&y=2").searchParams].length'), 2);
});

test("for…of over params iterates pairs", () => {
    assert.strictEqual(run('(()=>{let n=0;for(const p of new URLSearchParams("a=1&b=2&c=3")){n++;}return n;})()'), 3);
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
