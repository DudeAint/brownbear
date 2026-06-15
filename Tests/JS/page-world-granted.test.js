//
//  page-world-granted.test.js
//  BrownBear
//
//  Tests the page-world execution path for GRANTED userscripts (brownbear-runtime.js). Violentmonkey
//  parity: a granted script whose grants are all page-world-SAFE runs in the page's REAL main world, so
//  `unsafeWindow === window` and the page's own globals are visible, while its GM_* surface works. The
//  page-world-safe set is the GM surface that touches ONLY the script's own data:
//    • value/resource READS — served SYNCHRONOUSLY from a cache pre-seeded into the page-world closure
//      (GM_getValue/listValues/getValues, GM_getResourceText/URL);
//    • DOM-local GM_addStyle / GM_addElement — run on the page document directly;
//    • own-data WRITES (GM_setValue/deleteValue/setValues/deleteValues/GM_setClipboard/GM_log) — update
//      the page-local cache synchronously, then persist to native via the document-start VAULT's
//      `window.__bbPageGM(token, api, payload)` (a pristine, page-unreadable, non-configurable bridge to
//      the RESTRICTED native brownbearPage handler).
//  A script granting a cross-origin/streaming API (GM_xmlhttpRequest, cookies, downloads, notifications,
//  menu/tab) keeps running in the ISOLATED world.
//
//  Security pinned here: writes flow ONLY through window.__bbPageGM (never a forgeable shared-DOM relay);
//  the token lives in the page-world closure, used only to authenticate to native via the pristine vault.
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

// Execute the injected page-world source in a PAGE context. Installs a mock window.__bbPageGM (the vault
// bridge) that records the (token, api, payload) of every persisted write. Returns the page window, the
// created elements, and the recorded vault writes.
function runPageSource(code) {
    const styleEls = [];
    const vaultWrites = [];
    const pageDoc = {
        head: { appendChild(n) { styleEls.push(n); return n; } },
        documentElement: { appendChild(n) { styleEls.push(n); return n; } },
        createElement(tag) { return { tagName: tag, textContent: "", attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, appendChild(n) { return n; } }; }
    };
    const pageWin = {
        document: pageDoc, JSON, Object, Array, Promise, console, __obs: {},
        __bbPageGM: function (token, api, payload) { vaultWrites.push({ token, api, payload }); return Promise.resolve(null); },
        // The page-world client must NOT reach native directly; only the vault (__bbPageGM) may.
        webkit: { messageHandlers: { brownbearPage: { postMessage(m) { vaultWrites.push({ DIRECT: m }); } } } }
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageDoc, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(code, ctx);
    return { pageWin, styleEls, vaultWrites };
}

function scriptData(overrides) {
    return Object.assign({
        token: "tok-SECRET-abc",
        name: "Granted Script",
        uuid: "22222222-2222-2222-2222-222222222222",
        runAt: "document-start",
        grants: ["GM_getValue", "GM_setValue", "GM_addStyle"],
        grantNone: false,
        noFrames: false,
        injectInto: "auto",   // VM default: granted page/auto scripts run in the page world
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
    console.log("page-world granted execution (reads page-local, writes via the pristine vault)");

    // ============ ROUTING ============
    {
        const calls = await bootAndInject({ grants: ["GM_getValue", "GM_setValue", "GM_addStyle"] });   // injectInto: "auto"
        const injects = injectCalls(calls);
        test("granted + only page-safe grants (auto, the VM default) → page-world (one injectPageWorld)", () => {
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
            assert.ok(/GM_getValue/.test(m[1]) && /GM_setValue/.test(m[1]) && /GM_addStyle/.test(m[1]),
                "granted names present as params");
            assert.ok(!/GM_xmlhttpRequest|GM_deleteValue\b/.test(m[1]), "non-granted names absent");
        });
        test("writes go through the vault (__bbPageGM), NOT a forgeable shared-DOM relay", () => {
            const code = injects[0].payload.code;
            assert.ok(code.indexOf("__bbPageGM") !== -1, "client uses the vault bridge");
            assert.ok(code.indexOf("messageHandlers") === -1, "client never touches native handlers directly");
            // The ONLY dispatchEvent in the client is the SPA 'urlchange' notification fired OUT to the
            // script (window.onurlchange parity) — never a write channel TO native. Assert every
            // dispatchEvent is that urlchange event, so no forgeable custom-event DOM relay can sneak in.
            const dispatches = (code.match(/dispatchEvent\s*\(/g) || []).length;
            const urlchange = (code.match(/dispatchEvent\(\s*new _CE\(\s*"urlchange"/g) || []).length;
            assert.strictEqual(dispatches, urlchange,
                "the only dispatchEvent is the urlchange notification, not a DOM write relay");
        });
    }
    {
        // VM parity: an explicit @inject-into page also routes to the page world (same as auto).
        const calls = await bootAndInject({ injectInto: "page", grants: ["GM_getValue", "GM_addStyle"] });
        test("explicit @inject-into page → page-world too (same as auto)", () => {
            assert.strictEqual(injectCalls(calls).length, 1);
        });
    }
    {
        const calls = await bootAndInject({ injectInto: "auto", grants: ["GM_xmlhttpRequest"] });
        test("GM_xmlhttpRequest now routes to the page world (request via vault, response native→page)", () => {
            assert.strictEqual(injectCalls(calls).length, 1);
        });
    }
    {
        const calls = await bootAndInject({ injectInto: "auto", grants: ["GM_download"] });
        test("a still-callback-streaming grant (GM_download) keeps the script ISOLATED", () => {
            assert.strictEqual(injectCalls(calls).length, 0);
        });
    }
    {
        // Request→reply APIs (GM_cookie + GM_getTab/saveTab/listTabs) are page-world-safe.
        const calls = await bootAndInject({ injectInto: "auto", grants: ["GM_cookie", "GM_getTab", "GM_listTabs"] });
        test("GM_cookie + GM_getTab/listTabs route to the page world (reply via the pristine vault .then)", () => {
            assert.strictEqual(injectCalls(calls).length, 1);
        });
    }
    {
        // The owner's reported failing script: @grant unsafeWindow + GM_addValueChangeListener (plus the
        // already-safe value/style/xhr grants). `unsafeWindow` is a DECLARATION (the canonical "I want the
        // real page window") and value-change listeners are page-local — both must be page-world-safe so
        // this whole script runs in the page world (unsafeWindow === page window), like VM.
        const ownerGrants = ["GM_xmlhttpRequest", "GM_addStyle", "GM_setValue", "GM_getValue",
                             "GM_deleteValue", "GM_listValues", "GM_addValueChangeListener", "unsafeWindow"];
        const calls = await bootAndInject({ injectInto: "auto", runAt: "document-start", grants: ownerGrants });
        const injects = injectCalls(calls);
        test("@grant unsafeWindow + GM_addValueChangeListener (+value/style/xhr) → PAGE world (the owner's case)", () => {
            assert.strictEqual(injects.length, 1, "the whole script runs in the page world");
        });
        test("…and `unsafeWindow` is NOT duplicated in the body param list (it's already a fixed param)", () => {
            const code = injects[0].payload.code;
            const m = /function \(unsafeWindow, GM, GM_info, console, window([^)]*)\) \{/.exec(code);
            assert.ok(m, "body wrapper present");
            assert.ok(m[1].indexOf("unsafeWindow") === -1, "unsafeWindow must not appear again in the granted params");
            assert.ok(/GM_addValueChangeListener/.test(m[1]), "GM_addValueChangeListener is passed as a param");
        });
    }
    {
        const calls = await bootAndInject({ injectInto: "content", grants: ["GM_getValue", "GM_setValue"] });
        test("@inject-into content stays isolated even with only safe grants", () => {
            assert.strictEqual(injectCalls(calls).length, 0);
        });
    }

    // ============ END-TO-END: page-local reads + DOM + vaulted writes ============
    {
        const body = [
            "window.__obs.unsafeIsWindow = (unsafeWindow === window);",
            "window.__obs.readCount = GM_getValue('count', 0);",       // pre-seeded sync read
            "var fired = [];",
            "GM.addValueChangeListener('count', function (k, o, n, remote) { fired.push([k, o, n, remote]); });",
            "GM_setValue('count', 8);",                                // write: cache + listener + vault
            "window.__obs.afterWrite = GM_getValue('count');",         // cache reflects the write synchronously
            "window.__obs.fired = fired;",
            "window.__obs.styleTag = GM_addStyle('body{color:red}').tagName;",
            "console.warn('page-world says', 99);"                     // must forward to Logs via the vault
        ].join("\n");
        const calls = await bootAndInject({
            grants: ["GM_getValue", "GM_setValue", "GM_addStyle"], source: body
        });
        const code = injectCalls(calls)[0].payload.code;
        const { pageWin, styleEls, vaultWrites } = runPageSource(code);
        const obs = pageWin.__obs;

        test("unsafeWindow === window in the page world", () => { assert.strictEqual(obs.unsafeIsWindow, true); });
        test("GM_getValue serves the pre-seeded cache synchronously", () => { assert.strictEqual(obs.readCount, 7); });
        test("GM_setValue updates the page-local cache synchronously (sync read parity)", () => {
            assert.strictEqual(obs.afterWrite, 8);
        });
        test("a same-context value-change listener fires on the write", () => {
            assert.strictEqual(JSON.stringify(obs.fired), JSON.stringify([["count", 7, 8, false]]));
        });
        test("GM_addStyle creates a <style> on the page document", () => {
            assert.strictEqual(obs.styleTag, "style");
            assert.strictEqual(styleEls.length, 1);
        });
        test("the write was persisted via the vault with the token + JSON-encoded value", () => {
            const w = vaultWrites.filter((v) => v.api === "GM_setValue");
            assert.strictEqual(w.length, 1, "exactly one vaulted GM_setValue");
            assert.strictEqual(w[0].token, "tok-SECRET-abc", "authenticated with the script's token");
            assert.strictEqual(w[0].payload.key, "count");
            assert.strictEqual(w[0].payload.value, "8", "value is JSON-encoded");
        });
        test("the page-world client never posted to a native handler directly (only via the vault)", () => {
            assert.ok(!vaultWrites.some((v) => v.DIRECT), "no direct webkit.messageHandlers post");
        });
        test("console.* forwards to the dashboard Logs through the vault (no debugging regression)", () => {
            const logs = vaultWrites.filter((v) => v.api === "log");
            assert.ok(logs.some((v) => v.payload.level === "warn" && v.payload.message === "page-world says 99"),
                "console.warn relayed as a token-bound log: " + JSON.stringify(logs));
            assert.strictEqual(logs[0].token, "tok-SECRET-abc", "log is authenticated with the script's token");
        });
    }

    // ============ graceful when the vault is absent (handler unavailable) ============
    {
        const body = "GM_setValue('count', 9); window.__obs.afterWrite = GM_getValue('count');";
        const calls = await bootAndInject({ grants: ["GM_getValue", "GM_setValue"], source: body });
        const code = injectCalls(calls)[0].payload.code;
        // Run WITHOUT installing window.__bbPageGM — the client must not throw; the cache still updates.
        const pageDoc = { head: { appendChild() {} }, documentElement: { appendChild() {} },
            createElement() { return { textContent: "", setAttribute() {}, appendChild() {} }; } };
        const pageWin = { document: pageDoc, JSON, Object, Array, Promise, console, __obs: {} };
        pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
        const ctx = { window: pageWin, document: pageDoc, console, globalThis: undefined };
        ctx.globalThis = ctx; vm.createContext(ctx); vm.runInContext(code, ctx);
        test("no vault installed → write is a no-op to native but the page-local cache still updates (no throw)", () => {
            assert.strictEqual(pageWin.__obs.afterWrite, 9);
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
