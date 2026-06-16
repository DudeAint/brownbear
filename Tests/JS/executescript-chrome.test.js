//
//  executescript-chrome.test.js
//  BrownBear
//
//  chrome.scripting/tabs.executeScript injected code (e.g. a popup re-injecting content.js via
//  executeScript({files:['content.js']})) must run WITH the extension's `chrome` in scope — exactly like a
//  manifest content script. Natively it was eval'd RAW at the content world's global scope, where `chrome`
//  is undefined (it's a per-script closure var, never a real global), so a re-injected content.js threw
//  "Can't find variable: chrome" at its first chrome.* line. The fix: a content session's
//  window.__bbExtContent[token].runInjected(code) evals the code with that session's chrome/browser in
//  scope; native wraps executeScript content-world injections through it. This boots the REAL runtime,
//  registers a content session, and asserts runInjected exposes chrome (and keeps the eval's return value).
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/executescript-chrome.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const JSDIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const runtimeSrc = fs.readFileSync(path.join(JSDIR, "brownbear-webext-runtime.js"), "utf8");

const EXT_ID = "execscripttestidaaaaaaaaaaaaaaaa";
const BASE = `chrome-extension://${EXT_ID}/`;
const TOKEN = "tkn-exec-1";
// A manifest content script (registers an onMessage listener that READS chrome in its callback — the exact
// pattern that broke: chrome must still resolve when the listener runs later, not just at registration).
const CONTENT_JS = "chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {"
    + "  if (msg && msg.type === 'whoami') { sendResponse({ id: chrome.runtime.id }); }"
    + "});";

function bootContentWorld() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb; sb.window = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp,
        Map, Set, Error, Function, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout;
    sb.location = { href: "https://www.youtube.com/watch", protocol: "https:", host: "www.youtube.com",
                    origin: "https://www.youtube.com" };
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

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    let passed = 0, failed = 0;
    const ok = (n) => { console.log("  ok   " + n); passed++; };
    const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

    const world = bootContentWorld();
    await delay(30);   // let getContentScripts resolve + register the content session

    try {
        assert.ok(world.__bbExtContent && world.__bbExtContent[TOKEN], "the content session is registered");
        assert.strictEqual(typeof world.__bbExtContent[TOKEN].runInjected, "function",
            "the session exposes runInjected (native runs executeScript code through it)");
        ok("content session exposes runInjected");
    } catch (e) { bad("runInjected present", e); }

    // The core fix: code run through runInjected sees chrome (would be "Can't find variable: chrome" raw).
    try {
        const ri = world.__bbExtContent[TOKEN].runInjected;
        assert.strictEqual(ri("typeof chrome"), "object", "chrome is an object inside runInjected");
        assert.strictEqual(ri("typeof browser"), "object", "browser is also exposed");
        assert.strictEqual(ri("chrome.runtime.getURL('inpage.js')"), BASE + "inpage.js",
            "chrome.runtime.getURL resolves against the extension (chrome is the right extension's)");
        ok("runInjected exposes chrome/browser to injected code");
    } catch (e) { bad("chrome in scope", e); }

    // runInjected preserves the eval completion value (executeScript({func}) results).
    try {
        assert.strictEqual(world.__bbExtContent[TOKEN].runInjected("1 + 2"), 3, "the eval return value is preserved");
        ok("runInjected returns the injected code's value");
    } catch (e) { bad("return value", e); }

    // Re-injecting content.js-style code (registers an onMessage listener using chrome) must not throw, and
    // chrome must still resolve when that listener is invoked LATER (the original device failure mode).
    try {
        let threw = null;
        try { world.__bbExtContent[TOKEN].runInjected(CONTENT_JS); } catch (e) { threw = e; }
        assert.strictEqual(threw, null, "re-injecting content.js via runInjected does not throw on chrome");
        // Deliver a message; the listener reads chrome.runtime.id in its callback.
        let answered;
        const orig = world.webkit.messageHandlers.brownbearWebext.postMessage;
        world.webkit.messageHandlers.brownbearWebext.postMessage = (m) => {
            if (m.api === "runtime.messageResponse") { answered = m.payload && m.payload.value; }
            return orig(m);
        };
        world.__bbExtContent[TOKEN].onMessage({ type: "whoami" }, { id: EXT_ID }, "r-who");
        await delay(10);
        assert.ok(answered && answered.id === EXT_ID, "the re-injected listener's callback reads chrome.runtime.id fine");
        ok("a re-injected content.js listener keeps chrome in its deferred callback");
    } catch (e) { bad("re-inject listener", e); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
