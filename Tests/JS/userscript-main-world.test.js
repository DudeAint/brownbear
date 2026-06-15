//
//  userscript-main-world.test.js
//  BrownBear
//
//  Tests the native userscript runtime's world selection (brownbear-runtime.js). A WKContentWorld
//  isolated world has its OWN window/global object, so a userscript running there can't see the page's
//  own globals — `unsafeWindow`/`window` are the isolated window, not the page's. Tampermonkey parity:
//  a script with `@grant none` (or `@inject-into page`/`auto` with no grants) must run in the page's
//  REAL main world instead, where `window === unsafeWindow ===` the page window and its globals are
//  visible. The runtime achieves that by handing the wrapped source to native via an `injectPageWorld`
//  bridge call (native evaluates it in WKContentWorld.page — CSP-immune), rather than running it here
//  with `new Function`. A granted script keeps running in the isolated world (the GM bridge lives only
//  there). This asserts the routing decision and the page-world wrapper's shape.
//
//  Pure Node, no deps. Run by CI (`js-runtime` job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/userscript-main-world.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-runtime.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// Boot the runtime against a fresh mock page that reports exactly `scripts` from getScripts. Returns
// the recorded native bridge calls once the (async) getScripts → run() chain has fully settled.
async function boot(scripts) {
    const calls = [];           // every handler.postMessage({api, payload, token})
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") { return Promise.resolve(scripts); }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        return Promise.resolve(null);
    }
    const listeners = [];
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState: function () {}, replaceState: function () {} },
        location: { href: "https://example.com/page" },
        addEventListener: function (type, fn) { listeners.push([type, fn]); },
        removeEventListener: function () {},
        console: console,
        CustomEvent: function CustomEvent() {},
        dispatchEvent: function () { return true; }
    };
    win.window = win;
    win.self = win;
    win.top = win;            // main frame (not a subframe)
    const document = {
        readyState: "complete",   // so document-start AND document-end/idle scripts all run immediately
        addEventListener: function (type, fn) { listeners.push([type, fn]); }
    };
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    // Let the getScripts promise, run()'s loadRequires/loadResources Promise.all, and the
    // injectPageWorld bridge call all settle (microtasks + a macrotask turn).
    await new Promise((r) => setTimeout(r, 10));
    return calls;
}

// A minimal getScripts payload for one script. Mirrors ScriptMessageRouter.scriptPayload's shape.
function scriptData(overrides) {
    return Object.assign({
        token: "tok-" + Math.random().toString(36).slice(2),
        name: "Test Script",
        uuid: "11111111-1111-1111-1111-111111111111",
        runAt: "document-start",
        grants: [],
        grantNone: true,
        noFrames: false,
        injectInto: "auto",
        requires: [],
        resources: {},
        source: "var BB_MARKER = 42; window.__bbRan = BB_MARKER;",
        values: {},
        info: { uuid: "11111111-1111-1111-1111-111111111111", version: "5.0",
                script: { name: "Test Script", version: "1.0" } }
    }, overrides || {});
}

function injectCalls(calls) { return calls.filter((c) => c.api === "injectPageWorld"); }

(async function main() {
    console.log("userscript main-world (page-world) routing tests");

    // --- @grant none, @inject-into auto → PAGE world ---------------------------------------------
    {
        const calls = await boot([scriptData({ injectInto: "auto", grantNone: true })]);
        const injects = injectCalls(calls);
        test("@grant none + auto routes to the page world (one injectPageWorld call)", () => {
            assert.strictEqual(injects.length, 1, "expected exactly one injectPageWorld bridge call");
        });
        test("page-world wrapper aliases unsafeWindow to the page window and carries the source", () => {
            const code = injects[0].payload.code;
            assert.ok(/var unsafeWindow = window;/.test(code), "unsafeWindow === window");
            assert.ok(code.indexOf("var BB_MARKER = 42;") !== -1, "script source is embedded");
            assert.ok(/\.call\(window, unsafeWindow, GM, GM_info, window\)/.test(code),
                      "body invoked with the page window as this + args");
        });
        test("page-world inject carries the script token (native re-gates on a valid session)", () => {
            assert.strictEqual(typeof injects[0].token, "string");
            assert.ok(injects[0].token.length > 0);
        });
        test("GM_info is inlined as data (not the isolated GM object reference)", () => {
            const code = injects[0].payload.code;
            assert.ok(/var GM_info = \{/.test(code), "GM_info inlined as a JSON literal");
            assert.ok(code.indexOf("\"version\":\"5.0\"") !== -1 || code.indexOf("\"version\": \"5.0\"") !== -1,
                      "GM_info data is the native-supplied info");
        });
    }

    // --- @grant none, explicit @inject-into page → PAGE world ------------------------------------
    {
        const calls = await boot([scriptData({ injectInto: "page", grantNone: true })]);
        test("explicit @inject-into page + @grant none routes to the page world", () => {
            assert.strictEqual(injectCalls(calls).length, 1);
        });
    }

    // --- @inject-into content (even with grant none) → ISOLATED world (no page inject) -----------
    {
        const calls = await boot([scriptData({ injectInto: "content", grantNone: true })]);
        test("@inject-into content stays isolated (no injectPageWorld even with grant none)", () => {
            assert.strictEqual(injectCalls(calls).length, 0);
        });
    }

    // --- has a NON-page-safe grant → ISOLATED world regardless of inject-into ---------------------
    // (Scripts whose grants are all page-world-SAFE — including GM_xmlhttpRequest and GM_download — now run
    //  in the page world; see page-world-granted.test.js / pageworld-download.test.js. A still-callback-
    //  streaming grant like GM_notification keeps the script isolated, because its native→world callbacks
    //  aren't yet routed to the page world.)
    {
        const calls = await boot([scriptData({ injectInto: "auto", grantNone: false,
                                               grants: ["GM_notification"] })]);
        test("a GM_notification-granted script (auto) runs isolated — its callbacks aren't page-routed yet", () => {
            assert.strictEqual(injectCalls(calls).length, 0);
        });
    }
    {
        const calls = await boot([scriptData({ injectInto: "page", grantNone: false,
                                               grants: ["GM_notification"] })]);
        const logs = calls.filter((c) => c.api === "log");
        test("@inject-into page WITH a callback-streaming grant stays isolated", () => {
            assert.strictEqual(injectCalls(calls).length, 0, "no page inject");
        });
        test("…and surfaces a visible warning explaining why (not silently ignored)", () => {
            assert.ok(logs.some((c) => c.payload && c.payload.level === "warn" &&
                /@grant none|page-world-safe/.test(c.payload.message || "")),
                "a warn-level log explains the isolated fallback");
        });
    }

    // --- mixed batch: grant-none page-world + a GM_notification script that stays isolated -----------
    {
        const calls = await boot([
            scriptData({ name: "iso", injectInto: "content", grantNone: true,
                         source: "window.__iso = 1;" }),
            scriptData({ name: "pageworld", injectInto: "auto", grantNone: true,
                         source: "window.__pw = 2;" }),
            scriptData({ name: "granted", injectInto: "auto", grantNone: false,
                         grants: ["GM_notification"], source: "window.__g = 3;" })
        ]);
        const injects = injectCalls(calls);
        test("mixed batch: the grant-none page-world script is page-injected, the GM_notification one stays isolated", () => {
            assert.strictEqual(injects.length, 1, "only one injectPageWorld");
            assert.ok(injects[0].payload.code.indexOf("window.__pw = 2;") !== -1,
                      "it is the @grant-none/auto script");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed === 0 ? 0 : 1);
})();
