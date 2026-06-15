//
//  pageworld-onurlchange.test.js
//  BrownBear
//
//  Tests SPA URL tracking (window.onurlchange + a 'urlchange' event) for PAGE-WORLD userscripts
//  (brownbear-runtime.js pageWorldGMClient). In the page world `window` IS the page window, so the client
//  patches its history.pushState/replaceState and listens for popstate/hashchange — every navigation then
//  fires the script's window.onurlchange handler with { url } and dispatches a 'urlchange' CustomEvent.
//  Tampermonkey/Violentmonkey parity for `@grant window.onurlchange`.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-onurlchange.test.js`. Exits non-zero on any failure.
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
                token: "tok-url", name: "url", uuid: "66666666-6666-6666-6666-666666666666",
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

// A page context whose history.pushState updates location.href (like a real browser) so the client's
// wrapped pushState → emit detects the change.
function runPage(code) {
    const location = { href: "https://example.com/a" };
    const listeners = {};
    const pageWin = {
        history: {
            pushState(s, t, url) { location.href = url; },
            replaceState(s, t, url) { location.href = url; }
        },
        location,
        addEventListener(type, fn) { (listeners[type] || (listeners[type] = [])).push(fn); },
        dispatchEvent(ev) { (listeners[ev.type] || []).slice().forEach((fn) => fn(ev)); return true; },
        CustomEvent: function (type, init) { this.type = type; this.detail = init && init.detail; },
        Promise, JSON, Object, Array, console, onurlchange: null, __obs: {},
        document: { head: { appendChild() {} }, documentElement: { appendChild() {} }, createElement() { return { setAttribute() {}, appendChild() {} }; } },
        __bbPageGM: function () {}
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageWin.document, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    return { pageWin };
}

(async function main() {
    console.log("window.onurlchange (SPA URL tracking) in the page world");

    const body = [
        "window.__obs = { onurl: null, evt: null };",
        "window.onurlchange = function (e) { window.__obs.onurl = e.url; };",
        "window.addEventListener('urlchange', function (e) { window.__obs.evt = e.detail.url; });"
    ].join("\n");
    const calls = bootForCode(["GM_getValue", "window.onurlchange"], body);
    await new Promise((r) => setTimeout(r, 10));

    test("a script granting window.onurlchange routes to the page world", () => {
        assert.strictEqual(calls.filter((c) => c.api === "injectPageWorld").length, 1);
    });

    const { pageWin } = runPage(calls.filter((c) => c.api === "injectPageWorld")[0].payload.code);

    // SPA navigation via history.pushState (the client wrapped it).
    pageWin.history.pushState({}, "", "https://example.com/b");
    await new Promise((r) => setImmediate(r));   // the wrap defers emit one microtask

    test("history.pushState fires window.onurlchange with the new url", () => {
        assert.strictEqual(pageWin.__obs.onurl, "https://example.com/b");
    });
    test("…and dispatches a 'urlchange' event with detail.url", () => {
        assert.strictEqual(pageWin.__obs.evt, "https://example.com/b");
    });

    // No spurious fire when the URL is unchanged.
    pageWin.__obs.onurl = "UNCHANGED";
    pageWin.history.replaceState({}, "", "https://example.com/b");   // same href
    await new Promise((r) => setImmediate(r));
    test("a same-URL replaceState does NOT re-fire onurlchange", () => {
        assert.strictEqual(pageWin.__obs.onurl, "UNCHANGED");
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
