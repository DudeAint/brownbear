//
//  page-mediasource-stub.test.js
//  BrownBear
//
//  WKWebView does not expose window.MediaSource on the chrome-extension:// PAGE origin (MSE is gated
//  off). MetaMask's bundled LavaMoat "SNOW" realm sandbox unconditionally tames window.MediaSource at
//  boot — it reads `window.MediaSource` and does `Object.setPrototypeOf(wrapper, window.MediaSource)`.
//  With MediaSource `undefined`, JSC throws "Prototype value can only be an object or null" and the
//  whole wallet UI aborts before render. brownbear-webext-page.js installs an inert MediaSource
//  constructor (when the platform lacks one) so the taming step sees a real object.
//
//  This boots the REAL page shim over a window WITHOUT MediaSource and asserts: (1) the stub is
//  installed as a function whose `.prototype` is a real object, (2) SNOW's exact taming sequence no
//  longer throws, (3) a platform that already HAS MediaSource is left untouched.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/page-mediasource-stub.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const PAGE_SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-page.js"), "utf8");
const ID = "mediasourcetestidaaaaaaaaaaaaaaaa";

// Minimal extension-page window that runs the page shim. `existingMediaSource` (optional) pre-installs
// a constructor to verify the shim leaves a working one alone.
function bootPageShim(existingMediaSource) {
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
    if (existingMediaSource) { win.MediaSource = existingMediaSource; }
    win.__bbExtPage = {
        token: "tok-test", extensionId: ID, baseURL: "chrome-extension://" + ID + "/",
        manifestJSON: JSON.stringify({ manifest_version: 3, name: "t", version: "1" }), messages: {}
    };
    vm.createContext(win);
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js" });
    return win;
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

// No MediaSource on the origin → the shim installs an inert constructor with a real prototype.
try {
    const win = bootPageShim();
    assert.strictEqual(typeof win.MediaSource, "function", "MediaSource stub is installed as a function");
    assert.strictEqual(typeof win.MediaSource.prototype, "object", "the stub has a real .prototype object");
    assert.ok(win.MediaSource.prototype !== null, "prototype is non-null");
    ok("MediaSource stub installed when the platform lacks one");
} catch (e) { bad("stub installed", e); }

// SNOW's exact taming step must no longer throw "Prototype value can only be an object or null".
try {
    const win = bootPageShim();
    const wrapper = function MediaSource() { return undefined; };
    // SNOW: setPrototypeOf(wrapper, window.MediaSource) then defineProperty(orig.prototype, "constructor", …)
    Object.setPrototypeOf(wrapper, win.MediaSource);                     // would throw if MediaSource were undefined
    Object.defineProperty(win.MediaSource.prototype, "constructor", { value: wrapper, configurable: true });
    assert.strictEqual(Object.getPrototypeOf(wrapper), win.MediaSource, "wrapper's prototype is the stub");
    ok("SNOW taming sequence (setPrototypeOf + constructor) does not throw");
} catch (e) { bad("SNOW taming", e); }

// A genuine MSE use still fails honestly (we don't pretend to support streaming media).
try {
    const win = bootPageShim();
    let threw = false;
    try { new win.MediaSource(); } catch (e) { threw = /not supported/.test(String(e && e.message)); }
    assert.ok(threw, "constructing the stub throws an honest 'not supported' error");
    ok("constructing the inert MediaSource fails honestly");
} catch (e) { bad("honest failure", e); }

// A platform that already exposes a working MediaSource is left untouched.
try {
    const real = function MediaSource() {};
    real.__real = true;
    const win = bootPageShim(real);
    assert.strictEqual(win.MediaSource, real, "an existing MediaSource is not overridden");
    ok("existing MediaSource is left alone");
} catch (e) { bad("leave existing alone", e); }

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
