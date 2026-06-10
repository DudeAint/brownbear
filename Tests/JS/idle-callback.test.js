//
//  idle-callback.test.js
//  BrownBear
//
//  Tests the requestIdleCallback/cancelIdleCallback polyfill (brownbear-idle-callback.js). WebKit ships
//  neither in any JS world, so an extension content script / userscript that calls requestIdleCallback
//  (ScriptCat's content runtime) throws a bare ReferenceError and dies. The shim provides the standard
//  setTimeout-based behaviour: schedule the callback, hand it a {didTimeout, timeRemaining} deadline,
//  honour options.timeout, support cancellation, and never clobber a native implementation.
//
//  Pure Node, no deps. Run by CI (`js-runtime` job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/idle-callback.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-idle-callback.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// A window with controllable fake timers + clock, so callback scheduling/cancellation and the timeout
// deadline can be asserted synchronously. `preset` seeds a pre-existing requestIdleCallback (the
// "Chrome already has it" case the shim must leave alone).
function freshWindow(preset) {
    let timers = [];
    let nextTimer = 1;
    let nowValue = 1000;
    const window = {
        setTimeout(fn) { const id = nextTimer++; timers.push({ id, fn }); return id; },
        clearTimeout(id) { timers = timers.filter((t) => t.id !== id); },
        Date: { now() { return nowValue; } }
    };
    if (preset) { window.requestIdleCallback = preset; }
    const ctx = { console, window };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return {
        window,
        pendingCount() { return timers.length; },
        // Advance the clock by `advanceMs` (default 0) then flush every pending timer.
        fire(advanceMs) {
            nowValue += (advanceMs || 0);
            const due = timers.slice();
            timers = [];
            due.forEach((t) => t.fn());
        }
    };
}

console.log("requestIdleCallback polyfill tests");

test("defines requestIdleCallback and cancelIdleCallback when absent", () => {
    const { window } = freshWindow();
    assert.strictEqual(typeof window.requestIdleCallback, "function");
    assert.strictEqual(typeof window.cancelIdleCallback, "function");
});

test("does NOT override a native requestIdleCallback (Chrome already has it)", () => {
    const native = function () {};
    const { window } = freshWindow(native);
    assert.strictEqual(window.requestIdleCallback, native, "native implementation left untouched");
});

test("schedules the callback (not called synchronously) and runs it on the timer", () => {
    const env = freshWindow();
    let deadline = null;
    const id = env.window.requestIdleCallback(function (dl) { deadline = dl; });
    assert.strictEqual(typeof id, "number");
    assert.strictEqual(deadline, null, "must not run synchronously");
    assert.strictEqual(env.pendingCount(), 1);
    env.fire();
    assert.ok(deadline, "callback ran once the timer fired");
});

test("hands the callback a deadline: didTimeout false, timeRemaining a non-negative number", () => {
    const env = freshWindow();
    let deadline = null;
    env.window.requestIdleCallback(function (dl) { deadline = dl; });
    env.fire();
    assert.strictEqual(deadline.didTimeout, false);
    assert.strictEqual(typeof deadline.timeRemaining, "function");
    assert.ok(deadline.timeRemaining() >= 0, "timeRemaining is non-negative");
});

test("didTimeout is true once options.timeout has elapsed", () => {
    const env = freshWindow();
    let deadline = null;
    env.window.requestIdleCallback(function (dl) { deadline = dl; }, { timeout: 100 });
    env.fire(200);   // advance 200ms (> 100) before the timer fires
    assert.strictEqual(deadline.didTimeout, true);
});

test("cancelIdleCallback prevents a pending callback from ever running", () => {
    const env = freshWindow();
    let called = false;
    const id = env.window.requestIdleCallback(function () { called = true; });
    env.window.cancelIdleCallback(id);
    assert.strictEqual(env.pendingCount(), 0, "the pending timer was cleared");
    env.fire();
    assert.strictEqual(called, false);
});

test("ignores a non-function callback instead of throwing", () => {
    const env = freshWindow();
    assert.strictEqual(env.window.requestIdleCallback(null), 0);
    assert.strictEqual(env.pendingCount(), 0);
});

test("a throwing idle callback does not break the shim", () => {
    const env = freshWindow();
    env.window.requestIdleCallback(function () { throw new Error("boom"); });
    assert.doesNotThrow(() => env.fire(), "the shim swallows the callback's throw");
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
