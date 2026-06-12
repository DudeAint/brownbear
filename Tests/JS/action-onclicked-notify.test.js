//
//  action-onclicked-notify.test.js
//  BrownBear
//
//  chrome.action / chrome.pageAction onClicked listener detection. The toolbar tap path needs to tell a
//  click-handling extension from a configure-only one: an action with NO popup AND no onClicked handler
//  should open the extension's options page (what a user expects) instead of firing a click nothing is
//  listening for. The worker flags native via __bb_note_action_onclicked() the first time an
//  action/pageAction.onClicked listener registers; native records it per-extension and reads it on tap.
//
//  This boots the REAL background shim and asserts the notify fires exactly once, on the first listener,
//  for BOTH chrome.action.onClicked and chrome.pageAction.onClicked (which share the listener list).
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/action-onclicked-notify.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXT_ID = "actionclicktestidaaaaaaaaaaaaaaa";
const BASE = `chrome-extension://${EXT_ID}/`;

function bootWorker() {
    const sb = {}; sb.globalThis = sb; sb.self = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp, Map, Set, WeakMap, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    const cb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { try { c(JSON.stringify(null)); } catch (e) { /* noop */ } } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set", "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr", "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_alarm_create", "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all", "__bb_fetch"]) { sb[n] = cb; }
    sb.__bb_set_timeout = (fn, ms, r) => r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0); sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bb_port_post = () => {}; sb.__bb_port_disconnect = () => {};
    sb.__bb_note_blocking_webrequest = () => {};
    sb.noteActionClickedCalls = 0;
    sb.__bb_note_action_onclicked = () => { sb.noteActionClickedCalls++; };   // the native tap-path notify
    sb.__bbBgExtId = EXT_ID; sb.__bbBgBaseURL = BASE;
    // A configure-only action: an action with NO default_popup, plus an options page. This is the case the
    // tap path resolves to "open options" when no onClicked handler is registered.
    sb.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1", background: { service_worker: "bg.js" }, action: {}, options_ui: { page: "options.html" } });
    sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb, { filename: "brownbear-webext-background.js" });
    return sb;
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

// Before any listener: native is never notified (so the tap path falls through to "open options").
try {
    const w = bootWorker();
    assert.strictEqual(w.noteActionClickedCalls, 0, "booting alone does not notify native of an onClicked handler");
    ok("clean state: no onClicked listener → no notify");
} catch (e) { bad("clean state", e); }

// Registering chrome.action.onClicked notifies native exactly once.
try {
    const w = bootWorker();
    const chrome = w.chrome || w.browser;
    chrome.action.onClicked.addListener(function () {});
    assert.strictEqual(w.noteActionClickedCalls, 1, "first action.onClicked listener notifies native once");
    // A second listener must NOT re-notify — the flag is set once (matches the webRequest gate's idempotency).
    chrome.action.onClicked.addListener(function () {});
    assert.strictEqual(w.noteActionClickedCalls, 1, "a second listener does not re-notify");
    // The listener is genuinely registered (not swallowed by the notify wrapper).
    assert.strictEqual(typeof chrome.action.onClicked.hasListeners, "function", "onClicked is a real event");
    assert.strictEqual(chrome.action.onClicked.hasListeners(), true, "the listener is actually held");
    ok("action.onClicked: first listener notifies once, second does not, listener is held");
} catch (e) { bad("action.onClicked", e); }

// pageAction.onClicked (MV2 alias, shares the same listener list) also notifies native.
try {
    const w = bootWorker();
    const chrome = w.chrome || w.browser;
    chrome.pageAction.onClicked.addListener(function () {});
    assert.strictEqual(w.noteActionClickedCalls, 1, "first pageAction.onClicked listener notifies native once");
    ok("pageAction.onClicked notifies native too");
} catch (e) { bad("pageAction.onClicked", e); }

// A non-function argument must not notify (Chrome ignores it; we must not flag a phantom handler).
try {
    const w = bootWorker();
    const chrome = w.chrome || w.browser;
    chrome.action.onClicked.addListener(undefined);
    assert.strictEqual(w.noteActionClickedCalls, 0, "a non-function addListener arg does not notify");
    ok("non-function addListener arg → no notify");
} catch (e) { bad("non-function arg", e); }

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
