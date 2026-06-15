//
//  gm-addelement-style-csp.test.js
//  BrownBear
//
//  GM_addElement('style', {textContent}) (brownbear-runtime.js) must get the SAME CSP-resilient fallback
//  GM_addStyle has: if a strict style-src refuses the created <style> (its sheet has no rules), apply the
//  CSS via a constructed stylesheet (adoptedStyleSheets). Without it, a GM_addElement style is silently
//  dropped under a CSP that GM_addStyle survives — a Violentmonkey-parity gap. The fallback must be scoped
//  to <style> ONLY: <script>/<link> stay governed by the page CSP (bypassing those would be a security
//  regression). Pins both the isolated and page-world paths.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/gm-addelement-style-csp.test.js`. Exits non-zero on any failure.
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

// A document whose created <style> reports `styleTakes` (sheet.cssRules.length) — i.e. whether a strict
// style-src would have refused it. Records created <style> elements + adoptedStyleSheets.
function makeDocument(styleTakes, adopted) {
    return {
        readyState: "complete", addEventListener() {},
        head: { appendChild(n) { return n; } }, documentElement: { appendChild(n) { return n; } },
        createElement(tag) {
            if (tag === "style") {
                return {
                    tagName: "style", textContent: "",
                    sheet: { cssRules: { length: styleTakes ? 1 : 0 } },
                    setAttribute() {}, appendChild(n) { return n; }
                };
            }
            return { tagName: tag, textContent: "", setAttribute() {}, appendChild(n) { return n; } };
        },
        adoptedStyleSheets: adopted
    };
}

function CSSStyleSheet() { this.replaceSync = function (css) { this.cssText = css; }; }

// Boot an ISOLATED script that adds a <style> (and a <script>) via GM_addElement. `styleTakes` controls
// whether the <style> reports applied rules. Returns the document's adoptedStyleSheets.
function bootIsolated(styleTakes) {
    const adopted = [];
    const script = {
        token: "tok", name: "addel", uuid: "77777777-7777-7777-7777-777777777777",
        runAt: "document-start", grants: ["GM_addElement"], grantNone: false, noFrames: false,
        injectInto: "content", requires: [], resources: {},
        source: "window.__s = GM_addElement('style', {textContent: 'body{color:red}'});"
            + "window.__js = GM_addElement('script', {textContent: 'window.__x=1'});",
        values: {}, info: { scriptHandler: "BrownBear" }
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
    const document = makeDocument(styleTakes, adopted);
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(SRC, ctx);
    return { document };
}

// Capture the page-world payload for a granted GM_addElement script (page-world-safe ⇒ routes to page world).
function bootPageWorld() {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-pw", name: "addel-pw", uuid: "88888888-8888-8888-8888-888888888888",
                runAt: "document-start", grants: ["GM_addElement"], grantNone: false, noFrames: false,
                injectInto: "auto", requires: [], resources: {},
                source: "window.__s = GM_addElement('style', {textContent: 'body{color:red}'});", values: {},
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

function runPageWorld(code, styleTakes) {
    const adopted = [];
    const pageDoc = makeDocument(styleTakes, adopted);
    const pageWin = {
        document: pageDoc, JSON, Object, Array, Promise, console, CSSStyleSheet, __obs: {},
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, CustomEvent: function () {}, __bbPageGM: function () {}
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageDoc, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    return { adopted: pageDoc.adoptedStyleSheets };
}

(async function main() {
    console.log("GM_addElement('style') gets the CSP-resilient constructed-stylesheet fallback");
    await new Promise((r) => setTimeout(r, 15));

    // 1) Isolated, <style> takes → NO constructed sheet (no double application).
    {
        const { document } = bootIsolated(true);
        await new Promise((r) => setTimeout(r, 15));
        test("isolated: a working <style> needs no constructed-sheet fallback", () => {
            assert.strictEqual(document.adoptedStyleSheets.length, 0);
        });
    }

    // 2) Isolated, <style> refused → constructed sheet applied with the element's CSS.
    {
        const { document } = bootIsolated(false);
        await new Promise((r) => setTimeout(r, 15));
        test("isolated: a refused <style> falls back to a constructed stylesheet", () => {
            assert.strictEqual(document.adoptedStyleSheets.length, 1, "the fallback fired");
            assert.strictEqual(document.adoptedStyleSheets[0].cssText, "body{color:red}");
        });
        test("isolated: a <script> element gets NO style fallback (page CSP governs it)", () => {
            // Only the one <style> contributed a sheet; the GM_addElement('script', …) did not.
            assert.strictEqual(document.adoptedStyleSheets.length, 1);
        });
    }

    // 3) Page world (granted, VM-parity): same fallback behavior.
    {
        const calls = bootPageWorld();
        await new Promise((r) => setTimeout(r, 15));
        const injects = calls.filter((c) => c.api === "injectPageWorld");
        test("the granted GM_addElement script routed to the page world", () => {
            assert.strictEqual(injects.length, 1);
        });
        test("page world: a working <style> needs no fallback", () => {
            assert.strictEqual(runPageWorld(injects[0].payload.code, true).adopted.length, 0);
        });
        test("page world: a refused <style> falls back to a constructed stylesheet", () => {
            const { adopted } = runPageWorld(injects[0].payload.code, false);
            assert.strictEqual(adopted.length, 1);
            assert.strictEqual(adopted[0].cssText, "body{color:red}");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
