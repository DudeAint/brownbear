//
//  management-enums.test.js
//  BrownBear
//
//  Two Chrome-faithful background-surface additions found in an extension boot sweep:
//   - chrome.runtime.onSuspendCanceled (Chrome's lifecycle pair with onSuspend; Dashlane registers it — its
//     absence threw "Cannot read properties of undefined (reading 'addListener')").
//   - chrome.management's enum constants (ExtensionInstallType etc.; Avira reads ExtensionInstallType.NORMAL).
//  Boots the REAL background shim and asserts both, with the exact Chrome values so a comparison behaves
//  identically.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/management-enums.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXT_ID = "mgmtenumtestidaaaaaaaaaaaaaaaaaa";

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
        "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_fetch", "__bb_alarm_create",
        "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all"]) { sb[n] = nullCb; }
    sb.__bb_set_timeout = (fn, ms, r) => (r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0));
    sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bbBgExtId = EXT_ID; sb.__bbBgBaseURL = `chrome-extension://${EXT_ID}/`;
    sb.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1",
        background: { service_worker: "sw.js" }, permissions: ["management"] });
    sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb,
        { filename: "brownbear-webext-background.js" });
    return sb;
}

let passed = 0, failed = 0;
const test = (n, fn) => { try { fn(); console.log("  ok   " + n); passed++; } catch (e) { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; } };

(function main() {
    const sb = bootBackground();
    const chrome = sb.chrome;

    test("chrome.runtime.onSuspendCanceled is a registerable event (pairs with onSuspend)", () => {
        assert.strictEqual(typeof chrome.runtime.onSuspend.addListener, "function", "onSuspend exists");
        assert.ok(chrome.runtime.onSuspendCanceled, "onSuspendCanceled exists");
        assert.strictEqual(typeof chrome.runtime.onSuspendCanceled.addListener, "function",
            "onSuspendCanceled.addListener is callable (no 'undefined.addListener' throw)");
        chrome.runtime.onSuspendCanceled.addListener(() => {});   // must not throw
    });

    test("chrome.management.ExtensionInstallType carries Chrome's values", () => {
        const t = chrome.management.ExtensionInstallType;
        assert.ok(t, "ExtensionInstallType exists");
        assert.strictEqual(t.NORMAL, "normal");
        assert.strictEqual(t.ADMIN, "admin");
        assert.strictEqual(t.DEVELOPMENT, "development");
        assert.strictEqual(t.SIDELOAD, "sideload");
        assert.strictEqual(t.OTHER, "other");
    });

    test("chrome.management carries the other enum constants Chrome exposes", () => {
        assert.strictEqual(chrome.management.ExtensionType.THEME, "theme");
        assert.strictEqual(chrome.management.ExtensionDisabledReason.PERMISSIONS_INCREASE, "permissions_increase");
        assert.strictEqual(chrome.management.LaunchType.OPEN_AS_WINDOW, "OPEN_AS_WINDOW");
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed === 0 ? 0 : 1);   // the booted bg shim keeps timers alive; force exit
})();
