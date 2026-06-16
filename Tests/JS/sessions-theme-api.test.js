//
//  sessions-theme-api.test.js
//  BrownBear
//
//  Firefox browser.sessions per-window/per-tab values + browser.theme, which the Sidebery extension
//  needs (its MV2 background page + sidebar both run the page runtime). sessions.getWindowValue was
//  missing entirely ("browser.sessions.getWindowValue is not a function") and theme.getCurrent/onUpdated
//  were absent. This boots the REAL page runtime with the native bridge backed by an in-memory store
//  (mirroring WebExtensionStorage's sessions namespace) and asserts the round-trip + Firefox semantics:
//  every window id collapses to one bucket, tab values key by tab id, an unset key resolves to UNDEFINED
//  (not null), and theme.getCurrent returns a valid (empty) theme object rather than throwing.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/sessions-theme-api.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const PAGE_SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-page.js"), "utf8");
const ID = "sessionsthemetestidaaaaaaaaaaaaa1";

// Boot the page shim with a native bridge that backs sessions.* against an in-memory map keyed exactly
// like WebExtensionStorage: "<scope:id>::<key>" → JSON string. Returns { win, store }.
function bootPageShim() {
    const store = {};   // sessions native store
    const bucketKey = (p) => (p.scope === "tab" ? "tab:" + p.id : "window:" + p.id) + "::" + p.key;
    const win = {};
    win.window = win; win.self = win; win.globalThis = win;
    win.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    win.navigator = { language: "en-US", userAgent: "Mozilla/5.0", serviceWorker: undefined };
    win.location = new URL("moz-extension://" + ID + "/sidebar.html");
    win.URL = URL; win.JSON = JSON; win.Object = Object; win.Array = Array;
    win.Promise = Promise; win.Error = Error; win.TypeError = TypeError;
    win.Proxy = Proxy; win.Reflect = Reflect; win.Symbol = Symbol;
    win.structuredClone = (x) => JSON.parse(JSON.stringify(x));
    win.setTimeout = (fn) => { fn(); return 0; }; win.clearTimeout = () => {};
    win.addEventListener = () => {}; win.removeEventListener = () => {}; win.dispatchEvent = () => false;
    win.document = { addEventListener() {}, removeEventListener() {}, readyState: "complete",
                     currentScript: null, visibilityState: "visible" };
    win.fetch = undefined;
    win.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => {
        const api = msg.api, p = msg.payload || {};
        if (api === "sessions.getValue") {
            const v = store[bucketKey(p)];
            return Promise.resolve(v === undefined ? null : v);
        }
        if (api === "sessions.setValue") { store[bucketKey(p)] = p.value; return Promise.resolve(null); }
        if (api === "sessions.removeValue") { delete store[bucketKey(p)]; return Promise.resolve(null); }
        return Promise.resolve(null);
    } } } };
    win.__bbExtPage = {
        token: "tok-test", extensionId: ID, baseURL: "moz-extension://" + ID + "/",
        manifestJSON: JSON.stringify({ manifest_version: 2, name: "t", version: "1" }), messages: {}
    };
    vm.createContext(win);
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js" });
    return { win, store };
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

(async () => {
    const { win } = bootPageShim();
    const browser = win.browser;   // browser === chrome
    assert.strictEqual(browser, win.chrome, "browser is the same object as chrome");

    // sessions methods exist (the missing-function crash).
    try {
        for (const m of ["getWindowValue", "setWindowValue", "removeWindowValue", "getTabValue", "setTabValue", "removeTabValue"]) {
            assert.strictEqual(typeof browser.sessions[m], "function", "sessions." + m + " is a function");
        }
        ok("browser.sessions.{get,set,remove}{Window,Tab}Value all exist");
    } catch (e) { bad("sessions methods exist", e); }

    // window value round-trips; an unset key is undefined (NOT null); WINDOW_ID_CURRENT and a concrete id
    // hit the SAME bucket (single-window normalization).
    try {
        assert.strictEqual(await browser.sessions.getWindowValue(1, "uniqWinId"), undefined, "unset → undefined");
        await browser.sessions.setWindowValue(1, "uniqWinId", "win-abc");
        assert.strictEqual(await browser.sessions.getWindowValue(1, "uniqWinId"), "win-abc", "round-trips a string");
        // a different window id (and WINDOW_ID_CURRENT = -2) read the SAME value (one bucket on iOS)
        assert.strictEqual(await browser.sessions.getWindowValue(-2, "uniqWinId"), "win-abc",
            "WINDOW_ID_CURRENT reads the same bucket as a concrete window id");
        await browser.sessions.setWindowValue(1, "activePanelId", { id: 7, nested: [1, 2] });
        assert.deepStrictEqual(await browser.sessions.getWindowValue(1, "activePanelId"), { id: 7, nested: [1, 2] },
            "round-trips a JSON object");
        await browser.sessions.removeWindowValue(1, "uniqWinId");
        assert.strictEqual(await browser.sessions.getWindowValue(1, "uniqWinId"), undefined, "removed → undefined");
        ok("window values round-trip + normalize + remove (Firefox semantics)");
    } catch (e) { bad("window values", e); }

    // tab values key by tab id (distinct buckets).
    try {
        await browser.sessions.setTabValue(11, "k", "v11");
        await browser.sessions.setTabValue(22, "k", "v22");
        assert.strictEqual(await browser.sessions.getTabValue(11, "k"), "v11", "tab 11");
        assert.strictEqual(await browser.sessions.getTabValue(22, "k"), "v22", "tab 22 is a distinct bucket");
        assert.strictEqual(await browser.sessions.getTabValue(33, "k"), undefined, "unset tab → undefined");
        ok("tab values key by tab id");
    } catch (e) { bad("tab values", e); }

    // theme.getCurrent returns a valid (empty) theme object; onUpdated is registerable; contextualIdentities inert.
    try {
        const t = await browser.theme.getCurrent();
        assert.ok(t && typeof t === "object" && ("colors" in t), "theme.getCurrent returns a theme object");
        assert.strictEqual(typeof browser.theme.onUpdated.addListener, "function", "theme.onUpdated is an event");
        browser.theme.onUpdated.addListener(() => {});   // must not throw
        const ids = await browser.contextualIdentities.query({});
        assert.ok(Array.isArray(ids) && ids.length === 0, "contextualIdentities.query resolves [] (no containers on iOS)");
        ok("theme.getCurrent/onUpdated + contextualIdentities.query are present and inert-safe");
    } catch (e) { bad("theme + contextualIdentities", e); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
