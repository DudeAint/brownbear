//
//  pageworld-menu.test.js
//  BrownBear
//
//  Tests GM_registerMenuCommand / GM_unregisterMenuCommand in the PAGE world (brownbear-runtime.js
//  pageWorldGMClient + the vault). A granted page-world script registers a command through the vault's
//  minted-id streaming channel: vault.xhr(handler) mints an unguessable id (which IS the command id), the
//  client posts GM_registerMenuCommand with it, and when the user taps the command native streams back via
//  window.__bbPageXHR(commandId, "menu") — routed to the registered handler, firing the script's callback.
//  The handler PERSISTS across taps until GM_unregisterMenuCommand reaps it (vault.xhrDone). Same minted-id
//  machinery as the page-world GM_xmlhttpRequest / GM_download. Tampermonkey/ScriptCat parity.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-menu.test.js`. Exits non-zero on any failure.
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

function bootForMenuCode(source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-menu", name: "menu", uuid: "88888888-8888-8888-8888-888888888888",
                runAt: "document-start", grants: ["GM_registerMenuCommand", "GM_unregisterMenuCommand"],
                grantNone: false, noFrames: false,
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

// Run the page-world source with a mock vault that records relayed writes and lets the test drive a native
// "menu" tap back through the registered handler (simulating window.__bbPageXHR(commandId, "menu")).
function runPageWithVault(code) {
    const relayed = [];
    const handlers = {};   // mintedId -> handler
    let mintCount = 0;
    const vault = function (token, api, payload) { relayed.push({ token, api, payload }); return Promise.resolve(null); };
    vault.xhr = function (handler) { mintCount += 1; const id = "pwx_" + mintCount + "_cafef00d"; handlers[id] = handler; return id; };
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
             tap: (id) => handlers[id] && handlers[id]("menu", {}),
             isRegistered: (id) => !!handlers[id] };
}

function injectCode(calls) { return calls.filter((c) => c.api === "injectPageWorld")[0].payload.code; }

(async function main() {
    console.log("GM_registerMenuCommand in the page world (vault minted-id + native→page tap)");

    const body = [
        "window.__obs.taps = 0;",
        "window.__obs.id = GM_registerMenuCommand('Do the thing', function () { window.__obs.taps += 1; }, 'D');"
    ].join("\n");
    const calls = bootForMenuCode(body);
    await new Promise((r) => setTimeout(r, 10));

    test("a granted GM_registerMenuCommand script routes to the page world", () => {
        assert.strictEqual(calls.filter((c) => c.api === "injectPageWorld").length, 1);
    });

    const { pageWin, relayed, tap, isRegistered } = runPageWithVault(injectCode(calls));
    const obs = pageWin.__obs;

    test("the command is registered through the vault with title + accessKey + autoClose", () => {
        const reg = relayed.filter((r) => r.api === "GM_registerMenuCommand");
        assert.strictEqual(reg.length, 1, "one GM_registerMenuCommand relayed");
        assert.strictEqual(reg[0].token, "tok-menu", "authenticated with the script's token");
        assert.strictEqual(reg[0].payload.title, "Do the thing");
        assert.strictEqual(reg[0].payload.accessKey, "D");
        assert.strictEqual(reg[0].payload.autoClose, true);
        assert.ok(/^pwx_/.test(reg[0].payload.commandId), "the command id is the vault-minted (unguessable) id");
    });
    test("GM_registerMenuCommand returns the (minted) command id to the script", () => {
        assert.ok(/^pwx_/.test(obs.id), "the script got its command id back");
    });
    test("a registered streaming handler exists for native to deliver taps to", () => {
        assert.ok(isRegistered(obs.id), "vault.xhr registered a handler keyed by the command id");
    });

    // Native streams a tap → the script's callback fires. Taps repeat (the handler PERSISTS).
    tap(obs.id);
    tap(obs.id);
    test("a native tap fires the script's callback, and it persists across taps", () => {
        assert.strictEqual(obs.taps, 2, "callback fired once per tap");
    });

    // Unregister reaps the handler and relays GM_unregisterMenuCommand.
    {
        const body2 = [
            "var id = GM_registerMenuCommand('X', function () { window.__obs.x = (window.__obs.x||0)+1; });",
            "GM_unregisterMenuCommand(id);"
        ].join("\n");
        const calls2 = bootForMenuCode(body2);
        await new Promise((r) => setTimeout(r, 10));
        const r2 = runPageWithVault(injectCode(calls2));
        const reg = r2.relayed.filter((r) => r.api === "GM_registerMenuCommand")[0];
        test("GM_unregisterMenuCommand relays through the vault and reaps the handler", () => {
            assert.ok(r2.relayed.some((r) => r.api === "GM_unregisterMenuCommand" &&
                r.payload.commandId === reg.payload.commandId), "GM_unregisterMenuCommand relayed with the id");
            assert.ok(!r2.isRegistered(reg.payload.commandId), "the streaming handler was reaped (xhrDone)");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
