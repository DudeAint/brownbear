"use strict";
//
//  i18n-placeholders.test.js
//  BrownBear
//
//  chrome.i18n.getMessage must resolve NAMED placeholders, not only positional $1..$9. A Chrome i18n
//  message can be "$NAME$ $VERSION$ is available" with a declared placeholders map
//  {name:{content:"$1"}, version:{content:"$2"}}; getMessage substitutes $name$/$version$ with their
//  content first, then the positional args. Without this the literal "$version$"/"$name$" leak into the
//  UI (Tampermonkey's options/popup version line). Native now ships the placeholders map as
//  __bbBgPlaceholders; this pins the background shim's resolution. (The page shim shares the algorithm.)
//

const fs = require("fs");
const vm = require("vm");
const path = require("path");
const assert = require("assert");

const BG = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-background.js"), "utf8");

let passed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message)); process.exitCode = 1; }
}

function bootBg(messages, placeholders) {
    const ctx = {}; ctx.globalThis = ctx; ctx.self = ctx;
    for (const k of ["Object", "Array", "JSON", "Math", "Date", "RegExp", "Error", "TypeError",
        "Symbol", "Map", "Set", "WeakMap", "Proxy", "Reflect", "Function", "String", "Number",
        "Boolean", "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent",
        "decodeURIComponent", "Promise"]) { if (global[k] !== undefined) { ctx[k] = global[k]; } }
    const noop = function () { var a = arguments, cb = a[a.length - 1]; if (typeof cb === "function") { cb("null"); } };
    for (const f of ["__bb_set_timeout", "__bb_clear_timer", "__bb_log", "__bb_storage_get",
        "__bb_send_message", "__bb_message_response", "__bb_idle", "__bb_subtle"]) { ctx[f] = noop; }
    ctx.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "T", version: "1.0" });
    ctx.__bbBgExtId = "abcdefghijklmnopabcdefghijklmnop";
    ctx.__bbBgBaseURL = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/";
    ctx.__bbBgMessages = JSON.stringify(messages);
    ctx.__bbBgPlaceholders = JSON.stringify(placeholders || {});
    ctx.__bbUserAgent = "Mozilla/5.0";
    ctx.__bbLanguage = "en-US";
    ctx.__bbModuleSource = function () { return null; };
    vm.createContext(ctx);
    vm.runInContext(BG, ctx, { filename: "brownbear-webext-background.js" });
    return ctx;
}

function getMessage(ctx, key, subs) {
    ctx.__k = key; ctx.__s = subs === undefined ? undefined : subs;
    return vm.runInContext("globalThis.chrome.i18n.getMessage(__k, __s)", ctx);
}

test("named placeholders resolve to their substitution args ($version$ no longer leaks)", function () {
    const ctx = bootBg(
        { update: "$NAME$ $VERSION$ is available" },
        { update: { name: "$1", version: "$2" } });
    assert.strictEqual(getMessage(ctx, "update", ["Tampermonkey", "5.0"]), "Tampermonkey 5.0 is available");
});

test("a named placeholder with LITERAL content resolves without any substitutions", function () {
    const ctx = bootBg({ greet: "Hello $WHO$" }, { greet: { who: "World" } });
    assert.strictEqual(getMessage(ctx, "greet"), "Hello World");
});

test("placeholder name matching is case-insensitive", function () {
    const ctx = bootBg({ m: "$Foo$" }, { m: { foo: "bar" } });
    assert.strictEqual(getMessage(ctx, "m"), "bar");
});

test("positional-only messages still substitute ($1..$9)", function () {
    const ctx = bootBg({ count: "$1 items found" }, {});
    assert.strictEqual(getMessage(ctx, "count", ["3"]), "3 items found");
});

test("the $$ escape becomes a literal $ when substitutions are supplied", function () {
    const ctx = bootBg({ price: "Cost: $$$1" }, {});
    assert.strictEqual(getMessage(ctx, "price", ["5"]), "Cost: $5");
});

test("a literal $5 with no substitutions is left intact (not eaten as $5 positional)", function () {
    const ctx = bootBg({ lit: "Save $5 today" }, {});
    assert.strictEqual(getMessage(ctx, "lit"), "Save $5 today");
});

test("an unknown $token$ with no matching placeholder is left as-is", function () {
    const ctx = bootBg({ u: "$UNKNOWN$ end" }, { u: { known: "x" } });
    assert.strictEqual(getMessage(ctx, "u"), "$UNKNOWN$ end");
});

test("a missing message key returns empty string", function () {
    const ctx = bootBg({}, {});
    assert.strictEqual(getMessage(ctx, "nope"), "");
});

console.log("\n" + passed + " passed" + (process.exitCode ? "" : ", 0 failed"));
