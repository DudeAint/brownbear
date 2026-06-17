//
//  tabs-enums.test.js
//  BrownBear
//
//  Chrome exposes the chrome.tabs enums as namespace constants in EVERY extension context (page/popup/options
//  AND the service-worker/background world): TabStatus, MutedInfoReason, WindowType, ZoomSettingsMode and
//  ZoomSettingsScope, plus the static TAB_ID_NONE sentinel. Extensions read them directly — Coupert's
//  background.js touches chrome.tabs.TabStatus.LOADING at boot — so an absent enum reads as `undefined` and a
//  `.LOADING` access throws "undefined is not an object" before the page/worker finishes booting.
//
//  This test asserts the enums exist with Chrome's EXACT literal values in BOTH worlds, that the page world
//  and the background world agree key-for-key (a divergence there is its own class of bug), and includes a
//  malformed-extraction guard that must FAIL CLOSED rather than silently pass. The page world is exercised by
//  extracting + building `tabsApi()` (same brace-match technique as tabs-static-constants.test.js); the
//  background world by booting the REAL brownbear-webext-background.js shim (same harness as
//  management-enums.test.js).
//
//  Pure Node, no deps. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/tabs-enums.test.js`.
//  Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const PAGE_SRC = fs.readFileSync(path.join(DIR, "brownbear-webext-page.js"), "utf8");
const EXT_ID = "tabsenumtestidaaaaaaaaaaaaaaaaaa";

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// The Chrome-faithful contract every world must satisfy. Values are Chrome's exact literals — a comparison
// like `tab.status === chrome.tabs.TabStatus.LOADING` must behave identically to real Chrome.
const TAB_ENUMS = {
    TabStatus: { UNLOADED: "unloaded", LOADING: "loading", COMPLETE: "complete" },
    MutedInfoReason: { USER: "user", CAPTURE: "capture", EXTENSION: "extension" },
    WindowType: { NORMAL: "normal", POPUP: "popup", PANEL: "panel", APP: "app", DEVTOOLS: "devtools" },
    ZoomSettingsMode: { AUTOMATIC: "automatic", MANUAL: "manual", DISABLED: "disabled" },
    ZoomSettingsScope: { PER_ORIGIN: "per-origin", PER_TAB: "per-tab" }
};

// --- page-world harness: extract + build tabsApi() from the page shim --------------------------------------
// Brace-match the body of `function tabsApi() { ... }` (same technique tabs-static-constants.test.js uses).
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

// Inject stubs for the free identifiers tabsApi() closes over (settle/bridge/makeEvent/tabEventLists plus the
// captured _Array/_Promise/Promise aliases). Reading static enum constants exercises none of them, but they
// must exist so the factory doesn't ReferenceError.
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
    const tabEventLists = new Proxy({}, { get: function () { return []; } });
    const tabsApi = factory(settle, bridge, makeEvent, tabEventLists, Array, Promise, Promise);
    return tabsApi();
}

// --- background-world harness: boot the real background shim ------------------------------------------------
function bootBackground() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp,
        Map, Set, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    const nullCb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { c(JSON.stringify(null)); } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set",
        "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_tabs_send_message", "__bb_management",
        "__bb_dnr", "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_fetch", "__bb_i18n_detect",
        "__bb_alarm_create", "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all"]) { sb[n] = nullCb; }
    sb.__bb_set_timeout = (fn, ms, r) => (r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0));
    sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bbBgExtId = EXT_ID; sb.__bbBgBaseURL = `chrome-extension://${EXT_ID}/`;
    sb.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1",
        background: { service_worker: "sw.js" }, permissions: ["tabs"] });
    sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb,
        { filename: "brownbear-webext-background.js" });
    return sb;
}

// Assert one world's tabs namespace carries every enum with Chrome's exact values + types.
function assertEnums(worldName, tabs) {
    Object.keys(TAB_ENUMS).forEach(function (enumName) {
        test(worldName + ": chrome.tabs." + enumName + " exists and is an object", function () {
            assert.ok(Object.prototype.hasOwnProperty.call(tabs, enumName), enumName + " missing from tabs namespace");
            assert.strictEqual(typeof tabs[enumName], "object", enumName + " must be an object");
            assert.ok(tabs[enumName] !== null, enumName + " must not be null");
            assert.ok(Object.keys(tabs).indexOf(enumName) >= 0, enumName + " must be enumerable");
        });
        const expected = TAB_ENUMS[enumName];
        Object.keys(expected).forEach(function (key) {
            test(worldName + ": chrome.tabs." + enumName + "." + key + " === '" + expected[key] + "'", function () {
                assert.strictEqual(tabs[enumName][key], expected[key],
                    enumName + "." + key + " should be '" + expected[key] + "' (got " + tabs[enumName][key] + ")");
            });
        });
        test(worldName + ": chrome.tabs." + enumName + " has no extra keys beyond Chrome's", function () {
            assert.deepStrictEqual(Object.keys(tabs[enumName]).sort(), Object.keys(expected).sort(),
                enumName + " key set must match Chrome exactly");
        });
    });
}

(function main() {
    const pageTabs = buildTabsApi(PAGE_SRC);
    const bgTabs = bootBackground().chrome.tabs;

    assertEnums("page", pageTabs);
    assertEnums("background", bgTabs);

    // The two worlds must agree key-for-key and value-for-value — a divergence is its own bug class (a guard
    // that passes in the popup but the service-worker reads a different/absent value). Compared key/value
    // explicitly rather than with deepStrictEqual: the page namespace is built in the host realm while the
    // background shim runs in a `vm` context, so the two objects carry different Object prototypes and a
    // cross-realm deepStrictEqual would throw on prototype identity even when every value matches.
    Object.keys(TAB_ENUMS).forEach(function (enumName) {
        test("page and background agree on chrome.tabs." + enumName, function () {
            const pageEnum = pageTabs[enumName], bgEnum = bgTabs[enumName];
            assert.deepStrictEqual(Object.keys(pageEnum).sort(), Object.keys(bgEnum).sort(),
                enumName + " key sets must match across worlds");
            Object.keys(pageEnum).forEach(function (key) {
                assert.strictEqual(pageEnum[key], bgEnum[key],
                    enumName + "." + key + " must be identical in the page and background worlds");
            });
        });
    });

    // The static numeric sentinel must survive alongside the new enums in both worlds.
    test("TAB_ID_NONE (-1) preserved in both worlds", function () {
        assert.strictEqual(pageTabs.TAB_ID_NONE, -1, "page TAB_ID_NONE");
        assert.strictEqual(bgTabs.TAB_ID_NONE, -1, "background TAB_ID_NONE");
    });

    // Adding enums must not disturb the existing method/event surface (page world).
    test("existing tabs methods + events still present (page)", function () {
        ["query", "get", "create", "update", "remove", "getZoom", "setZoom"].forEach(function (m) {
            assert.strictEqual(typeof pageTabs[m], "function", "tabs." + m + " should still be a function");
        });
        ["onCreated", "onUpdated", "onActivated", "onRemoved"].forEach(function (e) {
            assert.ok(pageTabs[e] && typeof pageTabs[e].addListener === "function",
                "tabs." + e + " should still expose addListener");
        });
    });

    // Malformed-input guard: a page shim whose tabsApi() has an unbalanced brace must FAIL CLOSED — extraction
    // throws rather than silently building a bogus (passing-but-wrong) namespace. Catches a future refactor
    // that breaks the brace-match out from under this test.
    test("malformed page source fails closed (no silent pass)", function () {
        const broken = PAGE_SRC.replace("function tabsApi() {", "function tabsApi() ");   // strip opening brace
        assert.throws(function () { buildTabsApi(broken); },
            "a tabsApi() with a missing opening brace must throw, not build a bogus namespace");
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed === 0 ? 0 : 1);   // the booted bg shim keeps timers alive; force exit
})();
