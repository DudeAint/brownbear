//
//  content-scuttle-survival.test.js
//  BrownBear
//
//  All extensions' content scripts share ONE isolated content world. A content script that scuttles
//  globalThis (Phantom/MetaMask bundle LavaMoat's SNOW runs on EVERY web page) would replace
//  BrownBear's native→content push registry `globalThis.__bbExtContent` with a throwing getter — and
//  then native message/storage delivery (`window.__bbExtContent[token].onMessage(...)`) throws
//  "property __bbExtContent of globalThis is inaccessible under scuttling mode" for EVERY extension's
//  content scripts on that page. The fix locks `__bbExtContent` as a non-configurable, non-writable own
//  property on first creation so the scuttle skips it (LavaMoat skips a property only when it is both
//  non-configurable AND non-writable — the same reason `chrome` survives).
//
//  This boots the REAL content runtime, replays LavaMoat's scuttle branch over the world, and asserts
//  the registry survives and stays usable, while a control plain property is proven to get scuttled.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/content-scuttle-survival.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const JSDIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const runtimeSrc = fs.readFileSync(path.join(JSDIR, "brownbear-webext-runtime.js"), "utf8");

const EXT_ID = "scuttlecontenttestidaaaaaaaaaaaa1";
const BASE = `chrome-extension://${EXT_ID}/`;
const TOKEN = "tkn-scuttle-1";
const CONTENT_JS = "chrome.runtime.onMessage.addListener(function () {});";

function bootContentWorld() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb; sb.window = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp,
        Map, Set, Error, Function, TextEncoder, TextDecoder, URL, URLSearchParams, Reflect, Proxy });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout;
    sb.location = { href: "https://example.com/page", protocol: "https:", host: "example.com",
                    origin: "https://example.com" };
    sb.addEventListener = () => {}; sb.removeEventListener = () => {};
    sb.document = { readyState: "interactive", addEventListener: () => {}, removeEventListener: () => {},
                    documentElement: { appendChild() {} }, head: { appendChild() {} }, body: null,
                    createElement: () => ({ textContent: "", setAttribute() {}, style: {}, appendChild() {},
                                            get parentNode() { return null; } }), querySelector: () => null };
    sb.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => {
        if (msg.api === "getContentScripts") {
            return Promise.resolve([{ token: TOKEN, extensionId: EXT_ID, baseURL: BASE, manifestJSON: "{}",
                messages: {}, world: "ISOLATED", runAt: "document_start", js: CONTENT_JS }]);
        }
        return Promise.resolve(null);
    } } } };
    vm.createContext(sb);
    vm.runInContext(runtimeSrc, sb, { filename: "brownbear-webext-runtime.js" });
    return sb;
}

// Faithful replay of LavaMoat's per-property scuttle branch (configurable -> throwing getter;
// non-config+writable -> throwing Proxy; non-config+non-writable -> SKIP).
function scuttle(g) {
    for (const name of Object.getOwnPropertyNames(g)) {
        const desc = Object.getOwnPropertyDescriptor(g, name);
        if (!desc) { continue; }
        const get = () => { throw new Error('property "' + name + '" of globalThis is inaccessible under scuttling mode.'); };
        let next;
        if (desc.configurable === true) {
            next = { configurable: false, get, set: get };
        } else {
            if (desc.writable !== true) { continue; }
            next = { configurable: false, writable: false, value: new Proxy(function () {}, { get, apply: get }) };
        }
        try { Object.defineProperty(g, name, next); } catch (e) { /* built-in non-config; ignore */ }
    }
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    let passed = 0, failed = 0;
    const ok = (n) => { console.log("  ok   " + n); passed++; };
    const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

    const world = bootContentWorld();
    await delay(30);   // let getContentScripts resolve + the content session register

    try {
        const d = Object.getOwnPropertyDescriptor(world, "__bbExtContent");
        assert.ok(d, "__bbExtContent registry exists");
        assert.strictEqual(d.configurable, false, "non-configurable");
        assert.strictEqual(d.writable, false, "non-writable");
        assert.ok(world.__bbExtContent[TOKEN], "the content session is registered in the registry");
        ok("__bbExtContent is a non-configurable, non-writable own property with the session registered");
    } catch (e) { bad("descriptor + registration", e); }

    try {
        world.__bbControlPlain = { x: 1 };   // a plain property that MUST get scuttled (faithfulness check)
        scuttle(world);
        let controlThrew = false;
        try { void world.__bbControlPlain.x; } catch (e) { controlThrew = /scuttling mode/.test(String(e && e.message)); }
        assert.ok(controlThrew, "the scuttle replay is faithful (a plain property gets a throwing getter)");
        // the fix: the registry survived and native can still reach the session
        assert.strictEqual(typeof world.__bbExtContent, "object", "__bbExtContent survived scuttling");
        assert.strictEqual(typeof world.__bbExtContent[TOKEN].onMessage, "function",
            "native can still read window.__bbExtContent[token].onMessage after scuttling");
        ok("__bbExtContent survives LavaMoat-style scuttling (content message delivery keeps working)");
    } catch (e) { bad("survives scuttle", e); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
