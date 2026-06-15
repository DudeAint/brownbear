//
//  run-at-document-body.test.js
//  BrownBear
//
//  @run-at document-body (brownbear-runtime.js): a script must run as soon as <body> exists — EARLIER
//  than DOMContentLoaded, while the rest of the DOM is still parsing (Tampermonkey/Greasemonkey parity).
//  Previously "document-body" fell into the document-end bucket (DOMContentLoaded). Now the loader buckets
//  it into whenBodyReady, which observes documentElement for the body being inserted (DOMContentLoaded is
//  the guaranteed fallback). This proves: it does NOT run while body is null, and DOES run the moment the
//  body appears — before DOMContentLoaded.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/run-at-document-body.test.js`. Exits non-zero on any failure.
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

// A controllable document whose body starts null and whose MutationObserver fires when we flip it. The
// runtime injects @inject-into content (isolated bridge) so the body runs via the loader's bucketing.
function boot() {
    const calls = [];
    let observerCb = null;
    const dclListeners = [];
    const document = {
        readyState: "loading",   // before DOMContentLoaded
        body: null,
        documentElement: { /* observed target */ },
        addEventListener(type, fn) { if (type === "DOMContentLoaded") { dclListeners.push(fn); } },
        head: { appendChild(n) { return n; } },
        createElement() { return { setAttribute() {}, appendChild() {} }; }
    };
    function MutationObserver(cb) { observerCb = cb; }
    MutationObserver.prototype.observe = function () {};
    MutationObserver.prototype.disconnect = function () {};

    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-b", name: "bodytest", uuid: "0b0b0b0b-0b0b-0b0b-0b0b-0b0b0b0b0b0b",
                runAt: "document-body", grants: ["GM_setValue"], grantNone: false, noFrames: false,
                injectInto: "content", requires: [], resources: {},
                source: "GM_setValue('ran', true);", values: {}, info: { scriptHandler: "BrownBear" }
            }]);
        }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        return Promise.resolve(null);   // GM_setValue etc.
    }
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, console, CustomEvent: function () {}, MutationObserver
    };
    win.window = win; win.self = win; win.top = win;
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined, MutationObserver };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(SRC, ctx);
    return {
        calls,
        ranSetValue: () => calls.some((c) => c.api === "GM_setValue" && c.payload && c.payload.key === "ran"),
        insertBody: () => { document.body = { appendChild() {} }; if (observerCb) { observerCb(); } },
        fireDOMContentLoaded: () => { document.readyState = "interactive"; dclListeners.slice().forEach((fn) => fn()); }
    };
}

(async function main() {
    console.log("@run-at document-body runs when <body> first exists (before DOMContentLoaded)");

    const h = boot();
    await new Promise((r) => setTimeout(r, 10));   // let getScripts settle

    test("a document-body script does NOT run while document.body is null", () => {
        assert.strictEqual(h.ranSetValue(), false, "must wait for the body");
    });

    // <body> is inserted (still mid-parse — DOMContentLoaded has NOT fired yet).
    h.insertBody();
    await new Promise((r) => setTimeout(r, 10));
    test("it runs the moment <body> appears — before DOMContentLoaded", () => {
        assert.strictEqual(h.ranSetValue(), true, "ran on body insertion");
    });

    // A second boot proving the DOMContentLoaded fallback when no observer-driven body insert is seen.
    {
        const h2 = boot();
        await new Promise((r) => setTimeout(r, 10));
        h2.insertBody.toString();   // (not called) — exercise the fallback path instead
        // Body never explicitly inserted via the observer; DOMContentLoaded fires → fallback runs it.
        h2.fireDOMContentLoaded();
        await new Promise((r) => setTimeout(r, 10));
        test("DOMContentLoaded is a guaranteed fallback (still runs the body script)", () => {
            assert.strictEqual(h2.ranSetValue(), true);
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
