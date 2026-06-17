//
//  action-onusersettingschanged.test.js
//  BrownBear
//
//  chrome.action.onUserSettingsChanged on the extension-PAGE shim (brownbear-webext-page.js). Chrome 130+
//  fires this event with a UserSettingsChange object ({isOnToolbar}) when the user pins or unpins the
//  toolbar action button. A popup / service worker reads the event object at init time and calls
//  `.addListener` on it synchronously.
//
//  Regression: Sider ("Sider: Chat with all AI", difoiogjjojoaoomphldepapgpbgkhkb) registers
//  chrome.action.onUserSettingsChanged.addListener(...) at boot. The page shim's actionApi() exposed
//  getUserSettings() (the read counterpart) but NOT onUserSettingsChanged, so the read was `undefined`
//  → "Cannot read properties of undefined (reading 'addListener')" threw during the popup's top-level
//  script → the popup rendered blank. Fix: expose onUserSettingsChanged as an inert (spec-shaped) event.
//
//  iOS has no toolbar pin/unpin concept, so the event is correctly never dispatched — it exists only so
//  addListener/hasListener resolve without throwing, mirroring onShowSettings / windows.onCreated / etc.
//
//  Pure Node, no deps: boots the real page shim in a vm with the minimal document-start contract native
//  bakes into window.__bbExtPage. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/action-onusersettingschanged.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const PAGE_SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-page.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

/** Boot the page shim over a minimal extension-page window and return the assembled `window.chrome`. */
function bootPageShim(manifest) {
    const ID = "difoiogjjojoaoomphldepapgpbgkhkb";   // Sider's real id shape; value is irrelevant to the shim
    const win = {};
    win.window = win; win.self = win; win.globalThis = win;
    win.console = console;
    win.navigator = { language: "en-US", userAgent: "Mozilla/5.0", serviceWorker: undefined };
    win.location = new URL("chrome-extension://" + ID + "/popup.html");
    win.URL = URL; win.JSON = JSON; win.Object = Object; win.Array = Array;
    win.Promise = Promise; win.Error = Error;
    win.structuredClone = (typeof structuredClone === "function") ? structuredClone : (x) => JSON.parse(JSON.stringify(x));
    win.setTimeout = setTimeout; win.clearTimeout = clearTimeout;
    win.addEventListener = function () {}; win.removeEventListener = function () {}; win.dispatchEvent = function () { return false; };
    win.document = { addEventListener: function () {}, removeEventListener: function () {}, readyState: "complete", currentScript: null };
    win.fetch = undefined;   // skip the privileged cross-origin fetch wrapper (needs a real fetch)
    win.webkit = { messageHandlers: { brownbearWebext: { postMessage: function () { return Promise.resolve({}); } } } };
    win.__bbExtPage = {
        token: "tok-test",
        extensionId: ID,
        baseURL: "chrome-extension://" + ID + "/",
        manifestJSON: JSON.stringify(manifest || { manifest_version: 3, name: "t", version: "1", action: {} }),
        messages: {}
    };
    vm.createContext(win);
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js" });
    assert.ok(win.__brownbearExtPageReady === true, "page shim should mark itself ready");
    assert.ok(win.chrome && win.chrome.action, "page shim should expose chrome.action");
    return win.chrome;
}

function assertEvent(obj, name) {
    assert.ok(obj && typeof obj === "object", name + " should be an event object");
    assert.strictEqual(typeof obj.addListener, "function", name + ".addListener should be a function");
    assert.strictEqual(typeof obj.removeListener, "function", name + ".removeListener should be a function");
    assert.strictEqual(typeof obj.hasListener, "function", name + ".hasListener should be a function");
}

console.log("chrome.action.onUserSettingsChanged page-shim tests");

// Table-driven: the event must be a real, spec-shaped Event on BOTH chrome.action and chrome.browserAction
// (the MV2 alias popups still read). actionApi() backs both, so both must carry the event.
[
    ["chrome.action.onUserSettingsChanged", (c) => c.action.onUserSettingsChanged],
    ["chrome.browserAction.onUserSettingsChanged", (c) => c.browserAction && c.browserAction.onUserSettingsChanged]
].forEach(function (row) {
    const label = row[0], pick = row[1];
    test(label + " is a spec-shaped Event", function () {
        const c = bootPageShim();
        const ev = pick(c);
        assertEvent(ev, label);
    });
});

test("getUserSettings() still resolves to {isOnToolbar} (the read counterpart the event pairs with)", function () {
    const c = bootPageShim();
    return c.action.getUserSettings(function (s) {
        assert.ok(s && typeof s.isOnToolbar === "boolean", "getUserSettings must yield {isOnToolbar:boolean}");
    });
});

test("Sider's exact unguarded boot access no longer throws (popup boots instead of blanking)", function () {
    const c = bootPageShim();
    // Verbatim shape of Sider's init: chrome.action.onUserSettingsChanged.addListener(cb)
    assert.doesNotThrow(function () { c.action.onUserSettingsChanged.addListener(function () {}); },
        "action.onUserSettingsChanged.addListener must not throw at popup boot");
});

test("the event is inert: it registers/removes listeners but never fires them (no spurious callbacks)", function () {
    const c = bootPageShim();
    const ev = c.action.onUserSettingsChanged;
    let fired = false;
    const fn = function () { fired = true; };
    ev.addListener(fn);
    assert.strictEqual(ev.hasListener(fn), true, "listener should be tracked after addListener");
    ev.removeListener(fn);
    assert.strictEqual(ev.hasListener(fn), false, "listener should be gone after removeListener");
    assert.strictEqual(fired, false, "inert page event must never invoke its listeners (iOS has no pin/unpin)");
});

// Malformed input: makeEvent's addListener ignores non-function args (matches Chrome, which throws a
// TypeError for a non-function but must NOT crash our shim or register a phantom listener). A null/number
// arg must be a no-op that leaves the listener set empty — fail closed, never register garbage.
test("malformed addListener args are ignored (no phantom listener, no crash)", function () {
    const c = bootPageShim();
    const ev = c.action.onUserSettingsChanged;
    [undefined, null, 42, "nope", {}, []].forEach(function (bad) {
        assert.doesNotThrow(function () { ev.addListener(bad); }, "addListener(" + String(bad) + ") must not throw");
        assert.strictEqual(ev.hasListener(bad), false, "a non-function arg must not be registered as a listener");
    });
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
