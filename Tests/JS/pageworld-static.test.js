//
//  pageworld-static.test.js
//  BrownBear
//
//  brownbear-pageworld-static.js — the true-document-start fast-path for grant-none page-world userscripts.
//  Native prepends `var __bbStaticCfg = [...]` and adds this as a .page atDocumentStart WKUserScript. This
//  proves: it runs ONLY scripts whose @match/@exclude match the current URL; it wraps each via
//  buildPageWorldSource (so unsafeWindow===window, GM_info present) and evals it at page scope; a body that
//  throws or a CSP-refused eval doesn't break the loop or other scripts; and the shared run-once guard means
//  the dynamic path can safely re-emit the same script without a double-run.
//
//  Pure Node, no deps. Run by CI + locally with `node Tests/JS/pageworld-static.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-pageworld-static.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// Run the static bootstrap with a given __bbStaticCfg at a given URL. Captures every string passed to the
// page-world `eval` (that's the wrapped body the script would run) and runs it against a shared sandbox
// window so we can observe effects + the run-once guard.
function run(cfg, href, opts) {
    opts = opts || {};
    const evaled = [];
    const win = {};
    win.window = win; win.self = win; win.top = win;
    win.location = { href: href };
    win.history = {}; win.JSON = JSON; win.RegExp = RegExp; win.URL = URL;
    win.CustomEvent = function () {}; win.Promise = Promise;
    win.addEventListener = function () {}; win.console = console;
    const sandbox = {
        __bbStaticCfg: cfg, location: win.location, JSON, RegExp, URL, console,
        window: win, self: win, top: win, history: win.history, CustomEvent: win.CustomEvent, Promise,
        addEventListener: win.addEventListener,
        eval: function (code) {
            evaled.push(code);
            if (opts.execute) { vm.runInContext(code, ctx); }   // actually run the wrapped body in the sandbox
        }
    };
    const ctx = vm.createContext(sandbox);
    vm.runInContext(SRC, ctx);
    return { evaled, win };
}

const S = (over) => Object.assign({
    uuid: "u-" + Math.random().toString(36).slice(2), matches: ["*://*.example.com/*"],
    includes: [], excludes: [], excludeMatches: [], info: { scriptHandler: "BrownBear" },
    source: "window.__ran = (window.__ran||0)+1;"
}, over);

test("a matching script is wrapped (buildPageWorldSource) and eval'd at document-start", () => {
    const { evaled } = run([S()], "https://www.example.com/page");
    assert.strictEqual(evaled.length, 1);
    assert.ok(/unsafeWindow = window/.test(evaled[0]), "wrapped via buildPageWorldSource");
    assert.ok(/__bbRanUS/.test(evaled[0]), "carries the run-once guard");
    assert.ok(/window\.__ran/.test(evaled[0]), "contains the body");
});

test("a non-matching URL runs nothing", () => {
    const { evaled } = run([S()], "https://other.org/page");
    assert.strictEqual(evaled.length, 0);
});

test("@exclude-match suppresses an otherwise-matching script", () => {
    const cfg = [S({ excludeMatches: ["*://*.example.com/private/*"] })];
    assert.strictEqual(run(cfg, "https://www.example.com/private/x")[0] === undefined ? run(cfg, "https://www.example.com/private/x").evaled.length : 0, 0);
    assert.strictEqual(run(cfg, "https://www.example.com/ok").evaled.length, 1);
});

test("only matching scripts in a mixed batch run", () => {
    const cfg = [
        S({ uuid: "a", matches: ["*://*.example.com/*"] }),
        S({ uuid: "b", matches: ["https://nope.test/*"] }),
        S({ uuid: "c", matches: ["<all_urls>"] })
    ];
    const { evaled } = run(cfg, "https://www.example.com/x");
    assert.strictEqual(evaled.length, 2, "example.com + <all_urls>, not nope.test");
});

test("a throwing body (or CSP-refused eval) doesn't stop later scripts", () => {
    let throwOnce = true;
    const cfg = [S({ uuid: "boom" }), S({ uuid: "fine" })];
    // Simulate the FIRST eval throwing (e.g., strict-CSP refusal); the loop must continue to the second.
    const evaled = [];
    const win = {}; win.window = win;
    const sandbox = {
        __bbStaticCfg: cfg, location: { href: "https://www.example.com/x" }, JSON, RegExp, URL, console,
        window: win, self: win, top: win, history: {}, CustomEvent: function () {}, Promise, addEventListener() {},
        eval: function (code) { evaled.push(code); if (throwOnce) { throwOnce = false; throw new Error("EvalError: Refused (CSP)"); } }
    };
    vm.runInContext(SRC, vm.createContext(sandbox));
    assert.strictEqual(evaled.length, 2, "both attempted; the throw on #1 didn't abort the loop");
});

test("end-to-end: a matched body actually runs once in the page (run-once guard holds)", () => {
    const cfg = [S({ uuid: "once" })];
    const { win } = run(cfg, "https://www.example.com/x", { execute: true });
    assert.strictEqual(win.__ran, 1, "body executed exactly once");
});

console.log("\n" + passed + " passed, " + failed + " failed");
if (failed) { process.exitCode = 1; }
