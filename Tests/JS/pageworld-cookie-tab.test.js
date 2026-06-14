//
//  pageworld-cookie-tab.test.js
//  BrownBear
//
//  Tests the request→REPLY GM APIs in the page world (brownbear-runtime.js pageWorldGMClient + the vault):
//  GM_cookie (list/set/delete) and GM_getTab/GM_saveTab/GM_listTabs. The request goes out via the vault's
//  non-configurable window.__bbPageGM; native runs it (GM_cookie is @connect-gated) and RETURNS the result
//  through the WKScriptMessageHandlerWithReply reply promise, which the vault settles via a PRISTINE
//  Promise#then into the caller's closure callback — never on the DOM, never through a page-tamperable
//  `.then`. So even sensitive cross-origin cookie data stays confidential.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-cookie-tab.test.js`. Exits non-zero on any failure.
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

function bootForCode(grants, source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-ck", name: "ck", uuid: "55555555-5555-5555-5555-555555555555",
                runAt: "document-start", grants: grants, grantNone: false, noFrames: false,
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

// Run the page-world source with a mock vault whose `.reply(token, api, payload, cb, errcb)` records the
// relayed request and resolves with a canned native result via the callback (simulating the reply promise).
function runPage(code, nativeResultFor) {
    const relayed = [];
    const vault = function () {};
    vault.reply = function (token, api, payload, cb) {
        relayed.push({ token, api, payload });
        const r = nativeResultFor(api, payload);
        if (typeof cb === "function") { cb(r); }
    };
    const pageWin = {
        document: { head: { appendChild() {} }, documentElement: { appendChild() {} }, createElement() { return { setAttribute() {}, appendChild() {} }; } },
        JSON, Object, Array, Promise, console, __obs: {}, __bbPageGM: vault
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageWin.document, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    return { pageWin, relayed };
}

function injectCode(calls) { return calls.filter((c) => c.api === "injectPageWorld")[0].payload.code; }

(async function main() {
    console.log("GM_cookie + GM_getTab/saveTab/listTabs in the page world (reply via pristine .then)");

    // --- GM_cookie.list returns cookie data through the reply -------------------------------------
    {
        const body = [
            "window.__obs = { cookies: null, err: 'unset' };",
            "GM_cookie.list({ domain: 'google.com' }, function (cookies, err) {",
            "  window.__obs.cookies = cookies; window.__obs.err = err;",
            "});"
        ].join("\n");
        const calls = bootForCode(["GM_cookie"], body);
        await new Promise((r) => setTimeout(r, 10));
        test("a GM_cookie-granted script routes to the page world", () => {
            assert.strictEqual(calls.filter((c) => c.api === "injectPageWorld").length, 1);
        });
        const { pageWin, relayed } = runPage(injectCode(calls), function (api, payload) {
            if (api === "GM_cookie" && payload.action === "list") { return [{ name: "SID", value: "abc" }]; }
            return null;
        });
        await new Promise((r) => setImmediate(r));   // GM_cookie.list returns a Promise → callback on a microtask
        test("GM_cookie.list relays {action:list, details} via the vault with the token", () => {
            const c = relayed.filter((r) => r.api === "GM_cookie");
            assert.strictEqual(c.length, 1);
            assert.strictEqual(c[0].token, "tok-ck");
            assert.strictEqual(c[0].payload.action, "list");
            assert.strictEqual(c[0].payload.details.domain, "google.com");
        });
        test("the returned cookie data reaches the script's callback (delivered via the reply, not the DOM)", () => {
            assert.strictEqual(JSON.stringify(pageWin.__obs.cookies), JSON.stringify([{ name: "SID", value: "abc" }]));
            assert.strictEqual(pageWin.__obs.err, undefined);
        });
    }

    // --- GM_getTab / GM_saveTab / GM_listTabs ----------------------------------------------------
    {
        const body = [
            "window.__obs = {};",
            "GM_getTab(function (t) { window.__obs.tab = t; });",
            "GM_saveTab({ scroll: 42 }, function () { window.__obs.saved = true; });",
            "GM_listTabs(function (m) { window.__obs.tabs = m; });"
        ].join("\n");
        const calls = bootForCode(["GM_getTab", "GM_saveTab", "GM_listTabs"], body);
        await new Promise((r) => setTimeout(r, 10));
        const { pageWin, relayed } = runPage(injectCode(calls), function (api) {
            if (api === "GM_getTab") { return JSON.stringify({ note: "hi" }); }
            if (api === "GM_listTabs") { return { "1": JSON.stringify({ a: 1 }), "2": { b: 2 } }; }
            return null;
        });
        test("GM_getTab returns the per-tab object (JSON parsed)", () => {
            assert.strictEqual(JSON.stringify(pageWin.__obs.tab), JSON.stringify({ note: "hi" }));
        });
        test("GM_saveTab relays the serialized value and fires its callback", () => {
            const s = relayed.filter((r) => r.api === "GM_saveTab");
            assert.strictEqual(s.length, 1);
            assert.strictEqual(s[0].payload.value, JSON.stringify({ scroll: 42 }));
            assert.strictEqual(pageWin.__obs.saved, true);
        });
        test("GM_listTabs returns the tab map (each value JSON parsed)", () => {
            assert.strictEqual(JSON.stringify(pageWin.__obs.tabs), JSON.stringify({ "1": { a: 1 }, "2": { b: 2 } }));
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
