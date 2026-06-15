//
//  gm-addstyle-thenable.test.js
//  BrownBear
//
//  GM_addStyle / GM_addElement (brownbear-runtime.js) must return a Tampermonkey/Violentmonkey-compatible
//  thenable: the returned element carries a SELF-DELETING `then`, so `GM_addStyle(css).then(el => …)` works
//  and the first `then` (or an `await`) consumes it, leaving a plain element (no lingering thenable that
//  would make the element accidentally awaitable forever). Pins both the isolated and page-world paths.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/gm-addstyle-thenable.test.js`. Exits non-zero on failure.
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

function makeStyle() {
    return {
        tagName: "style", textContent: "", sheet: { cssRules: { length: 1 } },
        setAttribute() {}, appendChild(n) { return n; }, remove() {}
    };
}
function CSSStyleSheet() { this.replaceSync = function (css) { this.cssText = css; }; }

// Boot the isolated runtime; the script stashes the GM_addStyle return on window.__el.
function bootIsolated() {
    const script = {
        token: "tok", name: "thenable", uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        runAt: "document-start", grants: ["GM_addStyle"], grantNone: false, noFrames: false,
        injectInto: "content", requires: [], resources: {},
        source: "window.__el = GM_addStyle('body{color:red}');", values: {},
        info: { scriptHandler: "BrownBear" }
    };
    function postMessage(msg) {
        if (msg.api === "getScripts") { return Promise.resolve([script]); }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        return Promise.resolve(null);
    }
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, console, CustomEvent: function () {}, CSSStyleSheet
    };
    win.window = win; win.self = win; win.top = win;
    const document = {
        readyState: "complete", addEventListener() {},
        head: { appendChild(n) { return n; } }, documentElement: { appendChild(n) { return n; } },
        createElement(tag) { return tag === "style" ? makeStyle() : { setAttribute() {}, appendChild() {} }; },
        adoptedStyleSheets: []
    };
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(SRC, ctx);
    return win;
}

// Capture the page-world payload for a granted page-world-safe GM_addStyle script.
function bootPageWorld() {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-pw", name: "thenable-pw", uuid: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                runAt: "document-start", grants: ["GM_getValue", "GM_addStyle"], grantNone: false,
                noFrames: false, injectInto: "auto", requires: [], resources: {},
                source: "window.__el = GM_addStyle('body{color:red}');", values: {},
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

function runPageWorld(code) {
    const pageDoc = {
        head: { appendChild(n) { return n; } }, documentElement: { appendChild(n) { return n; } },
        createElement(tag) { return tag === "style" ? makeStyle() : { setAttribute() {}, appendChild() {} }; },
        adoptedStyleSheets: []
    };
    const pageWin = {
        document: pageDoc, JSON, Object, Array, Promise, console, CSSStyleSheet, __obs: {},
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, CustomEvent: function () {}, __bbPageGM: function () {}
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageDoc, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    return pageWin;
}

function assertThenable(el, label) {
    assert.ok(el, label + ": element returned");
    assert.strictEqual(typeof el.then, "function", label + ": has a then");
    let received = null;
    const ret = el.then(function (e) { received = e; return e; });
    assert.strictEqual(received, el, label + ": then invokes the callback with the element");
    assert.strictEqual(ret, el, label + ": then returns the callback's result");
    assert.strictEqual(typeof el.then, "undefined", label + ": then is self-deleting (plain element after)");
}

(async function main() {
    console.log("GM_addStyle/GM_addElement return a self-deleting thenable element (TM/VM parity)");
    await new Promise((r) => setTimeout(r, 10));

    {
        const win = bootIsolated();
        await new Promise((r) => setTimeout(r, 10));
        test("isolated: GM_addStyle return is a self-deleting thenable", () => {
            assertThenable(win.__el, "isolated");
        });
    }

    {
        const calls = bootPageWorld();
        await new Promise((r) => setTimeout(r, 10));
        const injects = calls.filter((c) => c.api === "injectPageWorld");
        test("the granted GM_addStyle script routed to the page world", () => {
            assert.strictEqual(injects.length, 1);
        });
        test("page world: GM_addStyle return is a self-deleting thenable", () => {
            const pageWin = runPageWorld(injects[0].payload.code);
            assertThenable(pageWin.__el, "page world");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
