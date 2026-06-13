//
//  page-object-url-polyfill.test.js
//  BrownBear
//
//  WebKit REFUSES URL.createObjectURL on a custom-scheme (chrome-extension://) PAGE origin — it throws a
//  TypeError ("createObjectURL@[native code]"). Tampermonkey's OFFSCREEN document turns a decoded
//  userscript Blob into an object URL exactly this way, so "import userscript from URL" hung forever at
//  the "Decoding…" popup. The page shim polyfills URL.createObjectURL/revokeObjectURL with an in-page
//  Blob Map and serves those URLs from its fetch wrapper, because consumers fetch the URL
//  (`fetch(objUrl).then(r => r.blob())` — TM's path) rather than requiring the literal blob: scheme.
//  This boots the REAL page shim over a window whose native createObjectURL throws (like WebKit) and
//  asserts: createObjectURL returns a blob:-shaped URL, fetch(url) yields the original bytes, revoke
//  frees it, and a non-Blob argument defers to the platform.
//
//  Pure Node (needs global Blob/Response — Node 18+). Run by CI (globs Tests/JS/*.test.js) and locally
//  with `node Tests/JS/page-object-url-polyfill.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const PAGE_SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-page.js"), "utf8");
const ID = "dhdgffkkebhmkfjojejmpbldmpobfkfo";

// A URL constructor that, like WebKit on a custom-scheme origin, THROWS from the native createObjectURL.
class ThrowingURL extends URL {}
let nativeCreateCalls = 0;
ThrowingURL.createObjectURL = function () {
    nativeCreateCalls += 1;
    throw new TypeError("createObjectURL@[native code]");
};
let nativeRevokeCalls = 0;
ThrowingURL.revokeObjectURL = function () { nativeRevokeCalls += 1; };

// Boot the page shim over a minimal extension-page window with a throwing native createObjectURL.
function bootPageShim() {
    const win = {};
    win.window = win; win.self = win; win.globalThis = win;
    win.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    win.navigator = { language: "en-US", userAgent: "Mozilla/5.0", serviceWorker: undefined };
    win.location = new URL("chrome-extension://" + ID + "/offscreen.html");
    win.URL = ThrowingURL; win.JSON = JSON; win.Object = Object; win.Array = Array;
    win.Promise = Promise; win.Error = Error; win.Proxy = Proxy; win.Reflect = Reflect; win.Symbol = Symbol;
    win.Map = Map; win.Blob = Blob; win.Response = Response; win.atob = atob;
    win.structuredClone = (x) => JSON.parse(JSON.stringify(x));
    win.setTimeout = setTimeout; win.clearTimeout = clearTimeout;
    win.addEventListener = function () {}; win.removeEventListener = function () {};
    win.dispatchEvent = function () { return false; };
    win.document = { addEventListener: function () {}, removeEventListener: function () {},
                     readyState: "complete", currentScript: null };
    // The native fetch the wrapper falls back to — distinguishable from an object-URL hit.
    win.fetch = function () { return Promise.resolve(new Response("NATIVE_FETCH")); };
    win.webkit = { messageHandlers: { brownbearWebext: { postMessage: function () { return Promise.resolve({}); } } } };
    win.__bbExtPage = {
        token: "tok-test", extensionId: ID, baseURL: "chrome-extension://" + ID + "/",
        manifestJSON: JSON.stringify({ manifest_version: 3, name: "t", version: "1" }), messages: {}
    };
    vm.createContext(win);
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js" });
    return win;
}

let passed = 0, failed = 0;

(async function main() {
    console.log("page object-URL polyfill tests");

    // createObjectURL on a Blob returns a blob:-shaped URL (does NOT call the throwing native).
    await (async () => {
        const win = bootPageShim();
        const before = nativeCreateCalls;
        const blob = new win.Blob(["hello userscript"], { type: "text/javascript" });
        const url = win.URL.createObjectURL(blob);
        assert.strictEqual(typeof url, "string");
        assert.ok(url.indexOf("blob:") === 0, "URL is blob:-shaped (consumer string-checks still pass): " + url);
        assert.strictEqual(nativeCreateCalls, before, "the throwing native createObjectURL was NOT invoked");
        console.log("  ok   createObjectURL(Blob) returns a blob: URL without hitting the throwing native");
        passed++;
    })().catch((e) => { console.log("  FAIL createObjectURL basic\n       " + e.message); failed++; });

    // fetch(objUrl) yields the ORIGINAL blob bytes — the exact path TM's decode does.
    await (async () => {
        const win = bootPageShim();
        const blob = new win.Blob(["// ==UserScript==\nconsole.log(1)"], { type: "text/javascript" });
        const url = win.URL.createObjectURL(blob);
        const res = await win.fetch(url);
        const text = await res.text();
        assert.strictEqual(text, "// ==UserScript==\nconsole.log(1)", "fetch(objUrl).text() returns the blob");
        const res2 = await win.fetch(url);
        const buf = await res2.blob();
        assert.strictEqual(await buf.text(), "// ==UserScript==\nconsole.log(1)", "fetch(objUrl).blob() round-trips");
        console.log("  ok   fetch(objUrl) returns the original Blob bytes (unblocks TM 'Decoding…')");
        passed++;
    })().catch((e) => { console.log("  FAIL fetch(objUrl)\n       " + e.message); failed++; });

    // revokeObjectURL frees it — a later fetch no longer resolves from the store (falls through to native).
    await (async () => {
        const win = bootPageShim();
        const blob = new win.Blob(["data"], { type: "text/plain" });
        const url = win.URL.createObjectURL(blob);
        win.URL.revokeObjectURL(url);
        const res = await win.fetch(url);
        const text = await res.text();
        assert.notStrictEqual(text, "data", "after revoke, the store no longer answers the URL");
        assert.strictEqual(text, "NATIVE_FETCH", "a revoked blob URL falls through to the platform fetch");
        console.log("  ok   revokeObjectURL frees the blob (fetch no longer serves it)");
        passed++;
    })().catch((e) => { console.log("  FAIL revokeObjectURL\n       " + e.message); failed++; });

    // A non-Blob argument defers to the platform (which here throws, like WebKit) — we don't mask it.
    await (async () => {
        const win = bootPageShim();
        const before = nativeCreateCalls;
        let threw = false;
        try { win.URL.createObjectURL({ notABlob: true }); } catch (e) { threw = true; }
        assert.ok(threw, "a non-Blob still hits the native (which throws on this origin)");
        assert.strictEqual(nativeCreateCalls, before + 1, "native createObjectURL was called for the non-Blob");
        console.log("  ok   non-Blob arg defers to the platform createObjectURL (no masking)");
        passed++;
    })().catch((e) => { console.log("  FAIL non-Blob defer\n       " + e.message); failed++; });

    // Let the async IIFEs settle, then report.
    await new Promise((r) => setTimeout(r, 30));
    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed === 0 ? 0 : 1);
})();
