//
//  tabs-removecss.test.js
//  BrownBear
//
//  chrome.tabs.insertCSS had no chrome.tabs.removeCSS counterpart — an asymmetry a CSS-injecting MV2
//  extension hits when it tries to undo an injection (uBlock Origin's background touches it). Native already
//  supports removeCSS (it pairs with insertCSS in the scripting dispatch); this adds the missing shim method.
//  Boots the REAL background shim, asserts chrome.tabs.removeCSS exists and routes to the native scripting
//  bridge with method "removeCSS" and the (tabId, css) the call carried.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/tabs-removecss.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXT_ID = "removecsstestidaaaaaaaaaaaaaaaaa";

const scriptingCalls = [];   // [method, argsObject] captured from __bb_scripting

function bootBackground() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp,
        Map, Set, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    const nullCb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { c(JSON.stringify(null)); } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set",
        "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr",
        "__bb_action", "__bb_permissions", "__bb_fetch", "__bb_alarm_create",
        "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all"]) { sb[n] = nullCb; }
    // Capture chrome.scripting / tabs CSS routing.
    sb.__bb_scripting = (method, argsJSON, cb) => {
        scriptingCalls.push([method, JSON.parse(argsJSON)]);
        if (typeof cb === "function") { cb(JSON.stringify(null)); }
    };
    sb.__bb_set_timeout = (fn, ms, r) => (r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0));
    sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bbBgExtId = EXT_ID;
    sb.__bbBgBaseURL = `chrome-extension://${EXT_ID}/`;
    sb.__bbBgManifest = JSON.stringify({ manifest_version: 2, name: "t", version: "1",
        background: { scripts: ["bg.js"] }, permissions: ["tabs", "<all_urls>"] });
    sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb,
        { filename: "brownbear-webext-background.js" });
    return sb;
}

(async function main() {
    let passed = 0, failed = 0;
    const ok = (n) => { console.log("  ok   " + n); passed++; };
    const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

    const sb = bootBackground();
    const tabs = sb.chrome && sb.chrome.tabs;

    try {
        assert.ok(tabs, "chrome.tabs exists");
        assert.strictEqual(typeof tabs.insertCSS, "function", "tabs.insertCSS exists");
        assert.strictEqual(typeof tabs.removeCSS, "function", "tabs.removeCSS now exists (was the gap)");
        ok("chrome.tabs.removeCSS is defined (symmetric with insertCSS)");
    } catch (e) { bad("removeCSS defined", e); }

    try {
        scriptingCalls.length = 0;
        await tabs.removeCSS(7, { code: "body{color:red}" });
        const call = scriptingCalls.find((c) => c[0] === "removeCSS");
        assert.ok(call, "removeCSS routes to the native scripting bridge with method 'removeCSS'");
        assert.strictEqual(call[1].tabId, 7, "the target tabId is forwarded");
        assert.strictEqual(call[1].css, "body{color:red}", "the CSS to remove is forwarded");
        ok("tabs.removeCSS(tabId, {code}) routes to native removeCSS with the tabId + css");
    } catch (e) { bad("removeCSS routes", e); }

    try {
        scriptingCalls.length = 0;
        await tabs.removeCSS({ code: ".x{}" });   // omitted tabId (current tab) — must not be mistaken for details
        const call = scriptingCalls.find((c) => c[0] === "removeCSS");
        assert.ok(call, "removeCSS works with the (details) overload (tabId omitted)");
        assert.strictEqual(call[1].css, ".x{}", "the details.code is read when tabId is omitted");
        ok("tabs.removeCSS({code}) overload (current tab) is handled");
    } catch (e) { bad("removeCSS overload", e); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);   // the booted bg shim keeps timers alive; force exit
})();
