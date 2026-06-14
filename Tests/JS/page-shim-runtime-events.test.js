//
//  page-shim-runtime-events.test.js
//  BrownBear
//
//  chrome.runtime event surface of the extension-PAGE shim (brownbear-webext-page.js). A popup or
//  options page is a WKWebView over chrome-extension://; its own <script> tags run synchronously, so
//  chrome.runtime must already carry the SAME event surface Chrome puts on every extension page —
//  including the lifecycle/external/userScript events that never actually FIRE on a page.
//
//  Regression: Tampermonkey 5.x's popup (action.html → extension.js) builds its messaging wrapper at
//  boot with an UNGUARDED `chrome.runtime.onMessageExternal.addListener(...)` and
//  `chrome.runtime.onConnectExternal.addListener(...)`. The page shim only exposed onMessage/onConnect/
//  onInstalled, so those reads were `undefined` → "Cannot read properties of undefined (reading
//  'addListener')" threw during the popup's top-level script → the popup rendered BLANK. Fix: expose the
//  external / userScript / lifecycle runtime events as inert (spec-shaped) events on the page runtime.
//
//  Pure Node, no deps: boots the real page shim in a vm with the minimal document-start contract native
//  bakes into window.__bbExtPage. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/page-shim-runtime-events.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const PAGE_SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-page.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

/** Boot the page shim over a minimal extension-page window and return the assembled `window.chrome`. */
function bootPageShim(manifest) {
    const ID = "dhdgffkkebhmkfjojejmpbldmpobfkfo";   // a real (Tampermonkey) id shape; value is irrelevant
    const win = {};
    win.window = win; win.self = win; win.globalThis = win;
    win.console = console;
    win.navigator = { language: "en-US", userAgent: "Mozilla/5.0", serviceWorker: undefined };
    win.location = new URL("chrome-extension://" + ID + "/action.html");
    win.URL = URL; win.JSON = JSON; win.Object = Object; win.Array = Array;
    win.Promise = Promise; win.Error = Error;
    win.structuredClone = (typeof structuredClone === "function") ? structuredClone : (x) => JSON.parse(JSON.stringify(x));
    win.setTimeout = setTimeout; win.clearTimeout = clearTimeout;
    win.addEventListener = function () {}; win.removeEventListener = function () {}; win.dispatchEvent = function () { return false; };
    win.document = { addEventListener: function () {}, removeEventListener: function () {}, readyState: "complete", currentScript: null };
    win.fetch = undefined;   // skip the privileged cross-origin fetch wrapper (needs a real fetch)
    win.webkit = { messageHandlers: { brownbearWebext: { postMessage: function () { return Promise.resolve({}); } } } };
    win.__bbExtPage = {
        token: "tok-test",
        extensionId: ID,
        baseURL: "chrome-extension://" + ID + "/",
        manifestJSON: JSON.stringify(manifest || { manifest_version: 3, name: "t", version: "1" }),
        messages: {}
    };
    vm.createContext(win);
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js" });
    assert.ok(win.__brownbearExtPageReady === true, "page shim should mark itself ready");
    assert.ok(win.chrome && win.chrome.runtime, "page shim should expose chrome.runtime");
    return win.chrome;
}

function assertEvent(obj, name) {
    assert.ok(obj && typeof obj === "object", name + " should be an event object");
    assert.strictEqual(typeof obj.addListener, "function", name + ".addListener should be a function");
    assert.strictEqual(typeof obj.removeListener, "function", name + ".removeListener should be a function");
    assert.strictEqual(typeof obj.hasListener, "function", name + ".hasListener should be a function");
}

console.log("page-shim chrome.runtime event surface tests");

test("page runtime exposes the events the popup actually uses (onMessage/onConnect/onInstalled)", function () {
    const rt = bootPageShim().runtime;
    assertEvent(rt.onMessage, "runtime.onMessage");
    assertEvent(rt.onConnect, "runtime.onConnect");
    assertEvent(rt.onInstalled, "runtime.onInstalled");
});

test("page runtime exposes external + userScript events (Tampermonkey reads these unguarded at boot)", function () {
    const rt = bootPageShim().runtime;
    assertEvent(rt.onConnectExternal, "runtime.onConnectExternal");
    assertEvent(rt.onMessageExternal, "runtime.onMessageExternal");
    assertEvent(rt.onUserScriptConnect, "runtime.onUserScriptConnect");
    assertEvent(rt.onUserScriptMessage, "runtime.onUserScriptMessage");
});

test("page runtime exposes the SW-lifecycle events (inert on a page, but must exist)", function () {
    const rt = bootPageShim().runtime;
    assertEvent(rt.onStartup, "runtime.onStartup");
    assertEvent(rt.onSuspend, "runtime.onSuspend");
    assertEvent(rt.onSuspendCanceled, "runtime.onSuspendCanceled");
    assertEvent(rt.onUpdateAvailable, "runtime.onUpdateAvailable");
    assertEvent(rt.onRestartRequired, "runtime.onRestartRequired");
});

test("Tampermonkey's exact unguarded boot accesses no longer throw (popup boots instead of blanking)", function () {
    const rt = bootPageShim().runtime;
    // Verbatim shape of extension.js's wrapper `ot`: `function(e){return ke.runtime.onMessageExternal.addListener(e)}`
    assert.doesNotThrow(function () { rt.onMessageExternal.addListener(function () {}); },
        "onMessageExternal.addListener must not throw");
    assert.doesNotThrow(function () { rt.onConnectExternal.addListener(function () {}); },
        "onConnectExternal.addListener must not throw");
});

test("inert page events register listeners without firing them (no spurious popup callbacks)", function () {
    const rt = bootPageShim().runtime;
    let fired = false;
    const fn = function () { fired = true; };
    rt.onMessageExternal.addListener(fn);
    assert.ok(rt.onMessageExternal.hasListener(fn), "listener should be tracked");
    rt.onMessageExternal.removeListener(fn);
    assert.ok(!rt.onMessageExternal.hasListener(fn), "listener should be removable");
    assert.strictEqual(fired, false, "inert page event must never invoke its listeners");
});

// Regression for the SECOND Tampermonkey blank-popup cause (device Logs 2026-06-10, post-#224):
// "undefined is not an object (evaluating 'ye.webRequest.filterResponseData')" — the page shim had no
// chrome.webRequest, so the popup's unguarded read threw and the popup rendered blank again. The page
// shim must carry the namespaces every Chrome extension page has, not just the background's.
test("page chrome.webRequest exists with inert events + enums (popup reads it unguarded at boot)", function () {
    const c = bootPageShim();
    assert.ok(c.webRequest && typeof c.webRequest === "object", "chrome.webRequest must exist on the page");
    assertEvent(c.webRequest.onBeforeRequest, "webRequest.onBeforeRequest");
    assertEvent(c.webRequest.onHeadersReceived, "webRequest.onHeadersReceived");
    assertEvent(c.webRequest.onErrorOccurred, "webRequest.onErrorOccurred");
    assert.strictEqual(c.webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS, "extraHeaders",
        "webRequest enums must be present (managers read them)");
    assert.strictEqual(c.webRequest.ResourceType.MAIN_FRAME, "main_frame");
});

test("chrome.webRequest.filterResponseData is undefined (the correct 'not Firefox' signal) and never throws", function () {
    const c = bootPageShim();
    // The EXACT device crash: reading chrome.webRequest.filterResponseData. It must read as undefined
    // (Chrome has no such API — that's how managers detect they're NOT on Firefox), not throw.
    let value, threw = false;
    try { value = c.webRequest.filterResponseData; } catch (e) { threw = true; }
    assert.strictEqual(threw, false, "reading filterResponseData must not throw");
    assert.strictEqual(value, undefined, "filterResponseData must be undefined (Firefox-only)");
});

test("page shim carries the rest of the namespaces Tampermonkey's popup reads (alarms/commands/declarativeContent)", function () {
    const c = bootPageShim();
    // alarms — page reads !chrome.alarms unguarded; the object must exist.
    assert.ok(c.alarms && typeof c.alarms.create === "function", "chrome.alarms must exist");
    assertEvent(c.alarms.onAlarm, "alarms.onAlarm");
    assert.doesNotThrow(function () { c.alarms.getAll(function () {}); }, "alarms.getAll must not throw");
    // commands — getAll + events.
    assert.ok(c.commands && typeof c.commands.getAll === "function", "chrome.commands must exist");
    assertEvent(c.commands.onCommand, "commands.onCommand");
    // declarativeContent — onPageChanged (declarative event) + the rule-class constructors.
    assert.ok(c.declarativeContent && c.declarativeContent.onPageChanged, "chrome.declarativeContent must exist");
    assert.strictEqual(typeof c.declarativeContent.PageStateMatcher, "function", "PageStateMatcher constructor present");
    assert.doesNotThrow(function () { c.declarativeContent.onPageChanged.addListener(function () {}); },
        "declarativeContent.onPageChanged.addListener must not throw");
});

// Regression for VeePN's blank popup (device Logs 2026-06-10): "[bb page bundle] ... undefined is not an
// object (evaluating 'super()')". It was NOT a linker/super() bug — VeePN's popup reads
// chrome.privacy.network.webRTCIPHandlingPolicy (then chrome.proxy.settings) in CLASS FIELD INITIALIZERS
// at module-eval, and the page shim had neither namespace (only the background shim did). The undefined
// read threw inside a constructor; JSC attributed it to the enclosing super(). The page shim must mirror
// the background's privacy/proxy ChromeSetting surfaces.
function assertChromeSetting(s, name) {
    assert.ok(s && typeof s === "object", name + " must be a ChromeSetting object");
    assert.strictEqual(typeof s.get, "function", name + ".get");
    assert.strictEqual(typeof s.set, "function", name + ".set");
    assert.strictEqual(typeof s.clear, "function", name + ".clear");
    assertEvent(s.onChange, name + ".onChange");
}

test("page chrome.privacy mirrors the background ChromeSetting surface (VeePN reads it at module-eval)", function () {
    const c = bootPageShim();
    assert.ok(c.privacy && c.privacy.network, "chrome.privacy.network must exist");
    assertChromeSetting(c.privacy.network.webRTCIPHandlingPolicy, "privacy.network.webRTCIPHandlingPolicy");
    assertChromeSetting(c.privacy.network.networkPredictionEnabled, "privacy.network.networkPredictionEnabled");
    assertChromeSetting(c.privacy.websites.hyperlinkAuditingEnabled, "privacy.websites.hyperlinkAuditingEnabled");
    assertChromeSetting(c.privacy.services.passwordSavingEnabled, "privacy.services.passwordSavingEnabled");
    // The EXACT VeePN access must not throw and must read as a ChromeSetting (not undefined).
    let threw = false;
    try { void c.privacy.network.webRTCIPHandlingPolicy.get; } catch (e) { threw = true; }
    assert.strictEqual(threw, false, "reading chrome.privacy.network.webRTCIPHandlingPolicy must not throw");
});

test("page chrome.proxy.settings is a ChromeSetting (VeePN's VPN popup reads it next)", function () {
    const c = bootPageShim();
    assert.ok(c.proxy, "chrome.proxy must exist on the page");
    assertChromeSetting(c.proxy.settings, "proxy.settings");
    assertEvent(c.proxy.onProxyError, "proxy.onProxyError");
    // VeePN reads chrome.proxy.settings in a field initializer; the chain must resolve, not throw.
    assert.doesNotThrow(function () { c.proxy.settings.get({}, function () {}); }, "proxy.settings.get must not throw");
});

// Proactive page-shim ⇄ background-shim PARITY. Every popup-blank this round was a namespace the
// background shim had but the page shim lacked, read at popup boot. Rather than fix them one device
// report at a time, the page shim now mirrors every page-legitimate background namespace. This test
// guards the whole set so a future trim can't silently reintroduce the blank-popup class of bug.
test("page shim exposes every page-legitimate namespace the background shim has (parity)", function () {
    const c = bootPageShim();
    const NS = ["runtime", "tabs", "windows", "storage", "cookies", "i18n", "permissions", "management",
        "scripting", "action", "contextMenus", "notifications", "webNavigation", "webRequest", "alarms",
        "commands", "declarativeContent", "declarativeNetRequest", "privacy", "proxy", "idle", "downloads",
        "bookmarks", "history", "sessions", "search", "pageAction", "sidePanel", "offscreen", "system",
        "tabCapture", "desktopCapture", "tts", "ttsEngine", "dom", "extension", "identity", "userScripts"];
    const missing = NS.filter(function (n) { return !c[n]; });
    assert.strictEqual(missing.length, 0, "page shim missing namespaces: " + missing.join(", "));
    // chrome.devtools is intentionally absent — Chrome only exposes it in a devtools_page context.
    assert.strictEqual(c.devtools, undefined, "chrome.devtools must NOT be on a normal page");
});

test("page-legitimate namespace members resolve without throwing (popup boot reads them)", function () {
    const c = bootPageShim();
    assert.doesNotThrow(function () {
        c.idle.queryState(30, function () {}); c.idle.onStateChanged.addListener(function () {});
        c.downloads.search({}, function () {}); c.downloads.onChanged.addListener(function () {});
        c.bookmarks.getTree(function () {}); c.history.search({ text: "" }, function () {});
        c.sessions.getRecentlyClosed(function () {}); c.search.query({ text: "x" }, function () {});
        c.system.cpu.getInfo(function () {}); c.system.display.getInfo(function () {});
        c.tabCapture.getCapturedTabs(function () {}); c.desktopCapture.chooseDesktopMedia(["screen"], function () {});
        c.tts.getVoices(function () {}); c.tts.speak("x", {}); c.ttsEngine.onSpeak.addListener(function () {});
        c.sidePanel.getOptions(function () {}); c.offscreen.hasDocument(function () {});
        c.pageAction.onClicked.addListener(function () {}); c.dom.openOrClosedShadowRoot(null);
    }, "no page-legitimate namespace member may throw at popup boot");
});

// Regression for iCloud Passwords (device Logs 2026-06-10): its BACKGROUND reads
// chrome.webNavigation.onTabReplaced.addListener UNGUARDED at boot. The event was missing from both
// shims -> "undefined is not an object" aborted its service worker. WKWebView never fires onTabReplaced
// (no tab-replacement), but the event object must exist. (Tested on the page shim here; the background
// shim's onTabReplaced is covered by the extension marathon's core webNavigation assertions.)
test("page chrome.webNavigation has onTabReplaced + onReferenceFragmentUpdated (inert, but must exist)", function () {
    const c = bootPageShim();
    assertEvent(c.webNavigation.onTabReplaced, "webNavigation.onTabReplaced");
    assertEvent(c.webNavigation.onReferenceFragmentUpdated, "webNavigation.onReferenceFragmentUpdated");
    assert.doesNotThrow(function () { c.webNavigation.onTabReplaced.addListener(function () {}); },
        "onTabReplaced.addListener must not throw (iCloud Passwords reads it at boot)");
});

// Chrome exposes the declarativeNetRequest LIMIT constants in EVERY extension context (a popup or
// options page reads e.g. MAX_NUMBER_OF_DYNAMIC_RULES to show "X / limit rules used"), so the page
// shim must carry the same set Chrome 121+ does — and the SAME values as our background shim, or a
// `rules.length < MAX_…` guard would compare against undefined. Regression guard: the page block had
// duplicate keys and was missing the per-bucket limits Chrome 121 split out.
test("page chrome.declarativeNetRequest exposes the Chrome 121 limit constants (matches background)", function () {
    const dnr = bootPageShim().declarativeNetRequest;
    const expected = {
        DYNAMIC_RULESET_ID: "_dynamic", SESSION_RULESET_ID: "_session",
        MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000,
        MAX_NUMBER_OF_SESSION_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
        MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000,
        MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
        GUARANTEED_MINIMUM_STATIC_RULES: 30000,
        GETMATCHEDRULES_QUOTA_INTERVAL: 600, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20
    };
    Object.keys(expected).forEach(function (key) {
        assert.strictEqual(dnr[key], expected[key], "declarativeNetRequest." + key + " must be " + expected[key]);
    });
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
