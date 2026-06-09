//
//  resilient-events.test.js
//  BrownBear
//
//  Tests the page-world resilience shim (brownbear-resilient-events.js). Instrumentation agents (New
//  Relic's nrWrapper) capture the original window.addEventListener and replace it with a wrapper that
//  calls back into that captured original. When the agent's external script is blocked the wrapper is
//  half-initialized: it either throws, or forwards a bogus `this` to the native ("Can only call
//  addEventListener on instances of EventTarget"). Either way it poisons the page global and breaks the
//  page AND any MAIN-world userscript. The shim keeps the methods working: it tries the page's override,
//  falls back to the native (with a real-EventTarget `this`) when the override throws OR would re-enter,
//  and never recurses even though the override calls back into the captured "original" (= the shim).
//
//  Pure Node, no deps. Run by CI (`js-runtime` job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/resilient-events.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-resilient-events.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// A fresh window with a real EventTarget hierarchy: the native add/removeEventListener (on
// EventTarget.prototype) record the (target, type, fn) they registered. Run the shim against it.
function freshWindow() {
    const added = [], removed = [];
    function EventTarget() {}
    EventTarget.prototype.addEventListener = function (type, fn) {
        if (!(this instanceof EventTarget)) {
            throw new TypeError("Can only call EventTarget.addEventListener on instances of EventTarget");
        }
        added.push([this, type, fn]); return "native-add";
    };
    EventTarget.prototype.removeEventListener = function (type, fn) {
        if (!(this instanceof EventTarget)) {
            throw new TypeError("Can only call EventTarget.removeEventListener on instances of EventTarget");
        }
        removed.push([this, type, fn]); return "native-remove";
    };
    const window = new EventTarget();
    window.EventTarget = EventTarget;
    const ctx = { console, window };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return { window, EventTarget, added, removed };
}

console.log("resilient-events shim tests");

test("transparent pass-through: with no page override, calls reach the native on the window", () => {
    const { window, added } = freshWindow();
    const fn = function () {};
    assert.strictEqual(window.addEventListener("click", fn), "native-add");
    assert.ok(added.some((a) => a[0] === window && a[1] === "click" && a[2] === fn));
});

// Model New Relic: capture the "original" (= the shim's guard), then replace with a wrapper that calls
// back into it. `mode` controls how the (blocked) wrapper misbehaves.
function installNRWrapper(window, mode) {
    const origAdd = window.addEventListener;       // captures the guard
    const origRemove = window.removeEventListener;
    const stats = { add: 0, remove: 0 };
    window.addEventListener = function nrWrapper(type, fn, opts) {
        stats.add++;
        if (mode === "throw") { var ie; return ie.addEventListener(type, fn); }       // throws outright
        if (mode === "bad-this") { return origAdd.call(undefined, type, fn, opts); }   // bogus `this`
        return origAdd.call(this, type, fn, opts);                                     // working: real `this`
    };
    window.removeEventListener = function nrWrapper(type, fn, opts) {
        stats.remove++;
        if (mode === "throw") { var ie; return ie.removeEventListener(type, fn); }
        if (mode === "bad-this") { return origRemove.call(undefined, type, fn, opts); }
        return origRemove.call(this, type, fn, opts);
    };
    return stats;
}

test("broken wrapper that THROWS: bot's addEventListener doesn't throw, registers on the window", () => {
    const { window, added } = freshWindow();
    installNRWrapper(window, "throw");
    const fn = function () {};
    let threw = false;
    try { window.addEventListener("load", fn); } catch (e) { threw = true; }
    assert.ok(!threw, "must not propagate the wrapper's throw");
    assert.ok(added.some((a) => a[0] === window && a[1] === "load" && a[2] === fn), "registered natively on window");
});

test("broken wrapper that forwards a BOGUS this: no EventTarget error, registers on the window", () => {
    const { window, added } = freshWindow();
    installNRWrapper(window, "bad-this");
    const fn = function () {};
    let err = null;
    try { window.addEventListener("load", fn); } catch (e) { err = e; }
    assert.strictEqual(err, null, "the 'Can only call ... on instances of EventTarget' error must not surface");
    assert.ok(added.some((a) => a[0] === window && a[1] === "load" && a[2] === fn), "registered on the window");
    assert.strictEqual(added.length, 1, "registered exactly once (no recursion-driven duplicates)");
});

test("the captured-original callback does NOT recurse (single registration, bounded wrapper calls)", () => {
    const { window, added } = freshWindow();
    const stats = installNRWrapper(window, "bad-this");
    window.addEventListener("load", function () {});
    assert.strictEqual(added.length, 1, "exactly one native registration");
    assert.strictEqual(stats.add, 1, "the wrapper ran once, not unbounded (no infinite recursion)");
});

test("a WORKING wrapper still runs (instrumentation preserved) and the listener registers once", () => {
    const { window, added } = freshWindow();
    const stats = installNRWrapper(window, "working");
    const fn = function () {};
    window.addEventListener("scroll", fn);
    assert.strictEqual(stats.add, 1, "the working wrapper ran");
    assert.ok(added.some((a) => a[0] === window && a[1] === "scroll" && a[2] === fn), "registered on window");
    assert.strictEqual(added.length, 1, "registered exactly once");
});

test("a direct call with a non-EventTarget this falls back to the window instead of throwing", () => {
    const { window, added } = freshWindow();
    const fn = function () {};
    let threw = false;
    try { window.addEventListener.call({ not: "an EventTarget" }, "x", fn); } catch (e) { threw = true; }
    assert.ok(!threw, "a bogus this must not throw");
    assert.ok(added.some((a) => a[0] === window && a[1] === "x"), "registered on the window as a safe default");
});

test("removeEventListener gets the same resilience (broken bogus-this wrapper)", () => {
    const { window, removed } = freshWindow();
    installNRWrapper(window, "bad-this");
    const fn = function () {};
    let threw = false;
    try { window.removeEventListener("load", fn); } catch (e) { threw = true; }
    assert.ok(!threw, "broken removeEventListener wrapper must not throw");
    assert.ok(removed.some((r) => r[0] === window && r[1] === "load" && r[2] === fn), "fell back to native remove");
});

test("stable guard identity + native-looking toString", () => {
    const { window } = freshWindow();
    assert.strictEqual(window.addEventListener, window.addEventListener, "guard reference is stable");
    assert.ok(/\[native code\]/.test(window.addEventListener.toString()), "toString masked");
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
