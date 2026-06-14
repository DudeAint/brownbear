//
//  page-world-granted.test.js
//  BrownBear
//
//  Tests the page-world execution path for GRANTED userscripts (brownbear-runtime.js). Violentmonkey
//  parity for the common "read config + manipulate the page" script: a granted script whose grants are
//  all page-world-SAFE runs in the page's REAL main world, so `unsafeWindow === window` and the page's
//  own globals are visible, WITHOUT handing the page world any native authority. The page-world-safe set
//  is exactly the GM surface that touches only the script's own data and needs no native channel:
//    • value/resource READS — served SYNCHRONOUSLY from a cache pre-seeded into the page-world closure
//      (GM_getValue/listValues/getValues, GM_getResourceText/URL);
//    • DOM-local GM_addStyle / GM_addElement — run on the page document directly.
//  A script granting a WRITE (GM_setValue/deleteValue/setClipboard/log) or any cross-origin/streaming API
//  (GM_xmlhttpRequest, cookies, downloads, notifications, menu/tab) keeps running in the ISOLATED world —
//  a secure page-world write path requires native, document-start-vaulted support (separate change).
//
//  The security property this pins: the emitted page-world source carries NO token and opens NO channel
//  to native (no webkit.messageHandlers, no shared-DOM relay), so a hostile co-resident page script has
//  nothing to forge, snoop, or MITM. The script just runs in the page world and reads its own config.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/page-world-granted.test.js`. Exits non-zero on any failure.
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

// Boot the runtime in an isolated world that reports exactly `scripts` from getScripts. Returns the
// recorded native bridge calls (the injectPageWorld payload is the page-world source we then execute).
function bootIsolated(scripts) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") { return Promise.resolve(scripts); }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        return Promise.resolve(null);
    }
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState() {}, replaceState() {} },
        location: { href: "https://example.com/page" },
        addEventListener() {}, removeEventListener() {},
        console, CustomEvent: function () {}
    };
    win.window = win; win.self = win; win.top = win;
    const document = { readyState: "complete", addEventListener() {} };
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return calls;
}

// Execute the injected page-world source in a PAGE context (its own window/document). Records the native
// bridge handle so we can ASSERT the page world never touches it. Returns the page window + created els.
function runPageSource(code) {
    const styleEls = [];
    const nativeCalls = [];
    const pageDoc = {
        head: { appendChild(n) { styleEls.push(n); return n; } },
        documentElement: { appendChild(n) { styleEls.push(n); return n; } },
        createElement(tag) { return { tagName: tag, textContent: "", attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, appendChild(n) { return n; } }; }
    };
    const pageWin = {
        document: pageDoc, JSON, Object, Array, Promise, console, __obs: {},
        // If the page-world client ever tried to reach native, this would record it (it must NOT).
        webkit: { messageHandlers: {
            brownbear: { postMessage(m) { nativeCalls.push(m); return Promise.resolve(null); } },
            brownbearPage: { postMessage(m) { nativeCalls.push(m); return Promise.resolve(null); } }
        } }
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageDoc, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(code, ctx);
    return { pageWin, styleEls, nativeCalls };
}

function scriptData(overrides) {
    return Object.assign({
        token: "tok-SECRET-" + Math.random().toString(36).slice(2),
        name: "Granted Script",
        uuid: "22222222-2222-2222-2222-222222222222",
        runAt: "document-start",
        grants: ["GM_getValue", "GM_addStyle"],
        grantNone: false,
        noFrames: false,
        injectInto: "auto",
        requires: [],
        resources: {},
        source: "void 0;",
        values: { count: "7", name: "\"bob\"" },   // pre-seeded cache: key -> JSON string
        info: { uuid: "22222222-2222-2222-2222-222222222222", version: "5.0",
                script: { name: "Granted Script", version: "1.0" } }
    }, overrides || {});
}

function injectCalls(calls) { return calls.filter((c) => c.api === "injectPageWorld"); }

async function bootAndInject(overrides) {
    const calls = bootIsolated([scriptData(overrides)]);
    await new Promise((r) => setTimeout(r, 10));
    return calls;
}

(async function main() {
    console.log("page-world granted execution (read + DOM-local, no native authority in the page)");

    // ============ ROUTING ============
    {
        const calls = await bootAndInject({ grants: ["GM_getValue", "GM_addStyle"] });
        const injects = injectCalls(calls);
        test("granted + only page-safe READ grants (auto) → page-world (one injectPageWorld)", () => {
            assert.strictEqual(injects.length, 1);
        });
        test("the injected source carries the self-contained page-world client + unsafeWindow=window", () => {
            const code = injects[0].payload.code;
            assert.ok(code.indexOf("function pageWorldGMClient") !== -1, "client function inlined");
            assert.ok(/var unsafeWindow = W;/.test(code), "unsafeWindow === window inside the client");
        });
        test("the body function exposes ONLY the granted GM_* names as params (grant-gated)", () => {
            const code = injects[0].payload.code;
            const m = /function \(unsafeWindow, GM, GM_info, console, window([^)]*)\) \{/.exec(code);
            assert.ok(m, "body wrapper present");
            assert.ok(/GM_getValue/.test(m[1]) && /GM_addStyle/.test(m[1]), "granted names present as params");
            assert.ok(!/GM_setValue|GM_xmlhttpRequest|GM_deleteValue/.test(m[1]), "non-granted names absent");
        });
        test("the script TOKEN never appears in the page-world source", () => {
            assert.strictEqual(injects[0].payload.code.indexOf("tok-SECRET-"), -1);
        });
        test("the page-world source opens NO channel to native (no webkit / messageHandlers / relay)", () => {
            const code = injects[0].payload.code;
            assert.ok(code.indexOf("messageHandlers") === -1, "no native handler reference");
            assert.ok(code.indexOf("webkit") === -1, "no webkit reference");
            assert.ok(code.indexOf("dispatchEvent") === -1 && code.indexOf("setAttribute(\"data-bbgm") === -1,
                "no shared-DOM relay");
        });
    }
    {
        const calls = await bootAndInject({ injectInto: "auto", grants: ["GM_getValue", "GM_setValue"] });
        test("a WRITE grant (GM_setValue) keeps the script ISOLATED (no page inject)", () => {
            assert.strictEqual(injectCalls(calls).length, 0);
        });
    }
    {
        const calls = await bootAndInject({ injectInto: "auto", grants: ["GM_xmlhttpRequest"] });
        test("a cross-origin grant (GM_xmlhttpRequest) keeps the script ISOLATED", () => {
            assert.strictEqual(injectCalls(calls).length, 0);
        });
    }
    {
        const calls = await bootAndInject({ injectInto: "content", grants: ["GM_getValue"] });
        test("@inject-into content stays isolated even with only safe read grants", () => {
            assert.strictEqual(injectCalls(calls).length, 0);
        });
    }

    // ============ END-TO-END: page-local GM surface ============
    {
        const body = [
            "window.__obs.unsafeIsWindow = (unsafeWindow === window);",
            "window.__obs.windowIsPage = (window === this);",
            "window.__obs.readCount = GM_getValue('count', 0);",       // pre-seeded sync read
            "window.__obs.readMissing = GM_getValue('nope', 42);",     // default
            "window.__obs.keys = GM_listValues().sort();",
            "window.__obs.styleTag = GM_addStyle('body{color:red}').tagName;",
            "window.__obs.infoFrozen = Object.isFrozen(GM_info);",
            "window.__obs.handler = GM_info.scriptHandler;"
        ].join("\n");
        const calls = await bootAndInject({
            grants: ["GM_getValue", "GM_listValues", "GM_addStyle"], source: body
        });
        const code = injectCalls(calls)[0].payload.code;
        const { pageWin, styleEls, nativeCalls } = runPageSource(code);
        const obs = pageWin.__obs;

        test("unsafeWindow === window === the page window", () => {
            assert.strictEqual(obs.unsafeIsWindow, true);
            assert.strictEqual(obs.windowIsPage, true);
        });
        test("GM_getValue serves the pre-seeded cache synchronously (sync TM parity)", () => {
            assert.strictEqual(obs.readCount, 7);
            assert.strictEqual(obs.readMissing, 42);
        });
        test("GM_listValues returns the pre-seeded keys", () => {
            assert.strictEqual(JSON.stringify(obs.keys), JSON.stringify(["count", "name"]));
        });
        test("GM_addStyle creates a <style> on the page document", () => {
            assert.strictEqual(obs.styleTag, "style");
            assert.strictEqual(styleEls.length, 1);
            assert.strictEqual(styleEls[0].textContent, "body{color:red}");
        });
        test("GM_info is inlined and deep-frozen", () => {
            assert.strictEqual(obs.infoFrozen, true);
            assert.strictEqual(obs.handler, "BrownBear");
        });
        test("the page-world client made ZERO native calls (no authority leaked to the page)", () => {
            assert.strictEqual(nativeCalls.length, 0, "page world must not reach native: " + JSON.stringify(nativeCalls));
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
