//
//  pageworld-opentab.test.js
//  BrownBear
//
//  Tests GM_openInTab in the PAGE world (brownbear-runtime.js pageWorldGMClient + the vault). A granted
//  page-world script opens a tab through the vault's minted-id streaming channel: vault.xhr(handler) mints
//  an unguessable id (which IS the openId), the client posts GM_openInTab with it and returns a REAL handle
//  ({ closed, onclose, close() }). When that tab later closes, native streams back via
//  window.__bbPageXHR(openId, "close") — routed to the registered handler — which flips handle.closed and
//  fires handle.onclose. close() posts GM_closeTab with the openId. Same minted-id machinery as the
//  page-world GM_xmlhttpRequest / GM_download / GM_registerMenuCommand. Tampermonkey/Violentmonkey parity.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-opentab.test.js`. Exits non-zero on any failure.
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

function bootForTabCode(source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-tab", name: "tab", uuid: "99999999-9999-9999-9999-999999999999",
                runAt: "document-start", grants: ["GM_openInTab"], grantNone: false, noFrames: false,
                injectInto: "auto", requires: [], resources: {}, source: source, values: {},
                info: { scriptHandler: "BrownBear" }
            }]);
        }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        return Promise.resolve(null);
    }
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, console, CustomEvent: function () {}
    };
    win.window = win; win.self = win; win.top = win;
    const document = { readyState: "complete", addEventListener() {} };
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(SRC, ctx);
    return calls;
}

function runPageWithVault(code) {
    const relayed = [];
    const handlers = {};
    let mintCount = 0;
    const vault = function (token, api, payload) { relayed.push({ token, api, payload }); return Promise.resolve(null); };
    vault.xhr = function (handler) { mintCount += 1; const id = "pwx_" + mintCount + "_d00dfeed"; handlers[id] = handler; return id; };
    vault.xhrDone = function (id) { delete handlers[id]; };
    const pageWin = {
        document: { head: { appendChild() {} }, documentElement: { appendChild() {} },
            createElement() { return { setAttribute() {}, appendChild() {} }; } },
        JSON, Object, Array, Promise, console, __obs: {}, __bbPageGM: vault
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageWin.document, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    return { pageWin, relayed,
             close: (id) => handlers[id] && handlers[id]("close", {}),
             isRegistered: (id) => !!handlers[id] };
}

function injectCode(calls) { return calls.filter((c) => c.api === "injectPageWorld")[0].payload.code; }

(async function main() {
    console.log("GM_openInTab in the page world (vault minted-id + native→page close)");

    const body = [
        "window.__obs.closed = false;",
        "window.__obs.h = GM_openInTab('https://example.org/x', { active: false });",
        "window.__obs.h.onclose = function () { window.__obs.closed = true; };",
        "window.__obs.closeIsFn = (typeof window.__obs.h.close === 'function');",
        "window.__obs.startClosed = window.__obs.h.closed;"
    ].join("\n");
    const calls = bootForTabCode(body);
    await new Promise((r) => setTimeout(r, 10));

    test("a granted GM_openInTab script routes to the page world", () => {
        assert.strictEqual(calls.filter((c) => c.api === "injectPageWorld").length, 1);
    });

    const { pageWin, relayed, close, isRegistered } = runPageWithVault(injectCode(calls));
    const obs = pageWin.__obs;

    // Find the openId the client minted (the request carries it).
    const open = relayed.filter((r) => r.api === "GM_openInTab")[0];

    test("the open request is relayed through the vault (token + url + active + minted openId)", () => {
        assert.ok(open, "one GM_openInTab relayed");
        assert.strictEqual(open.token, "tok-tab", "authenticated with the script's token");
        assert.strictEqual(open.payload.url, "https://example.org/x");
        assert.strictEqual(open.payload.active, false, "{active:false} opens in the background");
        assert.ok(/^pwx_/.test(open.payload.openId), "uses the vault-minted (unguessable) openId");
    });
    test("the returned handle starts open with a real close()", () => {
        assert.strictEqual(obs.startClosed, false, "handle.closed is false while the tab is open");
        assert.strictEqual(obs.closeIsFn, true, "handle.close is a function");
    });
    test("a streaming handler is registered for native to deliver the close to", () => {
        assert.ok(isRegistered(open.payload.openId), "vault.xhr registered a handler keyed by the openId");
    });

    // Native streams the tab close → handle flips closed + fires onclose + reaps the handler.
    close(open.payload.openId);
    test("a native close flips handle.closed, fires onclose, and reaps the handler", () => {
        assert.strictEqual(obs.closed, true, "onclose fired");
        assert.strictEqual(obs.h.closed, true, "handle.closed flipped");
        assert.ok(!isRegistered(open.payload.openId), "the streaming handler was reaped after close");
    });

    // close() relays GM_closeTab with the same openId.
    {
        const body2 = "var h = GM_openInTab('https://example.org/y'); h.close();";
        const calls2 = bootForTabCode(body2);
        await new Promise((r) => setTimeout(r, 10));
        const r2 = runPageWithVault(injectCode(calls2));
        const open2 = r2.relayed.filter((r) => r.api === "GM_openInTab")[0];
        test("handle.close() relays GM_closeTab with the openId", () => {
            assert.ok(r2.relayed.some((r) => r.api === "GM_closeTab" && r.payload.openId === open2.payload.openId),
                "GM_closeTab relayed with the same openId");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
