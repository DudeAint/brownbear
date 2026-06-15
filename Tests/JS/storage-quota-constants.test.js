//
//  storage-quota-constants.test.js
//  BrownBear
//
//  chrome.storage.<area> must expose Chrome's documented numeric quota constants (QUOTA_BYTES,
//  QUOTA_BYTES_PER_ITEM, MAX_ITEMS, MAX_WRITE_OPERATIONS_PER_*). Scripts size their writes against them
//  (e.g. Stylus chunks sync writes against QUOTA_BYTES_PER_ITEM), so their absence reads as undefined and
//  mis-sizes a batch. `managed` is read-only and carries none. This boots the real background shim and
//  asserts the constants on each area.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/storage-quota-constants.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXT_ID = "storagetestidaaaaaaaaaaaaaaaaaaa";

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

function bootBackground() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp,
        Map, Set, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout;
    sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    const nullCb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { c(JSON.stringify(null)); } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set",
        "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr",
        "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_fetch", "__bb_alarm_create",
        "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all"]) { sb[n] = nullCb; }
    sb.__bb_set_timeout = (fn, ms, r) => (r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0));
    sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bbBgExtId = EXT_ID;
    sb.__bbBgBaseURL = `chrome-extension://${EXT_ID}/`;
    sb.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1",
        background: { service_worker: "sw.js" }, permissions: ["storage"] });
    sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb,
        { filename: "brownbear-webext-background.js" });
    return sb;
}

(function main() {
    console.log("chrome.storage.<area> exposes Chrome's quota constants");
    const sb = bootBackground();
    const storage = sb.chrome && sb.chrome.storage;
    assert.ok(storage, "chrome.storage exists");

    test("sync carries the full quota constant set (Chrome values)", () => {
        assert.strictEqual(storage.sync.QUOTA_BYTES, 102400);
        assert.strictEqual(storage.sync.QUOTA_BYTES_PER_ITEM, 8192);
        assert.strictEqual(storage.sync.MAX_ITEMS, 512);
        assert.strictEqual(storage.sync.MAX_WRITE_OPERATIONS_PER_HOUR, 1800);
        assert.strictEqual(storage.sync.MAX_WRITE_OPERATIONS_PER_MINUTE, 120);
    });

    test("local and session carry QUOTA_BYTES (10 MB) and no per-item cap", () => {
        assert.strictEqual(storage.local.QUOTA_BYTES, 10485760);
        assert.strictEqual(storage.session.QUOTA_BYTES, 10485760);
        assert.strictEqual(storage.local.QUOTA_BYTES_PER_ITEM, undefined, "local has no per-item quota");
    });

    test("managed (read-only) carries no quota constant", () => {
        assert.strictEqual(storage.managed.QUOTA_BYTES, undefined);
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed === 0 ? 0 : 1);   // the booted bg shim keeps timers alive; force exit
})();
