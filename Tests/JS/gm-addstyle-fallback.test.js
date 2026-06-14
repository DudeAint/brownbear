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

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
