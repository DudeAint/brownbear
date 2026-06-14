//
//  pageworld-xhr.test.js
//  BrownBear
//
//  Tests GM_xmlhttpRequest in the PAGE world (brownbear-runtime.js pageWorldGMClient + the vault). A
//  granted page-world script's request goes out through the vault's non-configurable window.__bbPageGM to
//  the restricted brownbearPage handler (native runs the real request with @connect enforcement); native
//  streams lifecycle events BACK by evaluating window.__bbPageXHR(id, type, payload) in the page world —
//  a native→page eval, never a page-readable DOM channel, so a cross-origin response body can't be
//  snooped. The vault mints the request id with pristine crypto so a hostile page can't predict it. This
//  test drives that round-trip end to end and asserts the request relay + response shaping + abort.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-xhr.test.js`. Exits non-zero on any failure.
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

// Boot the isolated runtime → get the injectPageWorld source for a granted GM_xmlhttpRequest script.
function bootForXHRCode(source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-xhr", name: "xhr", uuid: "44444444-4444-4444-4444-444444444444",
                runAt: "document-start", grants: ["GM_xmlhttpRequest"], grantNone: false, noFrames: false,
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

// Run the page-world source with a mock vault that records the relayed request and lets the test drive
// native XHR events back through the registered handler (simulating window.__bbPageXHR).
function runPageWithVault(code) {
    const relayed = [];          // every __bbPageGM(token, api, payload)
    let registeredHandler = null;
    let mintedId = 0;
    const vault = function (token, api, payload) { relayed.push({ token, api, payload }); return Promise.resolve(null); };
    vault.xhr = function (handler) { mintedId += 1; registeredHandler = handler; return "pwx_" + mintedId + "_deadbeef"; };
    vault.xhrDone = function () { registeredHandler = null; };
    const pageWin = {
        document: { head: { appendChild() {} }, documentElement: { appendChild() {} },
            createElement() { return { setAttribute() {}, appendChild() {} }; } },
        JSON, Object, Array, Promise, console, atob: (s) => Buffer.from(s, "base64").toString("binary"),
        Uint8Array, ArrayBuffer, Blob: undefined, DOMParser: undefined, __obs: {},
        __bbPageGM: vault
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageWin.document, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    return { pageWin, relayed, fire: (type, payload) => registeredHandler && registeredHandler(type, payload),
             hasHandler: () => !!registeredHandler };
}

function injectCode(calls) { return calls.filter((c) => c.api === "injectPageWorld")[0].payload.code; }

(async function main() {
    console.log("GM_xmlhttpRequest in the page world (vault relay + native→page response)");

    const body = [
        "window.__obs.events = [];",
        "var h = GM_xmlhttpRequest({",
        "  method: 'POST', url: 'https://api.example.org/x', data: 'q=1',",
        "  responseType: 'json',",
        "  onload: function (r) { window.__obs.events.push(['load', r.status, r.responseText]); },",
        "  onerror: function (r) { window.__obs.events.push(['error', r.error]); }",
        "});",
        "window.__obs.abortIsFn = (typeof h.abort === 'function');"
    ].join("\n");
    const calls = bootForXHRCode(body);
    await new Promise((r) => setTimeout(r, 10));

    test("a granted GM_xmlhttpRequest script routes to the page world", () => {
        assert.strictEqual(calls.filter((c) => c.api === "injectPageWorld").length, 1);
    });

    const { pageWin, relayed, fire, hasHandler } = runPageWithVault(injectCode(calls));
    const obs = pageWin.__obs;

    test("the request is relayed through the vault to native (token + serialized request)", () => {
        const xhr = relayed.filter((r) => r.api === "GM_xmlhttpRequest");
        assert.strictEqual(xhr.length, 1, "one GM_xmlhttpRequest relayed");
        assert.strictEqual(xhr[0].token, "tok-xhr", "authenticated with the script's token");
        assert.strictEqual(xhr[0].payload.request.method, "POST");
        assert.strictEqual(xhr[0].payload.request.url, "https://api.example.org/x");
        assert.strictEqual(xhr[0].payload.request.data, "q=1");
        assert.ok(/^pwx_/.test(xhr[0].payload.requestId), "uses the vault-minted (unguessable) request id");
    });
    test("a handler was registered on the vault for native to stream events into", () => {
        assert.ok(hasHandler(), "vault.xhr registered a streaming handler");
    });
    test("the abort handle is a function (relays GM_abortRequest)", () => {
        assert.strictEqual(obs.abortIsFn, true);
    });

    // Simulate native streaming the response back via window.__bbPageXHR → the registered handler.
    fire("load", { status: 200, statusText: "OK", responseText: "{\"ok\":true}", readyState: 4 });
    fire("loadend", { status: 200, readyState: 4 });

    test("onload fires with the shaped response (status + responseText delivered native→page)", () => {
        assert.strictEqual(JSON.stringify(obs.events), JSON.stringify([["load", 200, "{\"ok\":true}"]]));
    });
    test("loadend reaps the handler (vault.xhrDone called)", () => {
        assert.ok(!hasHandler(), "handler removed after loadend");
    });

    // Abort path relays GM_abortRequest through the vault.
    {
        const body2 = "var h = GM_xmlhttpRequest({ url: 'https://api.example.org/y', onload: function(){} }); h.abort();";
        const calls2 = bootForXHRCode(body2);
        await new Promise((r) => setTimeout(r, 10));
        const { relayed: relayed2 } = runPageWithVault(injectCode(calls2));
        test("abort() relays GM_abortRequest through the vault", () => {
            assert.ok(relayed2.some((r) => r.api === "GM_abortRequest"), "GM_abortRequest relayed");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
