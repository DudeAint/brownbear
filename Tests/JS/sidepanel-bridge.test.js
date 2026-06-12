//
//  sidepanel-bridge.test.js
//  BrownBear
//
//  chrome.sidePanel ↔ native bridge. iOS has no docked panel, so open() presents the extension's
//  side-panel page as a sheet (native), while setOptions/setPanelBehavior state is held natively so
//  getOptions/getPanelBehavior round-trip and a toolbar tap can open the panel when openPanelOnActionClick
//  is set. The worker routes every sidePanel method through __bb_sidepanel(method, argsJSON, cb).
//
//  This boots the REAL background shim and asserts each method routes to the native bridge with the right
//  method name + args, that the getters surface the native result, and that when the bridge is ABSENT
//  (headless/test) the methods degrade to graceful no-ops (so a worker's init never throws).
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/sidepanel-bridge.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXT_ID = "sidepaneltestidaaaaaaaaaaaaaaaaa";
const BASE = `chrome-extension://${EXT_ID}/`;

// withBridge: install __bb_sidepanel (records calls + serves a tiny native state). withBridge=false omits
// it, so we can assert the graceful no-op fallback.
function bootWorker(withBridge) {
    const sb = {}; sb.globalThis = sb; sb.self = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp, Map, Set, WeakMap, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    const cb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { try { c(JSON.stringify(null)); } catch (e) { /* noop */ } } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set", "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr", "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_alarm_create", "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all", "__bb_fetch"]) { sb[n] = cb; }
    sb.__bb_set_timeout = (fn, ms, r) => r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0); sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bb_port_post = () => {}; sb.__bb_port_disconnect = () => {};
    sb.__bb_note_blocking_webrequest = () => {}; sb.__bb_note_action_onclicked = () => {};
    sb.sidePanelCalls = [];
    sb.nativeState = { path: null, enabled: true, openOnActionClick: false };
    if (withBridge) {
        sb.__bb_sidepanel = (method, argsJSON, callback) => {
            const args = JSON.parse(argsJSON);
            sb.sidePanelCalls.push({ method, args });
            let result = null;
            if (method === "setOptions") { if ("path" in args) { sb.nativeState.path = args.path; } if ("enabled" in args) { sb.nativeState.enabled = args.enabled; } }
            else if (method === "setPanelBehavior") { sb.nativeState.openOnActionClick = !!args.openPanelOnActionClick; }
            else if (method === "getOptions") { result = { path: sb.nativeState.path, enabled: sb.nativeState.enabled }; }
            else if (method === "getPanelBehavior") { result = { openPanelOnActionClick: sb.nativeState.openOnActionClick }; }
            callback(JSON.stringify(result));
        };
    }
    sb.__bbBgExtId = EXT_ID; sb.__bbBgBaseURL = BASE;
    sb.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1", background: { service_worker: "bg.js" }, side_panel: { default_path: "panel.html" }, permissions: ["sidePanel"] });
    sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb, { filename: "brownbear-webext-background.js" });
    return sb;
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

// open() routes to the native bridge as method "open".
(async () => {
    try {
        const w = bootWorker(true);
        const chrome = w.chrome || w.browser;
        await chrome.sidePanel.open({ tabId: 5 });
        const openCall = w.sidePanelCalls.find((c) => c.method === "open");
        assert.ok(openCall, "open() reaches __bb_sidepanel('open', …)");
        assert.strictEqual(openCall.args.tabId, 5, "open() forwards its options");
        ok("sidePanel.open() routes to native");
    } catch (e) { bad("open routes", e); }

    // setOptions({path}) then getOptions() round-trips the path through native state.
    try {
        const w = bootWorker(true);
        const chrome = w.chrome || w.browser;
        await chrome.sidePanel.setOptions({ path: "custom/panel.html", enabled: true });
        const set = w.sidePanelCalls.find((c) => c.method === "setOptions");
        assert.strictEqual(set.args.path, "custom/panel.html", "setOptions forwards the path");
        const opts = await chrome.sidePanel.getOptions({});
        assert.strictEqual(opts.path, "custom/panel.html", "getOptions surfaces the path native stored");
        assert.strictEqual(opts.enabled, true, "getOptions surfaces enabled");
        ok("setOptions/getOptions round-trip through native");
    } catch (e) { bad("setOptions/getOptions", e); }

    // setPanelBehavior / getPanelBehavior round-trip.
    try {
        const w = bootWorker(true);
        const chrome = w.chrome || w.browser;
        await chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true });
        const beh = await chrome.sidePanel.getPanelBehavior();
        assert.strictEqual(beh.openPanelOnActionClick, true, "getPanelBehavior surfaces what setPanelBehavior stored");
        ok("setPanelBehavior/getPanelBehavior round-trip");
    } catch (e) { bad("panel behavior", e); }

    // Without the native bridge, the methods are graceful no-ops (so a worker init never throws).
    try {
        const w = bootWorker(false);
        const chrome = w.chrome || w.browser;
        const o = await chrome.sidePanel.open();
        assert.strictEqual(o, undefined, "open() resolves undefined when the bridge is absent");
        // Realm-agnostic checks: the resolved objects are minted inside the worker's vm realm, so a
        // deepStrictEqual against a host-realm {} would fail on the prototype identity, not the value.
        const opts = await chrome.sidePanel.getOptions();
        assert.strictEqual(typeof opts, "object", "getOptions() resolves an object when the bridge is absent");
        assert.strictEqual(Object.keys(opts).length, 0, "getOptions() resolves {} when the bridge is absent");
        const beh = await chrome.sidePanel.getPanelBehavior();
        assert.strictEqual(beh.openPanelOnActionClick, false, "getPanelBehavior() resolves the default when absent");
        ok("graceful no-op when __bb_sidepanel is absent");
    } catch (e) { bad("no-op fallback", e); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
