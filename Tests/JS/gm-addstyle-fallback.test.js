//
//  gm-addstyle-fallback.test.js
//  BrownBear
//
//  GM_addStyle (brownbear-runtime.js) must apply a CONSTRUCTED stylesheet (adoptedStyleSheets) ONLY as a
//  fallback — when the <style> element it created did NOT take (a strict style-src refused it). #391 made
//  it apply the constructed sheet ALWAYS, alongside a working <style>, which (a) applied the CSS twice
//  with the adopted sheet cascading after the page's stylesheets (overriding the page harder than a plain
//  <style>), and (b) meant removing the returned <style> element — the TM/VM way to toggle a style off —
//  left the adopted sheet behind. This pins the fix: constructed sheet only when the <style> has no rules.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/gm-addstyle-fallback.test.js`. Exits non-zero on any failure.
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

// Boot the runtime and run an ISOLATED (@inject-into content) script granting GM_addStyle. `styleTakes`
// controls whether the created <style> reports applied rules (sheet.cssRules.length > 0) — i.e. whether a
// strict style-src would have refused it. Returns the document's adoptedStyleSheets + created <style> els.
function bootAddStyle(styleTakes) {
    const styleEls = [];
    const adopted = [];
    function makeStyle() {
        const el = {
            tagName: "style", textContent: "", removed: false,
            sheet: { cssRules: { length: styleTakes ? 1 : 0 } },
            setAttribute() {}, appendChild(n) { return n; },
            remove() { this.removed = true; }
        };
        styleEls.push(el);
        return el;
    }
    const script = {
        token: "tok", name: "styletest", uuid: "33333333-3333-3333-3333-333333333333",
        runAt: "document-start", grants: ["GM_addStyle"], grantNone: false, noFrames: false,
        injectInto: "content",   // isolated world → buildGM's GM_addStyle
        requires: [], resources: {}, source: "window.__el = GM_addStyle('body{color:red}');",
        values: {}, info: { scriptHandler: "BrownBear" }
    };
    function postMessage(msg) {
        if (msg.api === "getScripts") { return Promise.resolve([script]); }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        return Promise.resolve(null);
    }
    function CSSStyleSheet() { this.replaceSync = function (css) { this.cssText = css; }; }
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState() {}, replaceState() {} },
        location: { href: "https://example.com/page" },
        addEventListener() {}, removeEventListener() {},
        console, CustomEvent: function () {}, CSSStyleSheet
    };
    win.window = win; win.self = win; win.top = win;
    const document = {
        readyState: "complete", addEventListener() {},
        head: { appendChild(n) { return n; } },
        documentElement: { appendChild(n) { return n; } },
        createElement(tag) { return tag === "style" ? makeStyle() : { setAttribute() {}, appendChild() {} }; },
        adoptedStyleSheets: adopted
    };
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return { win, document, styleEls };
}

// Boot the runtime and capture the native bridge calls for a GRANTED script (injectInto "auto" + only
// page-world-safe grants ⇒ routes to the page world; the injectPageWorld payload is its page-world source).
function bootGrantedForPageWorld() {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-pw", name: "pwstyletest", uuid: "44444444-4444-4444-4444-444444444444",
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

// Run the page-world client code in a PAGE context whose created <style> reports `styleTakes` (its
// sheet.cssRules.length). Returns the page document's adoptedStyleSheets and the created <style> elements.
function runPageWorldAddStyle(code, styleTakes) {
    const styleEls = [];
    const adopted = [];
    function CSSStyleSheet() { this.replaceSync = function (css) { this.cssText = css; }; }
    const pageDoc = {
        head: { appendChild(n) { return n; } }, documentElement: { appendChild(n) { return n; } },
        createElement(tag) {
            if (tag !== "style") { return { setAttribute() {}, appendChild() {} }; }
            const el = { tagName: "style", textContent: "", sheet: { cssRules: { length: styleTakes ? 1 : 0 } },
                setAttribute() {}, appendChild(n) { return n; } };
            styleEls.push(el); return el;
        },
        adoptedStyleSheets: adopted
    };
    const pageWin = {
        document: pageDoc, JSON, Object, Array, Promise, console, CSSStyleSheet, __obs: {},
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, CustomEvent: function () {},
        __bbPageGM: function () {}
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageDoc, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    // Read the LIVE document.adoptedStyleSheets: the client does `D.adoptedStyleSheets = …concat([sheet])`,
    // which reassigns the property to a new array (the original `adopted` reference stays empty).
    return { adopted: pageDoc.adoptedStyleSheets, styleEls };
}

(async function main() {
    console.log("GM_addStyle constructed-stylesheet is a CSP fallback, not an always-on duplicate");
    await new Promise((r) => setTimeout(r, 10));   // let getScripts → run() settle

    // 1) <style> takes (normal page) → NO constructed sheet (no double application).
    {
        const { document, styleEls } = bootAddStyle(true);
        await new Promise((r) => setTimeout(r, 10));
        test("a working <style> is created", () => { assert.strictEqual(styleEls.length, 1); });
        test("when the <style> applies, NO constructed stylesheet is added (no duplicate)", () => {
            assert.strictEqual(document.adoptedStyleSheets.length, 0,
                "adoptedStyleSheets must stay empty when the <style> took");
        });
        test("removing the returned <style> element removes the style (nothing lingers in adoptedStyleSheets)", () => {
            assert.strictEqual(document.adoptedStyleSheets.length, 0);
        });
    }

    // 2) <style> blocked by strict style-src (no rules) → constructed sheet applied (CSP-resilient).
    {
        const { document, styleEls } = bootAddStyle(false);
        await new Promise((r) => setTimeout(r, 10));
        test("when the <style> is refused (no rules), the constructed stylesheet IS applied as a fallback", () => {
            assert.strictEqual(styleEls.length, 1, "a <style> was still attempted");
            assert.strictEqual(document.adoptedStyleSheets.length, 1, "constructed sheet applied as the fallback");
            assert.strictEqual(document.adoptedStyleSheets[0].cssText, "body{color:red}");
        });
    }

    // 3) PAGE WORLD (granted script ⇒ VM-parity main-world execution). The page-world GM_addStyle MUST
    //    have the SAME fallback-only behavior — a regression here double-applied every granted script's
    //    CSS (adopted sheet always added alongside a working <style>), visibly mis-styling pages.
    {
        const calls = bootGrantedForPageWorld();
        await new Promise((r) => setTimeout(r, 10));
        const injects = calls.filter((c) => c.api === "injectPageWorld");
        test("the granted GM_addStyle script routed to the page world", () => {
            assert.strictEqual(injects.length, 1);
        });
        // <style> takes → NO constructed sheet (no duplicate over-application).
        {
            const { adopted, styleEls } = runPageWorldAddStyle(injects[0].payload.code, true);
            test("page world: a working <style> is created", () => { assert.strictEqual(styleEls.length, 1); });
            test("page world: when the <style> applies, NO constructed stylesheet is added (the fix)", () => {
                assert.strictEqual(adopted.length, 0,
                    "adoptedStyleSheets must stay empty when the page-world <style> took");
            });
        }
        // <style> refused (no rules) → constructed sheet applied as the CSP fallback.
        {
            const { adopted, styleEls } = runPageWorldAddStyle(injects[0].payload.code, false);
            test("page world: when the <style> is refused, the constructed sheet IS the fallback", () => {
                assert.strictEqual(styleEls.length, 1, "a <style> was still attempted");
                assert.strictEqual(adopted.length, 1, "constructed sheet applied as the fallback");
                assert.strictEqual(adopted[0].cssText, "body{color:red}");
            });
        }
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
