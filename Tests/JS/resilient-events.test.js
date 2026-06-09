//
//  resilient-events.test.js
//  BrownBear
//
//  Tests the page-world resilience shim (brownbear-resilient-events.js). Some pages replace
//  window.addEventListener/removeEventListener with an instrumentation wrapper (e.g. New Relic's
//  nrWrapper); when that agent's external script is blocked, the wrapper throws on every call and
//  poisons the page global, breaking the page AND any MAIN-world userscript. The shim keeps the methods
//  working by trying the page's wrapper and falling back to the native ONLY when it throws — while
//  leaving a WORKING wrapper untouched (identity restored after its first successful call).
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

// Build a fresh window whose native add/removeEventListener (on EventTarget.prototype) record calls, run
// the shim against it, and return the handle + the native call log.
function freshWindow() {
    const added = [], removed = [];
    function NativeAdd(type, fn) { added.push([type, fn]); return "native-add"; }
    function NativeRemove(type, fn) { removed.push([type, fn]); return "native-remove"; }
    const EventTarget = function () {};
    EventTarget.prototype.addEventListener = NativeAdd;
    EventTarget.prototype.removeEventListener = NativeRemove;
    const window = Object.create(EventTarget.prototype);
    window.EventTarget = EventTarget;
    const ctx = { console, window };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return { window, added, removed };
}

console.log("resilient-events shim tests");

test("transparent pass-through: with no page override, calls reach the native", () => {
    const { window, added } = freshWindow();
    const fn = function () {};
    const ret = window.addEventListener("click", fn);
    assert.strictEqual(ret, "native-add");
    assert.ok(added.some((a) => a[0] === "click" && a[1] === fn), "registered natively");
});

test("a BROKEN wrapper (always throws) is bypassed: the call doesn't throw and registers natively", () => {
    const { window, added } = freshWindow();
    window.addEventListener = function nrBroken() { var ie; return ie.addEventListener.apply(ie, arguments); };
    const fn = function () {};
    let threw = false;
    try { window.addEventListener("load", fn); } catch (e) { threw = true; }
    assert.ok(!threw, "the throwing wrapper must not propagate");
    assert.ok(added.some((a) => a[0] === "load" && a[1] === fn), "fell back to the native registration");
});

test("a broken wrapper stays SHADOWED (identity is the guard, not the broken function)", () => {
    const { window } = freshWindow();
    const broken = function nrBroken() { throw new Error("ie is undefined"); };
    window.addEventListener = broken;
    // never called successfully → never trusted → getter keeps returning the guard, not `broken`
    assert.notStrictEqual(window.addEventListener, broken);
    assert.ok(typeof window.addEventListener === "function");
});

test("a WORKING wrapper is preserved and its identity restored after one successful call", () => {
    const { window, added } = freshWindow();
    let calls = 0;
    const good = function goodWrap(type, fn) { calls++; return window.EventTarget.prototype.addEventListener.call(window, type, fn); };
    window.addEventListener = good;
    assert.notStrictEqual(window.addEventListener, good, "before any call, the guard shadows it");
    window.addEventListener("x", function () {});   // succeeds → trusted
    assert.strictEqual(calls, 1, "the page wrapper actually ran");
    assert.strictEqual(window.addEventListener, good, "identity restored after a successful call");
    assert.ok(added.some((a) => a[0] === "x"), "the wrapper's native delegation still registered");
});

test("re-assigning a new override resets trust (must prove itself again)", () => {
    const { window } = freshWindow();
    const good = function (t, f) { return window.EventTarget.prototype.addEventListener.call(window, t, f); };
    window.addEventListener = good;
    window.addEventListener("a", function () {});            // trusts `good`
    assert.strictEqual(window.addEventListener, good);
    const broken = function () { throw new Error("boom"); };
    window.addEventListener = broken;                        // fresh override → untrusted again
    assert.notStrictEqual(window.addEventListener, broken, "a new override is shadowed until it proves itself");
    let threw = false;
    try { window.addEventListener("b", function () {}); } catch (e) { threw = true; }
    assert.ok(!threw, "the new broken override is also bypassed");
});

test("stable guard identity + native-looking toString (no obvious tampering tell)", () => {
    const { window } = freshWindow();
    assert.strictEqual(window.addEventListener, window.addEventListener, "guard reference is stable");
    assert.ok(/\[native code\]/.test(window.addEventListener.toString()), "toString masked");
});

test("removeEventListener is guarded the same way", () => {
    const { window, removed } = freshWindow();
    window.removeEventListener = function () { throw new Error("broken remove"); };
    const fn = function () {};
    let threw = false;
    try { window.removeEventListener("load", fn); } catch (e) { threw = true; }
    assert.ok(!threw, "a broken removeEventListener wrapper is bypassed");
    assert.ok(removed.some((r) => r[0] === "load" && r[1] === fn), "fell back to native removeEventListener");
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
