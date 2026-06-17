//
//  tabs-static-constants.test.js
//  BrownBear
//
//  Chrome exposes two enumerable static numeric constants on the chrome.tabs namespace: TAB_ID_NONE (-1, an
//  id that doesn't reference a real tab) and MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND (2, the per-second rate
//  cap for captureVisibleTab). Feature-detectors (e.g. the "Web Developer" extension) ENUMERATE the tabs
//  namespace and read these constants; if they're absent the value is `undefined` and detection breaks. This
//  test extracts `tabsApi()` from brownbear-webext-page.js, builds the namespace object, and asserts both
//  constants are present with Chrome's EXACT values, enumerable, and the right primitive type — without
//  disturbing the existing method/event surface. A malformed-extraction guard ensures the test fails loudly
//  if the function shape ever changes out from under it rather than silently passing.
//
//  Pure Node, no deps. Run by CI (Tests/JS/*.test.js) and locally with
//  `node Tests/JS/tabs-static-constants.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const SRC = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-page.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// Extract the body of `function tabsApi() { ... }` by brace-matching (same technique the equivalence test
// uses for buildPageWorldSource). Returns the full `function tabsApi() {...}` source string.
function extractTabsApi(src) {
    const sig = "function tabsApi() {";
    const start = src.indexOf(sig);
    assert.ok(start >= 0, "tabsApi() not found in page shim");
    let depth = 0, end = -1;
    for (let i = src.indexOf("{", start); i < src.length; i++) {
        if (src[i] === "{") depth++;
        else if (src[i] === "}") { depth--; if (depth === 0) { end = i + 1; break; } }
    }
    assert.ok(end > 0, "tabsApi() end brace not found");
    return src.slice(start, end);
}

// Build a callable tabsApi by injecting stubs for the free identifiers it closes over in the real shim:
// settle/bridge/makeEvent/tabEventLists plus the captured _Array/_Promise/Promise aliases. None of the stubs
// are exercised by reading the static constants, but they must exist so the factory doesn't ReferenceError.
function buildTabsApi(src) {
    const fnSrc = extractTabsApi(src);
    const factory = new Function(
        "settle", "bridge", "makeEvent", "tabEventLists", "_Array", "_Promise", "Promise",
        fnSrc + "\nreturn tabsApi;"
    );
    const noop = function () {};
    const settle = function (p) { return p; };
    const bridge = function () { return Promise.resolve(undefined); };
    const makeEvent = function () { return { addListener: noop, removeListener: noop, hasListener: function () { return false; } }; };
    // tabEventLists is indexed by event key in the real shim (tabEventLists["tabs.onCreated"], …).
    const tabEventLists = new Proxy({}, { get: function () { return []; } });
    const tabsApi = factory(settle, bridge, makeEvent, tabEventLists, Array, Promise, Promise);
    return tabsApi();
}

const tabs = buildTabsApi(SRC);

// Table-driven: each static constant Chrome puts on the tabs namespace, with its exact value.
const STATIC_CONSTANTS = [
    { name: "TAB_ID_NONE", value: -1 },
    { name: "MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND", value: 2 }
];

STATIC_CONSTANTS.forEach(function (c) {
    test(c.name + " is present with Chrome's exact value", function () {
        assert.ok(Object.prototype.hasOwnProperty.call(tabs, c.name), c.name + " missing from tabs namespace");
        assert.strictEqual(tabs[c.name], c.value, c.name + " should be " + c.value + " (got " + tabs[c.name] + ")");
    });
    test(c.name + " is a primitive number, not a getter/object", function () {
        assert.strictEqual(typeof tabs[c.name], "number", c.name + " must be a number");
        assert.ok(Number.isInteger(tabs[c.name]), c.name + " must be an integer");
    });
    test(c.name + " is enumerable (feature-detectors iterate the namespace)", function () {
        assert.ok(Object.keys(tabs).indexOf(c.name) >= 0, c.name + " must be enumerable");
    });
});

// Adding constants must not disturb the existing method + event surface.
test("existing tabs methods + events still present", function () {
    ["query", "get", "create", "update", "remove", "captureVisibleTab", "executeScript"].forEach(function (m) {
        assert.strictEqual(typeof tabs[m], "function", "tabs." + m + " should still be a function");
    });
    ["onCreated", "onUpdated", "onActivated", "onRemoved"].forEach(function (e) {
        assert.ok(tabs[e] && typeof tabs[e].addListener === "function", "tabs." + e + " should still expose addListener");
    });
});

// Malformed-extraction guard: feeding a source whose tabsApi() is malformed (unbalanced braces / wrong shape)
// must FAIL closed — extraction throws rather than silently yielding a passing-but-wrong namespace. This
// catches the case where the shim is refactored such that the brace-match no longer captures the real body.
test("malformed source fails closed (no silent pass)", function () {
    const broken = SRC.replace("function tabsApi() {", "function tabsApi() ");   // remove opening brace
    assert.throws(function () { buildTabsApi(broken); },
        "a tabsApi() with a missing opening brace must throw, not build a bogus namespace");
});

console.log("\n" + passed + " passed, " + failed + " failed");
if (failed > 0) { process.exit(1); }
