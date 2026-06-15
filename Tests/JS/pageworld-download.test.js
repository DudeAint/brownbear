//
//  pageworld-download.test.js
//  BrownBear
//
//  Tests GM_download in the PAGE world (brownbear-runtime.js pageWorldGMClient + the vault). A granted
//  page-world script's download request goes out through the vault's non-configurable window.__bbPageGM to
//  the restricted brownbearPage handler (native fetches the file with @connect enforcement); native streams
//  the download lifecycle (progress/load/error/abort) BACK by evaluating window.__bbPageXHR(id, type,
//  payload) in the page world — a native→page eval, never a page-readable DOM channel. The vault mints the
//  request id with pristine crypto so a hostile page can't predict it. Same machinery as the page-world
//  GM_xmlhttpRequest. This drives the round-trip end to end: request relay, callback streaming, abort.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-download.test.js`. Exits non-zero on any failure.
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

// Boot the isolated runtime → get the injectPageWorld source for a granted GM_download script.
function bootForDownloadCode(source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-dl", name: "dl", uuid: "77777777-7777-7777-7777-777777777777",
                runAt: "document-start", grants: ["GM_download"], grantNone: false, noFrames: false,
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

// Run the page-world source with a mock vault that records relayed requests and lets the test drive native
// download events back through the registered handler (simulating window.__bbPageXHR).
function runPageWithVault(code) {
    const relayed = [];
    let registeredHandler = null;
    let mintedId = 0;
    const vault = function (token, api, payload) { relayed.push({ token, api, payload }); return Promise.resolve(null); };
    vault.xhr = function (handler) { mintedId += 1; registeredHandler = handler; return "pwx_" + mintedId + "_deadbeef"; };
    vault.xhrDone = function () { registeredHandler = null; };
    const pageWin = {
        document: { head: { appendChild() {} }, documentElement: { appendChild() {} },
            createElement() { return { setAttribute() {}, appendChild() {} }; } },
        JSON, Object, Array, Promise, console, __obs: {}, __bbPageGM: vault
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
    console.log("GM_download in the page world (vault relay + native→page lifecycle streaming)");

    const body = [
        "window.__obs.events = [];",
        "var h = GM_download({",
        "  url: 'https://cdn.example.org/file.zip', name: 'file.zip', saveAs: true,",
        "  onprogress: function (p) { window.__obs.events.push(['progress', p.loaded]); },",
        "  onload: function (p) { window.__obs.events.push(['load', p.name]); },",
        "  onerror: function (p) { window.__obs.events.push(['error', p.error]); }",
        "});",
        "window.__obs.abortIsFn = (typeof h.abort === 'function');"
    ].join("\n");
    const calls = bootForDownloadCode(body);
    await new Promise((r) => setTimeout(r, 10));

    test("a granted GM_download script routes to the page world", () => {
        assert.strictEqual(calls.filter((c) => c.api === "injectPageWorld").length, 1);
    });

    const { pageWin, relayed, fire, hasHandler } = runPageWithVault(injectCode(calls));
    const obs = pageWin.__obs;

    test("the download request is relayed through the vault to native (token + payload)", () => {
        const dl = relayed.filter((r) => r.api === "GM_download");
        assert.strictEqual(dl.length, 1, "one GM_download relayed");
        assert.strictEqual(dl[0].token, "tok-dl", "authenticated with the script's token");
        assert.strictEqual(dl[0].payload.url, "https://cdn.example.org/file.zip");
        assert.strictEqual(dl[0].payload.name, "file.zip");
        assert.strictEqual(dl[0].payload.saveAs, true);
        assert.ok(/^pwx_/.test(dl[0].payload.requestId), "uses the vault-minted (unguessable) request id");
    });
    test("a handler was registered on the vault for native to stream events into", () => {
        assert.ok(hasHandler(), "vault.xhr registered a streaming handler");
    });
    test("the abort handle is a function", () => {
        assert.strictEqual(obs.abortIsFn, true);
    });

    // Simulate native streaming progress then completion via window.__bbPageXHR → the registered handler.
    fire("progress", { loaded: 512, total: 1024 });
    fire("load", { name: "file.zip", url: "https://cdn.example.org/file.zip" });

    test("onprogress + onload fire with the streamed payloads", () => {
        assert.strictEqual(JSON.stringify(obs.events),
            JSON.stringify([["progress", 512], ["load", "file.zip"]]));
    });
    test("a terminal event (load) reaps the handler (vault.xhrDone called)", () => {
        assert.ok(!hasHandler(), "handler removed after the download settled");
    });

    // Error path: onerror fires and the handler is reaped.
    {
        const body2 = [
            "window.__obs.events = [];",
            "GM_download({ url: 'https://cdn.example.org/x', onerror: function (p) { window.__obs.events.push(['error', p.error]); } });"
        ].join("\n");
        const calls2 = bootForDownloadCode(body2);
        await new Promise((r) => setTimeout(r, 10));
        const r2 = runPageWithVault(injectCode(calls2));
        r2.fire("error", { error: "network" });
        test("onerror fires on a streamed error and the handler is reaped", () => {
            assert.strictEqual(JSON.stringify(r2.pageWin.__obs.events), JSON.stringify([["error", "network"]]));
            assert.ok(!r2.hasHandler(), "handler removed after error");
        });
    }

    // Abort path relays GM_downloadAbort through the vault.
    {
        const body3 = "var h = GM_download({ url: 'https://cdn.example.org/z', onload: function(){} }); h.abort();";
        const calls3 = bootForDownloadCode(body3);
        await new Promise((r) => setTimeout(r, 10));
        const { relayed: relayed3 } = runPageWithVault(injectCode(calls3));
        test("abort() relays GM_downloadAbort through the vault with the requestId", () => {
            const ab = relayed3.filter((r) => r.api === "GM_downloadAbort");
            assert.strictEqual(ab.length, 1, "GM_downloadAbort relayed");
            assert.ok(/^pwx_/.test(ab[0].payload.requestId), "carries the minted requestId");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
