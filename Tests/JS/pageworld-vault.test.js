//
//  pageworld-vault.test.js
//  BrownBear
//
//  Tests the document-start page-world vault (brownbear-pageworld-vault.js). The vault captures a
//  PRISTINE reference to the restricted native handler (webkit.messageHandlers.brownbearPage) before any
//  page script runs, and exposes it as a non-configurable window.__bbPageGM(token, api, payload). This is
//  the foundation of the secure page-world WRITE path: the page cannot redefine __bbPageGM (so it can't
//  snoop a userscript's writes) and cannot usefully call it (native requires a per-injection token).
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-vault.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-pageworld-vault.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// Run the vault in a fresh page context whose webkit.messageHandlers.brownbearPage records posts.
function runVault(opts) {
    opts = opts || {};
    const posts = [];
    const mh = opts.noHandler ? {} : {
        brownbearPage: { postMessage(m) { posts.push(m); return Promise.resolve("ok"); } }
    };
    const win = { webkit: { messageHandlers: mh }, Object };
    win.window = win;
    const ctx = { window: win, Object, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return { win, posts };
}

(function main() {
    console.log("page-world vault (window.__bbPageGM)");

    // --- exposes __bbPageGM and posts token-bound messages to the native handler -------------------
    {
        const { win, posts } = runVault();
        test("exposes window.__bbPageGM as a function", () => {
            assert.strictEqual(typeof win.__bbPageGM, "function");
        });
        test("a write posts {api, payload, token} to the brownbearPage handler", () => {
            win.__bbPageGM("tok-123", "GM_setValue", { key: "k", value: "\"v\"" });
            assert.strictEqual(posts.length, 1);
            // posts[0] is built in the vm realm — compare structurally (JSON), not by reference/prototype.
            assert.strictEqual(JSON.stringify(posts[0]),
                JSON.stringify({ api: "GM_setValue", payload: { key: "k", value: "\"v\"" }, token: "tok-123" }));
        });
        test("a missing/garbage payload is normalized to {}", () => {
            win.__bbPageGM("tok-123", "GM_log", undefined);
            assert.strictEqual(JSON.stringify(posts[posts.length - 1].payload), "{}");
        });
        test("a null token is forwarded as null (native will reject it)", () => {
            win.__bbPageGM(null, "GM_setValue", { key: "x", value: "1" });
            assert.strictEqual(posts[posts.length - 1].token, null);
        });
    }

    // --- non-configurable: a later page script cannot redefine or snoop __bbPageGM -----------------
    {
        const { win } = runVault();
        const original = win.__bbPageGM;
        test("__bbPageGM is non-writable (page cannot replace it with a snooping wrapper)", () => {
            try { win.__bbPageGM = function evil() {}; } catch (e) { /* strict-mode throw is fine */ }
            assert.strictEqual(win.__bbPageGM, original, "binding must be unchanged");
        });
        test("__bbPageGM is non-configurable (page cannot redefine it)", () => {
            const desc = Object.getOwnPropertyDescriptor(win, "__bbPageGM");
            assert.strictEqual(desc.configurable, false);
            assert.strictEqual(desc.writable, false);
            assert.strictEqual(desc.enumerable, false, "and non-enumerable so it doesn't show up in the page's window scan");
            assert.throws(() => Object.defineProperty(win, "__bbPageGM", { value: 1, configurable: true }),
                "redefining a non-configurable property must throw");
        });
    }

    // --- single install: a second run does not replace the first binding ---------------------------
    {
        const { win } = runVault();
        const first = win.__bbPageGM;
        vm.runInContext(SRC, vm.createContext({ window: win, Object, console }));   // re-run against same window
        test("re-running the vault keeps the original binding (single install)", () => {
            assert.strictEqual(win.__bbPageGM, first);
        });
    }

    // --- graceful no-op when the native handler is not registered ----------------------------------
    {
        const { win } = runVault({ noHandler: true });
        test("no brownbearPage handler → __bbPageGM is not installed (writes simply unavailable, no throw)", () => {
            assert.strictEqual(win.__bbPageGM, undefined);
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
