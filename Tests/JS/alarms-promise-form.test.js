//
//  alarms-promise-form.test.js
//  BrownBear
//
//  chrome.alarms in the MV3 background service-worker shim must return a Promise when no callback is passed
//  (and still fire the callback when one is) — `browser.alarms.*` and `await chrome.alarms.getAll()` are the
//  normal MV3-worker form. The shim was callback-only, so `await chrome.alarms.get('x')` resolved to
//  undefined and an alarm-driven worker mis-fired. This boots the real background shim with stub
//  __bb_alarm_* natives and asserts both the promise and the callback forms (and the browser alias).
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/alarms-promise-form.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXT_ID = "alarmtestidaaaaaaaaaaaaaaaaaaaaa";

let passed = 0, failed = 0;
function test(name, fn) {
    return Promise.resolve().then(fn)
        .then(() => { console.log("  ok   " + name); passed++; })
        .catch((e) => { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; });
}

function bootBackground() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp,
        Map, Set, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout;
    sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    // A generic native stub: invoke the trailing callback with JSON null.
    const nullCb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { c(JSON.stringify(null)); } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set",
        "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr",
        "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_fetch"]) { sb[n] = nullCb; }
    sb.__bb_set_timeout = (fn, ms, r) => (r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0));
    sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    // Controlled alarm natives: a single alarm "refresh" exists.
    const ALARM = { name: "refresh", scheduledTime: 123, periodInMinutes: 5 };
    sb.__bb_alarm_create = () => {};   // fire-and-forget
    sb.__bb_alarm_get = (name, cb) => cb(JSON.stringify(name === "refresh" ? ALARM : null));
    sb.__bb_alarm_get_all = (cb) => cb(JSON.stringify([ALARM]));
    sb.__bb_alarm_clear = (name, cb) => cb(JSON.stringify(name === "refresh"));
    sb.__bb_alarm_clear_all = (cb) => cb(JSON.stringify(true));
    sb.__bbBgExtId = EXT_ID;
    sb.__bbBgBaseURL = `chrome-extension://${EXT_ID}/`;
    sb.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1",
        background: { service_worker: "sw.js" }, permissions: ["alarms"] });
    sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb,
        { filename: "brownbear-webext-background.js" });
    return sb;
}

(async function main() {
    console.log("chrome.alarms (MV3 background shim) returns Promises, not just callbacks");
    const sb = bootBackground();
    const chrome = sb.chrome;
    assert.ok(chrome && chrome.alarms, "chrome.alarms exists");

    await test("getAll() returns a Promise that resolves to an array", async () => {
        const result = chrome.alarms.getAll();
        assert.ok(result && typeof result.then === "function", "getAll() must return a thenable");
        const alarms = await result;
        assert.ok(Array.isArray(alarms) && alarms.length === 1 && alarms[0].name === "refresh");
    });

    await test("get(name) resolves the alarm, and an absent name resolves undefined", async () => {
        assert.strictEqual((await chrome.alarms.get("refresh")).name, "refresh");
        assert.strictEqual(await chrome.alarms.get("nope"), undefined);
    });

    await test("clear(name) resolves the boolean, clearAll() resolves true", async () => {
        assert.strictEqual(await chrome.alarms.clear("refresh"), true);
        assert.strictEqual(await chrome.alarms.clear("other"), false);
        assert.strictEqual(await chrome.alarms.clearAll(), true);
    });

    await test("create() returns a resolved Promise (Chrome 111+ form)", async () => {
        const result = chrome.alarms.create("x", { periodInMinutes: 1 });
        assert.ok(result && typeof result.then === "function");
        assert.strictEqual(await result, undefined);
    });

    await test("the callback form still fires (no regression)", async () => {
        const got = await new Promise((resolve) => { chrome.alarms.getAll((alarms) => resolve(alarms)); });
        assert.ok(Array.isArray(got) && got[0].name === "refresh");
        const one = await new Promise((resolve) => { chrome.alarms.get("refresh", (a) => resolve(a)); });
        assert.strictEqual(one.name, "refresh");
    });

    await test("browser.alarms (the webextension alias) is promise-bearing too", async () => {
        assert.ok(sb.browser && sb.browser.alarms, "browser.alarms exists");
        assert.ok(Array.isArray(await sb.browser.alarms.getAll()));
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed === 0 ? 0 : 1);   // the booted bg shim keeps timers alive; force exit
})();
