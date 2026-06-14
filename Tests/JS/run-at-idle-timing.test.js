//
//  run-at-idle-timing.test.js
//  BrownBear
//
//  Verifies the @run-at scheduling in the injected userscript runtime (brownbear-runtime.js) matches
//  Violentmonkey/Tampermonkey. The fidelity bug this guards against: BrownBear used to fire
//  @run-at document-idle scripts at the window `load` event — i.e. only after EVERY image and
//  subresource finished — which can be many seconds after the page is usable. VM fires idle scripts
//  right after DOMContentLoaded plus one macrotask yield (inject.js: `await injectAll('idle')` where
//  idle does `await nextTask()`), so they feel instant. This test pins that behavior:
//
//    • document-start  → runs immediately (before DOMContentLoaded).
//    • document-end    → runs synchronously when DOMContentLoaded fires.
//    • document-idle   → runs after DOMContentLoaded + ONE macrotask — and crucially does NOT wait
//                        for the `load` event (we never fire `load`, yet idle still runs).
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/run-at-idle-timing.test.js`. Exits non-zero on any failure.
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

// The runtime schedules document-idle one MACROTASK out (setTimeout(0) fallback in this mock, where
// no MessageChannel is provided). To stay deterministic we never mix setImmediate with setTimeout:
//   • microtasks() drains the promise queue WITHOUT advancing a macrotask, so a pending setTimeout(0)
//     provably has NOT fired — this is what lets us assert "idle hasn't run yet".
//   • macrotask() advances exactly one timer turn; Node drains microtasks between macrotasks, so the
//     idle run()'s own promise chain has settled by the time it resolves.
async function microtasks() { for (let i = 0; i < 8; i += 1) { await Promise.resolve(); } }
function macrotask() { return new Promise((r) => setTimeout(r, 0)); }

// Boot the runtime against a page that starts in readyState "loading", so document-end/idle scripts
// are DEFERRED rather than run inline. Returns a controller that records every injectPageWorld call
// (the per-script "this script ran" signal for grant-none page-world scripts) and lets the test fire
// DOMContentLoaded / load on demand.
function boot(scripts) {
    const injects = [];                                          // names of scripts handed to the page world
    function postMessage(msg) {
        if (msg.api === "getScripts") { return Promise.resolve(scripts); }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        if (msg.api === "injectPageWorld") {
            const code = (msg.payload && msg.payload.code) || "";
            const m = /__RANMARK__([a-z0-9-]+)/.exec(code);      // scripts tag themselves with a marker
            injects.push(m ? m[1] : "?");
        }
        return Promise.resolve(null);
    }
    const docListeners = {};                                     // type -> [fn] on `document`
    const winListeners = {};                                     // type -> [fn] on `window`
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState: function () {}, replaceState: function () {} },
        location: { href: "https://example.com/page" },
        addEventListener: function (type, fn) { (winListeners[type] || (winListeners[type] = [])).push(fn); },
        removeEventListener: function () {},
        console: console,
        setTimeout: setTimeout,                                  // runtime's macrotask fallback uses this
        CustomEvent: function CustomEvent() {},
        dispatchEvent: function () { return true; }
    };
    win.window = win; win.self = win; win.top = win;
    const document = {
        readyState: "loading",                                   // deferred path for end/idle
        addEventListener: function (type, fn) { (docListeners[type] || (docListeners[type] = [])).push(fn); }
    };
    const ctx = { console, window: win, document, location: win.location, setTimeout, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);

    function fire(target, type) {
        const map = target === "document" ? docListeners : winListeners;
        if (type === "DOMContentLoaded") { document.readyState = "interactive"; }
        if (type === "load") { document.readyState = "complete"; }
        (map[type] || []).slice().forEach((fn) => fn({ type }));
    }
    return { injects, fire };
}

function scriptData(name, runAt) {
    return {
        token: "tok-" + name,
        name: name,
        uuid: "11111111-1111-1111-1111-111111111111",
        runAt: runAt,
        grants: [],
        grantNone: true,                                         // → page-world inject = our timing signal
        noFrames: false,
        injectInto: "auto",
        requires: [],
        resources: {},
        // The marker lets the harness identify which script was injected, by name.
        source: "var __RANMARK__" + name + " = 1;",
        values: {},
        info: { uuid: "11111111-1111-1111-1111-111111111111", version: "5.0",
                script: { name: name, version: "1.0" } }
    };
}

(async function main() {
    console.log("@run-at scheduling (document-idle = DOMContentLoaded + macrotask, NOT load)");

    const c = boot([
        scriptData("start", "document-start"),
        scriptData("end", "document-end"),
        scriptData("idle", "document-idle")
    ]);

    // 1) Before any DOM event: only document-start has run. (start's run() chain is all microtasks.)
    await microtasks();
    test("document-start runs immediately (before DOMContentLoaded)", () => {
        assert.deepStrictEqual(c.injects, ["start"], "only start should have run, got: " + c.injects);
    });

    // 2) Fire DOMContentLoaded: document-end runs now; document-idle is still pending (one macrotask out).
    //    We drain ONLY microtasks here, so the idle script's pending setTimeout(0) provably can't fire.
    c.fire("document", "DOMContentLoaded");
    await microtasks();
    test("document-end runs at DOMContentLoaded", () => {
        assert.ok(c.injects.indexOf("end") !== -1, "end should have run after DOMContentLoaded");
    });
    test("document-idle has NOT run yet (it yields a macrotask after DOM ready)", () => {
        assert.strictEqual(c.injects.indexOf("idle"), -1, "idle ran too early: " + c.injects);
    });

    // 3) Let one macrotask pass — WITHOUT ever firing `load`. document-idle must run now.
    await macrotask();
    await microtasks();
    test("document-idle runs after DOMContentLoaded + a macrotask, with NO `load` event", () => {
        assert.ok(c.injects.indexOf("idle") !== -1,
            "idle never ran — it is still (incorrectly) gated on the window `load` event. injects: " + c.injects);
    });

    // 4) Ordering: end before idle (VM runs end, then idle).
    test("ordering is start → end → idle", () => {
        assert.deepStrictEqual(c.injects, ["start", "end", "idle"],
            "expected start,end,idle in order, got: " + c.injects);
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
