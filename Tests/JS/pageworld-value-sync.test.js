//
//  pageworld-value-sync.test.js
//  BrownBear
//
//  Tests REMOTE value-change sync for PAGE-WORLD userscripts (brownbear-runtime.js pageWorldGMClient).
//  GM_addValueChangeListener fires for the script's OWN writes synchronously; for a change made by the
//  SAME script in ANOTHER tab/frame or the dashboard, native streams it back native→page via the vault's
//  minted-id channel (window.__bbPageXHR(vcStreamId, "valueChange", {key, oldJSON, newJSON})) and the
//  client fires the listener with remote = true (Tampermonkey/Violentmonkey cross-context parity). The
//  client subscribes lazily on the first listener (posting GM_subscribeValueChanges with its streamId) and
//  keeps the page-local read cache in sync so GM_getValue reflects the remote change.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-value-sync.test.js`. Exits non-zero on any failure.
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

function bootForValueCode(source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-vc", name: "vc", uuid: "13131313-1313-1313-1313-131313131313",
                runAt: "document-start", grants: ["GM_getValue", "GM_addValueChangeListener"],
                grantNone: false, noFrames: false, injectInto: "auto", requires: [], resources: {},
                source: source, values: { n: "1" }, info: { scriptHandler: "BrownBear" }
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
    vault.xhr = function (handler) { mintCount += 1; const id = "pwx_" + mintCount + "_va1uesync"; handlers[id] = handler; return id; };
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
    return { pageWin, relayed, push: (id, payload) => handlers[id] && handlers[id]("valueChange", payload) };
}

function injectCode(calls) { return calls.filter((c) => c.api === "injectPageWorld")[0].payload.code; }

(async function main() {
    console.log("remote value-change sync for page-world userscripts");

    const body = [
        "window.__obs.events = [];",
        "GM_addValueChangeListener('n', function (key, oldV, newV, remote) {",
        "  window.__obs.events.push([key, oldV, newV, remote]);",
        "});",
        "window.__obs.readBefore = GM_getValue('n');"
    ].join("\n");
    const calls = bootForValueCode(body);
    await new Promise((r) => setTimeout(r, 10));

    test("a granted value-listener script routes to the page world", () => {
        assert.strictEqual(calls.filter((c) => c.api === "injectPageWorld").length, 1);
    });

    const { pageWin, relayed, push } = runPageWithVault(injectCode(calls));
    const obs = pageWin.__obs;

    test("adding a listener subscribes the remote channel through the vault (with its streamId)", () => {
        const sub = relayed.filter((r) => r.api === "GM_subscribeValueChanges");
        assert.strictEqual(sub.length, 1, "one GM_subscribeValueChanges relayed");
        assert.strictEqual(sub[0].token, "tok-vc", "authenticated with the script's token");
        assert.ok(/^pwx_/.test(sub[0].payload.streamId), "carries the vault-minted streamId");
    });
    test("the pre-seeded value reads synchronously", () => {
        assert.strictEqual(obs.readBefore, 1);
    });

    const streamId = relayed.filter((r) => r.api === "GM_subscribeValueChanges")[0].payload.streamId;

    // Native streams a REMOTE change (another tab set n = 42) → listener fires with remote = true.
    push(streamId, { key: "n", oldJSON: "1", newJSON: "42" });
    test("a remote change fires the listener with remote = true and the new value", () => {
        assert.strictEqual(JSON.stringify(obs.events), JSON.stringify([["n", 1, 42, true]]));
    });
    test("the page-local read cache reflects the remote change (GM_getValue is in sync)", () => {
        // Re-read through a fresh injection-time API isn't available here; assert the cache var indirectly
        // by pushing another change whose oldV must equal the just-applied 42.
        push(streamId, { key: "n", oldJSON: "42", newJSON: "43" });
        const last = obs.events[obs.events.length - 1];
        assert.strictEqual(last[1], 42, "the prior remote value became the new oldV (cache stayed in sync)");
        assert.strictEqual(last[2], 43);
    });

    // A remote DELETE (newJSON null) fires with newV undefined.
    push(streamId, { key: "n", oldJSON: "43", newJSON: null });
    test("a remote delete fires with newV undefined", () => {
        const last = obs.events[obs.events.length - 1];
        assert.strictEqual(last[2], undefined);
        assert.strictEqual(last[3], true);
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
