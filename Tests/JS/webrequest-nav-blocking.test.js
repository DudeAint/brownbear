//
//  webrequest-nav-blocking.test.js
//  BrownBear
//
//  chrome.webRequest blocking on FRAME navigations — the one request class WKWebView lets us intercept
//  (WKNavigationDelegate). Static subresources (img/script/xhr) have no WebKit hook, but ad IFRAMES and
//  redirect-trackers ARE navigations, so an MV2 webRequest blocker (uBO/ABP/AdBlock) can block them. The
//  worker exposes __bbWebRequestNavDecision(url,type,tabId) — runs the registered blocking onBeforeRequest
//  listeners and returns the aggregate decision JSON ({"cancel":true} / {"redirectUrl":…} / "") — which the
//  native nav delegate applies; and __bbHasBlockingWebRequest() so native gates the dispatch to pages where
//  a blocking webRequest extension is actually present.
//
//  This boots the REAL background shim, registers blocking onBeforeRequest listeners exactly as an
//  extension would, and asserts the decision + the gate flag + the native notify.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/webrequest-nav-blocking.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXT_ID = "webreqtestidaaaaaaaaaaaaaaaaaaaa";
const BASE = `chrome-extension://${EXT_ID}/`;

let noteBlockingCalls = 0;

function bootWorker() {
    const sb = {}; sb.globalThis = sb; sb.self = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp, Map, Set, WeakMap, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    const cb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { try { c(JSON.stringify(null)); } catch (e) { /* noop */ } } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set", "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr", "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_alarm_create", "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all", "__bb_fetch"]) { sb[n] = cb; }
    sb.__bb_set_timeout = (fn, ms, r) => r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0); sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bb_port_post = () => {}; sb.__bb_port_disconnect = () => {};
    sb.__bb_note_blocking_webrequest = () => { noteBlockingCalls++; };   // the native gate-notify
    sb.__bbBgExtId = EXT_ID; sb.__bbBgBaseURL = BASE; sb.__bbBgManifest = JSON.stringify({ manifest_version: 2, name: "t", version: "1", background: { scripts: ["bg.js"] }, permissions: ["webRequest", "webRequestBlocking", "<all_urls>"] }); sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb, { filename: "brownbear-webext-background.js" });
    return sb;
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

const w = bootWorker();
const chrome = w.chrome || w.browser;

// Before any listener: not flagged, decision is allow.
try {
    assert.strictEqual(w.__bbHasBlockingWebRequest(), false, "no blocking listener yet → flag false");
    assert.strictEqual(w.__bbWebRequestNavDecision("https://ads.example.com/x", "sub_frame", 1), "", "no listener → allow ('')");
    ok("clean state: no blocking listener, allow");
} catch (e) { bad("clean state", e); }

// Register a blocking onBeforeRequest that cancels ads.example.com — exactly as a webRequest blocker does.
try {
    chrome.webRequest.onBeforeRequest.addListener(
        function (details) { return /:\/\/ads\.example\.com\//.test(details.url) ? { cancel: true } : {}; },
        { urls: ["*://ads.example.com/*"], types: ["sub_frame", "main_frame"] },
        ["blocking"]
    );
    assert.strictEqual(w.__bbHasBlockingWebRequest(), true, "registering a blocking listener flags the worker");
    assert.strictEqual(noteBlockingCalls, 1, "native is notified exactly once that a blocking webRequest extension is present");
    ok("registering a blocking onBeforeRequest flags + notifies native");
} catch (e) { bad("register", e); }

// A matching sub_frame navigation → cancel.
try {
    const d = w.__bbWebRequestNavDecision("https://ads.example.com/banner.html", "sub_frame", 1);
    assert.deepStrictEqual(JSON.parse(d), { cancel: true }, "an ad iframe is cancelled");
    ok("matching sub_frame → {cancel:true} (ad iframe blocked)");
} catch (e) { bad("cancel", e); }

// A non-matching navigation → allow.
try {
    assert.strictEqual(w.__bbWebRequestNavDecision("https://news.example.org/", "sub_frame", 1), "", "an unrelated iframe is allowed");
    ok("non-matching sub_frame → '' (allowed)");
} catch (e) { bad("allow", e); }

// A type filter excludes it: a listener scoped to sub_frame only must not fire on a main_frame nav.
try {
    const w2 = bootWorker();
    const c2 = w2.chrome || w2.browser;
    c2.webRequest.onBeforeRequest.addListener(
        function () { return { cancel: true }; },
        { urls: ["*://ads.example.com/*"], types: ["sub_frame"] }, ["blocking"]);
    assert.deepStrictEqual(JSON.parse(w2.__bbWebRequestNavDecision("https://ads.example.com/x", "sub_frame", 1)), { cancel: true }, "fires for sub_frame");
    assert.strictEqual(w2.__bbWebRequestNavDecision("https://ads.example.com/x", "main_frame", 1), "", "type filter excludes main_frame");
    ok("type filter honored (sub_frame-only listener doesn't block main_frame)");
} catch (e) { bad("type filter", e); }

// redirectUrl decision round-trips.
try {
    const w3 = bootWorker();
    const c3 = w3.chrome || w3.browser;
    c3.webRequest.onBeforeRequest.addListener(
        function () { return { redirectUrl: "https://surrogate.local/blank.html" }; },
        { urls: ["*://tracker.example.com/*"] }, ["blocking"]);
    assert.deepStrictEqual(JSON.parse(w3.__bbWebRequestNavDecision("https://tracker.example.com/p", "sub_frame", 2)),
        { redirectUrl: "https://surrogate.local/blank.html" }, "redirect decision is surfaced");
    ok("redirectUrl decision round-trips");
} catch (e) { bad("redirect", e); }

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
