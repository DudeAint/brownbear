"use strict";
//
//  firefox-scheme.test.js
//  BrownBear
//
//  A Firefox-build extension is served under moz-extension:// (not chrome-extension://) because its
//  bundle hardcodes that protocol and gates runtime messaging on it. Native picks the scheme from the
//  manifest (browser_specific_settings.gecko); the JS half is that the background shim, given a
//  moz-extension baseURL, must report a moz-extension TUPLE origin (NOT the spec's opaque "null") so a
//  Firefox manager's background message gate (Tampermonkey's mp(): sender.origin === self.location
//  .origin) accepts its own page senders. This test pins that JS behavior.
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

// A JavaScriptCore-like context: provide ONLY what JSC has natively, so the shim's own URL polyfill is
// used (JSC lacks URL) — exactly the on-device path. Do NOT inject Node's URL (it would mask the bug).
function bootBg(extId, scheme) {
    const ctx = {}; ctx.globalThis = ctx; ctx.self = ctx;
    for (const k of ["Object", "Array", "JSON", "Math", "Date", "RegExp", "Error", "TypeError",
        "Symbol", "Map", "Set", "WeakMap", "WeakSet", "Proxy", "Reflect", "Function", "String",
        "Number", "Boolean", "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent",
        "decodeURIComponent", "Promise", "ArrayBuffer", "Uint8Array"]) {
        if (global[k] !== undefined) { ctx[k] = global[k]; }
    }
    const noop = function () { var a = arguments, cb = a[a.length - 1]; if (typeof cb === "function") { cb("null"); } };
    for (const f of ["__bb_set_timeout", "__bb_clear_timer", "__bb_log", "__bb_storage_get",
        "__bb_storage_set", "__bb_send_message", "__bb_message_response", "__bb_alarm_get_all",
        "__bb_idle", "__bb_dnr", "__bb_userscripts", "__bb_import_script", "__bb_fetch",
        "__bb_crypto_uuid", "__bb_subtle"]) { ctx[f] = noop; }
    ctx.__bbBgManifest = JSON.stringify({ manifest_version: 2, background: { page: "background.html" } });
    ctx.__bbBgExtId = extId;
    ctx.__bbBgBaseURL = scheme + "://" + extId + "/";
    ctx.__bbBgMessages = "{}";
    ctx.__bbUserAgent = "Mozilla/5.0";
    ctx.__bbLanguage = "en-US";
    ctx.__bbModuleSource = function () { return null; };
    vm.createContext(ctx);
    vm.runInContext(BG, ctx, { filename: "brownbear-webext-background.js" });
    return ctx;
}

const ID = "abcdefghijklmnopabcdefghijklmnop";

test("Firefox build: worker location.origin is the moz-extension TUPLE origin (not 'null')", function () {
    const ctx = bootBg(ID, "moz-extension");
    assert.strictEqual(ctx.location.origin, "moz-extension://" + ID,
        "location.origin must be moz-extension://<id>, got " + JSON.stringify(ctx.location.origin));
    assert.strictEqual(ctx.origin, "moz-extension://" + ID, "self.origin must equal the tuple origin");
    const urlOrigin = vm.runInContext("new globalThis.URL('moz-extension://" + ID + "/options.html').origin", ctx);
    assert.strictEqual(urlOrigin, "moz-extension://" + ID, "new URL(moz-extension://...).origin must be the tuple origin");
});

test("Chrome build still reports the chrome-extension tuple origin (no regression)", function () {
    const ctx = bootBg(ID, "chrome-extension");
    assert.strictEqual(ctx.location.origin, "chrome-extension://" + ID);
    assert.strictEqual(ctx.origin, "chrome-extension://" + ID);
});

test("chrome.runtime.getURL uses the worker's own scheme (moz-extension for a Firefox build)", function () {
    const ctx = bootBg(ID, "moz-extension");
    const url = vm.runInContext("globalThis.chrome.runtime.getURL('options.html')", ctx);
    assert.strictEqual(url, "moz-extension://" + ID + "/options.html",
        "getURL must build moz-extension URLs, got " + JSON.stringify(url));
});

console.log("\n" + passed + " passed" + (process.exitCode ? "" : ", 0 failed"));
