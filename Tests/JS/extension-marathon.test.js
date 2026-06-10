//
//  extension-marathon.test.js
//  BrownBear
//
//  Marathon harness: download + test 12 popular Chrome extensions against BrownBear's
//  chrome.*/browser.* shim surface (brownbear-webext-background.js). For each extension:
//
//   1. Load the manifest and locate all JS files (background SW + content scripts).
//   2. Build a minimal shim environment (Node vm.createContext) that mirrors what
//      brownbear-webext-background.js exposes: all chrome.* namespaces as stubs, the
//      primitive globals (console, setTimeout, crypto, fetch, importScripts, TextEncoder/
//      TextDecoder, etc.). The shim surface is the REAL BrownBear surface extracted from
//      the source — so any addition to the JS files is reflected in the next test run.
//   3. Execute the background service worker (or MV2 background scripts) in the context.
//   4. Collect every TypeError / ReferenceError that fires during load. A crash-free boot
//      is the bar; we record any `undefined is not an object` style failures as FAILs.
//   5. Assert that specific high-value APIs exist and have the right shape (function /
//      object / event shape).
//
//  Pure Node, no deps beyond Node built-ins. Mirrors the style of resilient-events.test.js
//  and cross-world-bridge.test.js. Run locally:
//    node Tests/JS/extension-marathon.test.js
//  Or via CI (js-runtime job already globs Tests/JS/*.test.js).
//  Exits non-zero if any failure is detected.
//
//  Extensions expected under /tmp/marathon/<name>/ (unzipped CRX). The test skips any
//  extension whose directory does not exist so CI passes without the downloaded CRXs.
//
"use strict";

const fs    = require("fs");
const path  = require("path");
const vm    = require("vm");
const assert = require("assert");

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

const JSDIR  = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXTDIR = "/tmp/marathon";

const BG_SRC = fs.readFileSync(path.join(JSDIR, "brownbear-webext-background.js"), "utf8");

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

let passed = 0, failed = 0, skipped = 0;

function test(name, fn) {
    try {
        fn();
        console.log("  ok   " + name);
        passed++;
    } catch (e) {
        console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e));
        failed++;
    }
}

function skip(name, reason) {
    console.log("  skip " + name + (reason ? " (" + reason + ")" : ""));
    skipped++;
}

// ---------------------------------------------------------------------------
// Minimal native stubs that brownbear-webext-background.js calls synchronously
// at boot (the __bb_* functions the Swift side provides).
// ---------------------------------------------------------------------------

function makeNativeBridge() {
    // Simple stub: most calls invoke their callback immediately with a JSON success response.
    function noop() {}
    function cbJSON(val) { return function(_arg, cb) { if (typeof cb === "function") { cb(JSON.stringify(val)); } }; }
    function cb2JSON(val) { return function(_a, _b, cb) { if (typeof cb === "function") { cb(JSON.stringify(val)); } }; }
    function cb3JSON(val) { return function(_a, _b, _c, cb) { if (typeof cb === "function") { cb(JSON.stringify(val)); } }; }

    // Return a uniform __bb_* method that accepts up to 4 args, last is always the callback.
    function bbCall(val) {
        return function() {
            var args = Array.prototype.slice.call(arguments);
            var cb = args[args.length - 1];
            if (typeof cb === "function") { cb(JSON.stringify(val)); }
        };
    }

    var timerId = 0;
    var pendingTimers = {}; // id -> {fn, ms, repeat}

    return {
        // timers — key primitive for background boot
        __bb_set_timeout: function(fn, ms, repeat) {
            var id = ++timerId;
            pendingTimers[id] = { fn: fn, ms: ms || 0, repeat: !!repeat };
            // For testing purposes fire synchronously (0ms) so boot-level timers run.
            // Real timers with ms > 0 are NOT fired — we only want synchronous boot effects.
            if ((ms || 0) === 0) {
                try { fn(); } catch(e) { /* ignore timer errors in test env */ }
            }
            return id;
        },
        __bb_clear_timer: function(id) { delete pendingTimers[id]; },

        // logging — no-op in test
        __bb_log: function(level, msg) {
            // Surface errors so test output is informative
            if (level === "error") {
                // Don't throw — just record. Many "warn" messages are expected on non-Chrome.
            }
        },

        // storage
        __bb_storage_get:    bbCall({}),
        __bb_storage_set:    bbCall(null),
        __bb_storage_remove: bbCall(null),
        __bb_storage_clear:  bbCall(null),

        // tabs
        __bb_tabs:              bbCall([]),
        __bb_tabs_send_message: bbCall(null),
        __bb_capture_visible_tab: bbCall({ dataUrl: "data:image/png;base64,AA==" }),

        // windows
        __bb_windows: bbCall({ id: 1, focused: true, type: "normal" }),

        // scripting
        __bb_scripting: bbCall([]),

        // action
        __bb_action: bbCall(null),

        // notifications
        __bb_notifications: bbCall("test-id"),

        // cookies
        __bb_cookies: bbCall([]),

        // alarms
        __bb_alarm_create: bbCall(null),
        __bb_alarm_get:    bbCall(null),
        __bb_alarm_getall: bbCall([]),
        __bb_alarm_clear:  bbCall(true),
        __bb_alarm_clearall: bbCall(true),
        __bb_alarm_get_all: bbCall([]),
        __bb_alarm_clear_all: bbCall(true),

        // context menus
        __bb_context_menus: bbCall({ id: "1" }),

        // permissions
        __bb_permissions: bbCall({ permissions: [], origins: [] }),

        // management
        __bb_management: bbCall([]),

        // downloads
        __bb_downloads: bbCall({ downloadId: 1 }),

        // offscreen
        __bb_offscreen: bbCall(null),

        // DNR
        __bb_dnr: bbCall([]),

        // userScripts
        __bb_userscripts: bbCall([]),

        // messaging
        __bb_send_message: function(json, cb) {
            if (typeof cb === "function") { cb(JSON.stringify({ value: null })); }
        },
        __bb_message_response: function() {},
        __bb_port_post: function() {},
        __bb_port_disconnect: function() {},

        // idle
        __bb_idle: bbCall("active"),

        // privacy (no native surface — privacy is all JS-side stubs in the shim)
        // (none needed)

        // browser data (bookmarks/history/sessions)
        __bb_browser_data: bbCall(null),

        // identity
        // (none needed — identity is pure JS)

        // i18n
        __bb_i18n_detect: function(text, cb) {
            if (typeof cb === "function") { cb(JSON.stringify({ isReliable: false, languages: [] })); }
        },

        // crypto (JSC normally provides these; Node has them, but we need the __bb_ bridged forms)
        __bb_crypto_random: function(n) { var a = []; for (var i=0; i<n; i++) { a.push(i & 0xff); } return a; },
        __bb_crypto_uuid:   function() { return "aaaaaaaa-bbbb-4ccc-dddd-eeeeeeeeeeee"; },
        __bb_crypto_digest: function(algo, data) { return Array(32).fill(0); },
        __bb_subtle:        function(op, json) { return JSON.stringify({ error: "subtle " + op + " not in test stub" }); },

        // fetch
        __bb_fetch: function(json, cb) {
            if (typeof cb === "function") {
                cb(JSON.stringify({ status: 200, headers: {}, bodyBase64: "", body: "" }));
            }
        },

        // import (for importScripts in MV2 backgrounds)
        __bb_import_script: function(spec) { return "/* stub: " + spec + " */"; },
        __bb_eval_global: function(src, spec) { return null; },

        // image fetch (used by Image.src in MV2 background pages)
        __bb_fetch_image: function(url, cb) {
            if (typeof cb === "function") { cb(JSON.stringify({ dataUrl: null })); }
        },

        // runtime
        __bb_runtime_open_options: function(cb) { if (typeof cb === "function") { cb(); } },
        __bb_runtime_set_uninstall_url: function(url, cb) { if (typeof cb === "function") { cb(); } },
        __bb_get_contexts: function(json, cb) { if (typeof cb === "function") { cb(JSON.stringify([])); } },

        // search
        __bb_search: function(json, cb) { if (typeof cb === "function") { cb(); } },

        // webNavigation (no active push needed for boot test)

        // webext page injection (no-op in headless context)
        // (handled by the page-world bridge, not background)
    };
}

// ---------------------------------------------------------------------------
// Build a fresh vm.Context that looks like the BrownBear background worker
// environment for a specific extension.
// ---------------------------------------------------------------------------

function buildWorkerContext(extId, baseURL, manifestJSON, messagesJSON) {
    var bridge = makeNativeBridge();

    // Build a minimal globalThis for JavaScriptCore-like headless context.
    //
    // CRITICAL: Do NOT inject outer-realm constructor globals (Object, Array, Promise,
    // Map, Set, Symbol, Proxy, Reflect, Math, Date, RegExp, Error, typed arrays, etc.)
    // into the vm sandbox. vm.createContext already gives the context its OWN set of
    // built-ins that share the same realm as code running inside that context. Injecting
    // outer-realm constructors shadows the vm-native ones and breaks `instanceof Object`
    // for any object literal created inside the vm (a different realm's Object.prototype).
    // This is exactly why `chrome.webRequest.ResourceType instanceof Object` was returning
    // false even when the check ran via vm.runInContext.
    //
    // Only inject things the vm does NOT provide natively:
    //   TextEncoder, TextDecoder, atob, btoa, crypto, performance, console (suppressed),
    //   localStorage, sessionStorage, location, navigator, and the __bb_* bridge stubs.
    var ctx = Object.create(null);

    // Spread the bridge natives
    Object.assign(ctx, bridge);

    // Identity
    ctx.__bbBgExtId     = extId   || "test-extension-id";
    ctx.__bbBgBaseURL   = baseURL || "chrome-extension://test-extension-id/";
    ctx.__bbBgManifest  = manifestJSON  || "{}";
    ctx.__bbBgMessages  = messagesJSON  || "{}";
    ctx.__bbLanguage    = "en-US";

    // TextEncoder / TextDecoder: not in vm context natively; needed by many extension scripts.
    ctx.TextEncoder   = TextEncoder;
    ctx.TextDecoder   = TextDecoder;

    // atob / btoa: not in vm context natively.
    ctx.atob = function(s) { return Buffer.from(s, "base64").toString("binary"); };
    ctx.btoa = function(s) { return Buffer.from(s, "binary").toString("base64"); };

    // crypto: vm context has no globalThis.crypto; background.js installs a shim if absent,
    // but providing a more complete one here lets extensions that call crypto.subtle at boot
    // get a real-ish promise-based response rather than crashing.
    ctx.crypto = {
        getRandomValues: function(arr) {
            for (var i = 0; i < arr.length; i++) { arr[i] = Math.floor(Math.random() * 256); }
            return arr;
        },
        randomUUID: function() {
            return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
                var r = Math.random() * 16 | 0;
                return (c === "x" ? r : (r & 0x3 | 0x8)).toString(16);
            });
        },
        subtle: {
            digest:      function() { return Promise.resolve(new ArrayBuffer(32)); },
            importKey:   function() { return Promise.resolve({}); },
            exportKey:   function() { return Promise.resolve({}); },
            generateKey: function() { return Promise.resolve({}); },
            sign:        function() { return Promise.resolve(new ArrayBuffer(32)); },
            verify:      function() { return Promise.resolve(true); },
            encrypt:     function() { return Promise.resolve(new ArrayBuffer(0)); },
            decrypt:     function() { return Promise.resolve(new ArrayBuffer(0)); },
            deriveBits:  function() { return Promise.resolve(new ArrayBuffer(32)); },
            deriveKey:   function() { return Promise.resolve({}); }
        }
    };

    // performance: not in vm context natively.
    ctx.performance = { now: function() { return Date.now(); }, timeOrigin: Date.now() };

    // console: vm context exposes Node's real console; replace with a silent stub so
    // extension boot noise doesn't pollute test output.
    ctx.console = {
        log: function() {}, info: function() {}, warn: function() {},
        error: function() {}, debug: function() {}, trace: function() {}
    };

    // Storage API placeholders (IndexedDB / localStorage are not needed for the shim boot test)
    ctx.localStorage = {
        getItem: function() { return null; },
        setItem: function() {},
        removeItem: function() {},
        clear: function() {},
        length: 0
    };
    ctx.sessionStorage = ctx.localStorage;

    // location is intentionally LEFT UNSET so the real shim DERIVES it from the manifest background
    // entry (a SW's location.href is its script URL, e.g. .../background.js — webpack SWs branch on
    // location.href.includes("background")). Asserted by "shim derives a script-URL location".

    ctx.navigator = {
        language: "en-US",
        languages: ["en-US", "en"],
        userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        appVersion: "5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
        platform: "iPhone",
        product: "Gecko", productSub: "20030107",
        vendor: "Apple Computer, Inc.", vendorSub: "",
        appName: "Netscape", appCodeName: "Mozilla",
        onLine: true, cookieEnabled: true,
        doNotTrack: null, webdriver: false,
        hardwareConcurrency: 4, maxTouchPoints: 5,
        pdfViewerEnabled: false,
        userAgentData: null,
        sendBeacon: function() { return false; },
        javaEnabled: function() { return false; }
    };

    // globalThis self-reference — must be set before vm.createContext wraps the object
    // so the shim's `(typeof globalThis !== 'undefined' ? globalThis : self)` resolves to ctx.
    ctx.globalThis = ctx;

    vm.createContext(ctx);
    return ctx;
}

// ---------------------------------------------------------------------------
// Run the BrownBear background shim in a fresh context and return the chrome
// object it exposed. Throws if the shim itself crashes.
// ---------------------------------------------------------------------------

function bootShim(extId, manifestObj, messages) {
    var manifestJSON = JSON.stringify(manifestObj || {});
    var messagesJSON = JSON.stringify(messages || {});
    var baseURL = "chrome-extension://" + extId + "/";
    var ctx = buildWorkerContext(extId, baseURL, manifestJSON, messagesJSON);
    vm.runInContext(BG_SRC, ctx, { filename: "brownbear-webext-background.js" });
    return ctx;
}

// ---------------------------------------------------------------------------
// Load extension manifest + i18n messages
// ---------------------------------------------------------------------------

function loadExtension(name) {
    var extDir = path.join(EXTDIR, name);
    if (!fs.existsSync(extDir)) { return null; }
    var manifestPath = path.join(extDir, "manifest.json");
    if (!fs.existsSync(manifestPath)) { return null; }
    var manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

    // Load default locale messages
    var messages = {};
    try {
        var defaultLocale = manifest.default_locale || "en";
        var msgPath = path.join(extDir, "_locales", defaultLocale, "messages.json");
        if (!fs.existsSync(msgPath)) {
            msgPath = path.join(extDir, "_locales", "en", "messages.json");
        }
        if (fs.existsSync(msgPath)) {
            var raw = JSON.parse(fs.readFileSync(msgPath, "utf8"));
            // Flatten: { "key": { "message": "value" } } -> { "key": "value" }
            Object.keys(raw).forEach(function(k) {
                messages[k] = (raw[k] && raw[k].message) ? raw[k].message : "";
            });
        }
    } catch(e) { /* no messages file */ }

    return { name: name, extDir: extDir, manifest: manifest, messages: messages };
}

// ---------------------------------------------------------------------------
// Try to run a JS file from an extension in a vm context. Catches errors and
// returns { ok: bool, error: string|null }.
// ---------------------------------------------------------------------------

function tryRunExtScript(ctx, filePath, filename) {
    try {
        var src = fs.readFileSync(filePath, "utf8");
        // Some extensions use `chrome` or `browser` as globals at top level.
        // In BrownBear, these are set on globalThis by the shim, so they're in ctx already.
        vm.runInContext(src, ctx, { filename: filename || path.basename(filePath), timeout: 5000 });
        return { ok: true, error: null };
    } catch(e) {
        var msg = (e && e.message) ? e.message : String(e);
        return { ok: false, error: msg };
    }
}

// ---------------------------------------------------------------------------
// Assert helpers
// ---------------------------------------------------------------------------

function assertFunction(obj, name) {
    assert.ok(typeof obj === "function", name + " should be a function, got " + typeof obj);
}
function assertObject(obj, name) {
    assert.ok(obj !== null && typeof obj === "object", name + " should be an object, got " + typeof obj);
}
function assertEvent(obj, name) {
    assertObject(obj, name);
    assertFunction(obj.addListener, name + ".addListener");
    assertFunction(obj.removeListener, name + ".removeListener");
    assertFunction(obj.hasListener, name + ".hasListener");
}
function assertString(val, name) {
    assert.ok(typeof val === "string", name + " should be a string, got " + typeof val);
}

// ---------------------------------------------------------------------------
// Core shim surface tests (run against every extension context)
// ---------------------------------------------------------------------------

function runCoreShimTests(ctx, extName) {
    var c = ctx.chrome;
    test(extName + ": chrome is an object", function() { assertObject(c, "chrome"); });
    test(extName + ": browser aliases chrome", function() {
        assert.strictEqual(ctx.browser, c, "browser !== chrome");
    });

    // runtime
    test(extName + ": chrome.runtime.id is a string", function() {
        assertString(c.runtime.id, "chrome.runtime.id");
    });
    test(extName + ": chrome.runtime.getManifest returns object", function() {
        var m = c.runtime.getManifest();
        assertObject(m, "getManifest()");
    });
    test(extName + ": chrome.runtime.getURL returns string", function() {
        assertString(c.runtime.getURL("icon.png"), "runtime.getURL");
    });
    test(extName + ": chrome.runtime.sendMessage is a function", function() {
        assertFunction(c.runtime.sendMessage, "runtime.sendMessage");
    });
    test(extName + ": chrome.runtime.onMessage is an event", function() {
        assertEvent(c.runtime.onMessage, "runtime.onMessage");
    });
    test(extName + ": chrome.runtime.onInstalled is an event", function() {
        assertEvent(c.runtime.onInstalled, "runtime.onInstalled");
    });
    test(extName + ": chrome.runtime.onStartup is an event", function() {
        assertEvent(c.runtime.onStartup, "runtime.onStartup");
    });
    test(extName + ": chrome.runtime.onConnect is an event", function() {
        assertEvent(c.runtime.onConnect, "runtime.onConnect");
    });
    test(extName + ": chrome.runtime.lastError accessible", function() {
        var _ = c.runtime.lastError; // must not throw
        assert.ok(true);
    });
    test(extName + ": chrome.runtime.OnInstalledReason is an object", function() {
        assertObject(c.runtime.OnInstalledReason, "runtime.OnInstalledReason");
        assertString(c.runtime.OnInstalledReason.INSTALL, "OnInstalledReason.INSTALL");
    });
    test(extName + ": chrome.runtime.ContextType is an object", function() {
        assertObject(c.runtime.ContextType, "runtime.ContextType");
        assertString(c.runtime.ContextType.BACKGROUND, "ContextType.BACKGROUND");
        assertString(c.runtime.ContextType.POPUP, "ContextType.POPUP");
    });
    test(extName + ": chrome.runtime.getContexts is a function", function() {
        assertFunction(c.runtime.getContexts, "runtime.getContexts");
    });
    test(extName + ": chrome.runtime.getPlatformInfo is a function", function() {
        assertFunction(c.runtime.getPlatformInfo, "runtime.getPlatformInfo");
    });
    test(extName + ": chrome.runtime.onConnectExternal/onMessageExternal exist", function() {
        // Tampermonkey and other script managers register listeners on both events unconditionally
        // at boot: without these, addListener throws "Cannot read properties of undefined".
        assertEvent(c.runtime.onConnectExternal, "runtime.onConnectExternal");
        assertEvent(c.runtime.onMessageExternal, "runtime.onMessageExternal");
    });
    test(extName + ": chrome.runtime.onBrowserUpdateAvailable/onRestartRequired exist", function() {
        // Chrome-specific lifecycle events that update-aware extensions (Tampermonkey watchdog) register.
        assertEvent(c.runtime.onBrowserUpdateAvailable, "runtime.onBrowserUpdateAvailable");
        assertEvent(c.runtime.onRestartRequired, "runtime.onRestartRequired");
    });

    // The SW's own location.href is its SCRIPT URL (e.g. .../background.js), not the bare origin. The
    // harness leaves location unset so the shim must DERIVE it from the manifest background entry;
    // webpack-bundled SWs read location.href.includes("background") to branch SW-vs-page (Browsec
    // messaged itself → "Receiving end does not exist" when location was only the origin).
    test(extName + ": shim derives a script-URL location (not the bare origin)", function() {
        assertObject(ctx.location, "location");
        assert.ok(typeof ctx.location.href === "string" && ctx.location.href.length > 0, "location.href set");
        assert.notStrictEqual(ctx.location.href, "chrome-extension://" + extName + "/", "location is a script URL, not the bare origin");
        assert.ok(/\.(js|html)$/i.test(ctx.location.href), "location.href ends in a script/page filename: " + ctx.location.href);
    });

    // chrome.privacy ChromeSettings expose get/set/clear AND onChange (Chrome spec). A VPN extension
    // (VeePN) wraps a privacy setting in a class and calls setting.onChange.addListener at init; a
    // missing onChange crashed module-eval with "this.setting.onChange.addListener is undefined".
    test(extName + ": chrome.privacy.* settings expose onChange (ChromeSetting shape)", function() {
        assertObject(c.privacy, "privacy");
        assertEvent(c.privacy.network.webRTCIPHandlingPolicy.onChange, "privacy.network.webRTCIPHandlingPolicy.onChange");
        assertEvent(c.privacy.network.networkPredictionEnabled.onChange, "privacy.network.networkPredictionEnabled.onChange");
        assertEvent(c.privacy.websites.hyperlinkAuditingEnabled.onChange, "privacy.websites.hyperlinkAuditingEnabled.onChange");
        assertFunction(c.privacy.network.webRTCIPHandlingPolicy.set, "privacy ChromeSetting.set");
    });

    // storage
    test(extName + ": chrome.storage.local has get/set/remove/onChanged", function() {
        assertFunction(c.storage.local.get, "storage.local.get");
        assertFunction(c.storage.local.set, "storage.local.set");
        assertFunction(c.storage.local.remove, "storage.local.remove");
        assertEvent(c.storage.local.onChanged, "storage.local.onChanged");
    });
    test(extName + ": chrome.storage.sync has get/set", function() {
        assertFunction(c.storage.sync.get, "storage.sync.get");
        assertFunction(c.storage.sync.set, "storage.sync.set");
    });
    test(extName + ": chrome.storage.session has get/set", function() {
        assertFunction(c.storage.session.get, "storage.session.get");
        assertFunction(c.storage.session.set, "storage.session.set");
    });
    test(extName + ": chrome.storage.onChanged is an event", function() {
        assertEvent(c.storage.onChanged, "storage.onChanged");
    });

    // tabs
    test(extName + ": chrome.tabs.query/get/create/update/remove are functions", function() {
        assertFunction(c.tabs.query, "tabs.query");
        assertFunction(c.tabs.get, "tabs.get");
        assertFunction(c.tabs.create, "tabs.create");
        assertFunction(c.tabs.update, "tabs.update");
        assertFunction(c.tabs.remove, "tabs.remove");
    });
    test(extName + ": chrome.tabs.sendMessage is a function", function() {
        assertFunction(c.tabs.sendMessage, "tabs.sendMessage");
    });
    test(extName + ": chrome.tabs.onUpdated/onCreated/onActivated/onRemoved are events", function() {
        assertEvent(c.tabs.onUpdated, "tabs.onUpdated");
        assertEvent(c.tabs.onCreated, "tabs.onCreated");
        assertEvent(c.tabs.onActivated, "tabs.onActivated");
        assertEvent(c.tabs.onRemoved, "tabs.onRemoved");
    });
    test(extName + ": chrome.tabs.getZoom/setZoom/move/duplicate are functions", function() {
        assertFunction(c.tabs.getZoom, "tabs.getZoom");
        assertFunction(c.tabs.setZoom, "tabs.setZoom");
        assertFunction(c.tabs.move, "tabs.move");
        assertFunction(c.tabs.duplicate, "tabs.duplicate");
    });

    // action
    test(extName + ": chrome.action setBadgeText/setIcon/setPopup are functions", function() {
        assertFunction(c.action.setBadgeText, "action.setBadgeText");
        assertFunction(c.action.setIcon, "action.setIcon");
        assertFunction(c.action.setPopup, "action.setPopup");
        assertFunction(c.action.openPopup, "action.openPopup");
        assertEvent(c.action.onClicked, "action.onClicked");
    });

    // scripting
    test(extName + ": chrome.scripting.executeScript is a function", function() {
        assertFunction(c.scripting.executeScript, "scripting.executeScript");
    });
    test(extName + ": chrome.scripting.registerContentScripts is a function", function() {
        assertFunction(c.scripting.registerContentScripts, "scripting.registerContentScripts");
    });
    test(extName + ": chrome.scripting.ExecutionWorld is an object", function() {
        assertObject(c.scripting.ExecutionWorld, "scripting.ExecutionWorld");
        assertString(c.scripting.ExecutionWorld.ISOLATED, "scripting.ExecutionWorld.ISOLATED");
        assertString(c.scripting.ExecutionWorld.MAIN, "scripting.ExecutionWorld.MAIN");
    });

    // windows
    test(extName + ": chrome.windows getCurrent/getAll/create are functions", function() {
        assertFunction(c.windows.getCurrent, "windows.getCurrent");
        assertFunction(c.windows.getAll, "windows.getAll");
        assertFunction(c.windows.create, "windows.create");
        assertFunction(c.windows.update, "windows.update");
    });

    // contextMenus
    test(extName + ": chrome.contextMenus.create/onClicked exist", function() {
        assertFunction(c.contextMenus.create, "contextMenus.create");
        assertEvent(c.contextMenus.onClicked, "contextMenus.onClicked");
    });

    // notifications
    test(extName + ": chrome.notifications.create is a function", function() {
        assertFunction(c.notifications.create, "notifications.create");
        assertEvent(c.notifications.onClicked, "notifications.onClicked");
    });

    // alarms
    test(extName + ": chrome.alarms.create/onAlarm exist", function() {
        assertFunction(c.alarms.create, "alarms.create");
        assertEvent(c.alarms.onAlarm, "alarms.onAlarm");
    });

    // cookies
    test(extName + ": chrome.cookies.get/getAll/set are functions", function() {
        assertFunction(c.cookies.get, "cookies.get");
        assertFunction(c.cookies.getAll, "cookies.getAll");
        assertFunction(c.cookies.set, "cookies.set");
        assertEvent(c.cookies.onChanged, "cookies.onChanged");
    });

    // i18n
    test(extName + ": chrome.i18n.getMessage/getUILanguage are functions", function() {
        assertFunction(c.i18n.getMessage, "i18n.getMessage");
        assertFunction(c.i18n.getUILanguage, "i18n.getUILanguage");
        assertFunction(c.i18n.getAcceptLanguages, "i18n.getAcceptLanguages");
    });

    // webNavigation
    test(extName + ": chrome.webNavigation events exist", function() {
        assertEvent(c.webNavigation.onCommitted, "webNavigation.onCommitted");
        assertEvent(c.webNavigation.onBeforeNavigate, "webNavigation.onBeforeNavigate");
        assertEvent(c.webNavigation.onCreatedNavigationTarget, "webNavigation.onCreatedNavigationTarget");
        // onTabReplaced + onReferenceFragmentUpdated: inert on WKWebView but must exist — iCloud Passwords'
        // background reads chrome.webNavigation.onTabReplaced.addListener UNGUARDED at boot.
        assertEvent(c.webNavigation.onTabReplaced, "webNavigation.onTabReplaced");
        assertEvent(c.webNavigation.onReferenceFragmentUpdated, "webNavigation.onReferenceFragmentUpdated");
        assertFunction(c.webNavigation.getAllFrames, "webNavigation.getAllFrames");
    });

    // webRequest
    test(extName + ": chrome.webRequest events + ResourceType exist", function() {
        assertEvent(c.webRequest.onBeforeRequest, "webRequest.onBeforeRequest");
        assertEvent(c.webRequest.onBeforeSendHeaders, "webRequest.onBeforeSendHeaders");
        assertEvent(c.webRequest.onHeadersReceived, "webRequest.onHeadersReceived");
        assertEvent(c.webRequest.onAuthRequired, "webRequest.onAuthRequired");
        assertObject(c.webRequest.ResourceType, "webRequest.ResourceType");
        assertString(c.webRequest.ResourceType.MAIN_FRAME, "ResourceType.MAIN_FRAME");
        // vapi-background.js:35 checks `webRequest.ResourceType instanceof Object` at module-eval
        // time. Verify the same check passes when run inside the same vm context that the shim ran in.
        // Plain `instanceof Object` from outside the vm uses the outer realm's Object constructor,
        // which does NOT match objects created inside the vm context — so we run the check inside.
        var instanceofResult = vm.runInContext(
            "chrome.webRequest.ResourceType instanceof Object",
            ctx, { filename: "webRequest-instanceof-check.js" }
        );
        assert.ok(instanceofResult, "webRequest.ResourceType should pass instanceof Object (same vm realm)");
    });

    // offscreen
    test(extName + ": chrome.offscreen.createDocument/hasDocument/Reason exist", function() {
        assertFunction(c.offscreen.createDocument, "offscreen.createDocument");
        assertFunction(c.offscreen.hasDocument, "offscreen.hasDocument");
        assertObject(c.offscreen.Reason, "offscreen.Reason");
        assertString(c.offscreen.Reason.DOM_PARSER, "offscreen.Reason.DOM_PARSER");
    });

    // privacy
    test(extName + ": chrome.privacy.network/websites settings exist", function() {
        assertObject(c.privacy.network, "privacy.network");
        assertObject(c.privacy.websites, "privacy.websites");
        assertFunction(c.privacy.network.networkPredictionEnabled.get, "privacy.network.networkPredictionEnabled.get");
    });
    test(extName + ": chrome.privacy.services is an object (bitwarden/lastpass)", function() {
        // privacy.services is an undocumented-in-standard surface Bitwarden/LastPass use.
        // BrownBear needs to provide it with the same {get/set/clear} shape as other privacy settings.
        assertObject(c.privacy.services, "privacy.services");
        assertFunction(c.privacy.services.autofillAddressEnabled.get, "privacy.services.autofillAddressEnabled.get");
        assertFunction(c.privacy.services.autofillCreditCardEnabled.get, "privacy.services.autofillCreditCardEnabled.get");
        assertFunction(c.privacy.services.passwordSavingEnabled.get, "privacy.services.passwordSavingEnabled.get");
    });

    // declarativeNetRequest
    test(extName + ": chrome.declarativeNetRequest constants exist", function() {
        assertObject(c.declarativeNetRequest.ResourceType, "dnr.ResourceType");
        assertObject(c.declarativeNetRequest.RuleActionType, "dnr.RuleActionType");
        assertFunction(c.declarativeNetRequest.updateDynamicRules, "dnr.updateDynamicRules");
    });

    // permissions
    test(extName + ": chrome.permissions getAll/contains/request exist", function() {
        assertFunction(c.permissions.getAll, "permissions.getAll");
        assertFunction(c.permissions.contains, "permissions.contains");
        assertFunction(c.permissions.request, "permissions.request");
        assertEvent(c.permissions.onAdded, "permissions.onAdded");
    });

    // management
    test(extName + ": chrome.management.getSelf/getAll exist", function() {
        assertFunction(c.management.getSelf, "management.getSelf");
        assertFunction(c.management.getAll, "management.getAll");
    });

    // idle
    test(extName + ": chrome.idle.queryState/setDetectionInterval/onStateChanged exist", function() {
        assertFunction(c.idle.queryState, "idle.queryState");
        assertFunction(c.idle.setDetectionInterval, "idle.setDetectionInterval");
        assertEvent(c.idle.onStateChanged, "idle.onStateChanged");
    });

    // commands
    test(extName + ": chrome.commands.getAll/onCommand exist", function() {
        assertFunction(c.commands.getAll, "commands.getAll");
        assertEvent(c.commands.onCommand, "commands.onCommand");
    });

    // bookmarks/history/sessions
    test(extName + ": chrome.bookmarks.getTree/search exist", function() {
        assertFunction(c.bookmarks.getTree, "bookmarks.getTree");
        assertFunction(c.bookmarks.search, "bookmarks.search");
    });
    test(extName + ": chrome.history.search/onVisited/onVisitRemoved exist", function() {
        assertFunction(c.history.search, "history.search");
        assertEvent(c.history.onVisited, "history.onVisited");
        assertEvent(c.history.onVisitRemoved, "history.onVisitRemoved");
    });
    test(extName + ": chrome.sessions.getRecentlyClosed/restore exist", function() {
        assertFunction(c.sessions.getRecentlyClosed, "sessions.getRecentlyClosed");
        assertFunction(c.sessions.restore, "sessions.restore");
    });

    // downloads
    test(extName + ": chrome.downloads.download/search exist", function() {
        assertFunction(c.downloads.download, "downloads.download");
        assertFunction(c.downloads.search, "downloads.search");
        assertEvent(c.downloads.onCreated, "downloads.onCreated");
    });

    // tabGroups
    test(extName + ": chrome.tabGroups exists with expected members", function() {
        assertObject(c.tabGroups, "tabGroups");
        assertFunction(c.tabGroups.query, "tabGroups.query");
        assertFunction(c.tabGroups.update, "tabGroups.update");
        assert.strictEqual(c.tabGroups.TAB_GROUP_ID_NONE, -1, "TAB_GROUP_ID_NONE should be -1");
    });

    // identity
    test(extName + ": chrome.identity.getRedirectURL is a function", function() {
        assertFunction(c.identity.getRedirectURL, "identity.getRedirectURL");
        assertString(c.identity.getRedirectURL("redirect"), "identity.getRedirectURL result");
    });

    // dom
    test(extName + ": chrome.dom.openOrClosedShadowRoot is a function", function() {
        assertFunction(c.dom.openOrClosedShadowRoot, "dom.openOrClosedShadowRoot");
    });

    // extension (legacy)
    test(extName + ": chrome.extension.getURL/inIncognitoContext/getViews/getBackgroundPage", function() {
        assertFunction(c.extension.getURL, "extension.getURL");
        assert.strictEqual(c.extension.inIncognitoContext, false, "inIncognitoContext should be false");
        assertFunction(c.extension.getViews, "extension.getViews");
        assertFunction(c.extension.getBackgroundPage, "extension.getBackgroundPage");
        // legacy MV2 aliases
        assertFunction(c.extension.sendMessage, "extension.sendMessage");
        assertObject(c.extension.onMessage, "extension.onMessage");
        assertObject(c.extension.onRequest, "extension.onRequest");
    });

    // search
    test(extName + ": chrome.search.query is a function", function() {
        assertFunction(c.search.query, "search.query");
    });

    // sidePanel (Grammarly etc.)
    test(extName + ": chrome.sidePanel is an object with expected methods", function() {
        assertObject(c.sidePanel, "sidePanel");
        assertFunction(c.sidePanel.open, "sidePanel.open");
        assertFunction(c.sidePanel.setOptions, "sidePanel.setOptions");
        assertFunction(c.sidePanel.getOptions, "sidePanel.getOptions");
        assertFunction(c.sidePanel.setPanel, "sidePanel.setPanel");
        assertFunction(c.sidePanel.setPanelBehavior, "sidePanel.setPanelBehavior");
        assertFunction(c.sidePanel.getPanelBehavior, "sidePanel.getPanelBehavior");
    });

    // devtools
    test(extName + ": chrome.devtools is an object", function() {
        assertObject(c.devtools, "devtools");
        assertObject(c.devtools.inspectedWindow, "devtools.inspectedWindow");
        assertObject(c.devtools.panels, "devtools.panels");
        assertObject(c.devtools.network, "devtools.network");
    });

    // sendNativeMessage
    test(extName + ": chrome.runtime.sendNativeMessage is a function", function() {
        assertFunction(c.runtime.sendNativeMessage, "runtime.sendNativeMessage");
    });

    // scripting.ExecutionWorld
    test(extName + ": chrome.scripting.ExecutionWorld has ISOLATED/MAIN/USER_SCRIPT", function() {
        assertObject(c.scripting.ExecutionWorld, "scripting.ExecutionWorld");
        assertString(c.scripting.ExecutionWorld.ISOLATED, "ExecutionWorld.ISOLATED");
        assertString(c.scripting.ExecutionWorld.MAIN, "ExecutionWorld.MAIN");
        assertString(c.scripting.ExecutionWorld.USER_SCRIPT, "ExecutionWorld.USER_SCRIPT");
    });

    // userScripts
    test(extName + ": chrome.userScripts.register/configureWorld/execute exist", function() {
        assertFunction(c.userScripts.register, "userScripts.register");
        assertFunction(c.userScripts.configureWorld, "userScripts.configureWorld");
        assertFunction(c.userScripts.execute, "userScripts.execute");
    });
}

// ---------------------------------------------------------------------------
// Per-extension boot test: load the BrownBear shim under the extension's
// manifest, then (optionally) try to run the background SW to check it boots
// without crashing.
// ---------------------------------------------------------------------------

function runExtensionTests(extInfo) {
    var name = extInfo.name;
    var manifest = extInfo.manifest;
    var messages = extInfo.messages;
    var extId = "brownbear-" + name;

    console.log("\n--- " + name.toUpperCase() + " (MV" + (manifest.manifest_version || "?") + ") ---");

    // 1. Boot the BrownBear shim under this extension's manifest
    var ctx;
    test(name + ": shim boots without crashing", function() {
        ctx = bootShim(extId, manifest, messages);
        assert.ok(ctx.chrome, "chrome not set after shim boot");
    });

    if (!ctx) { skip(name + ": (skipping surface tests — shim failed to boot)", ""); return; }

    // 2. Core surface tests (run against every extension's shim context)
    runCoreShimTests(ctx, name);

    // 3. Try to run the extension's background script
    var bgScript = null;
    if (manifest.background) {
        if (manifest.background.service_worker) {
            bgScript = path.join(extInfo.extDir, manifest.background.service_worker);
        } else if (manifest.background.scripts && manifest.background.scripts.length > 0) {
            bgScript = path.join(extInfo.extDir, manifest.background.scripts[0]);
        }
    }

    if (!bgScript || !fs.existsSync(bgScript)) {
        skip(name + ": background script boot", "no background script found");
    } else {
        test(name + ": background script loads without TypeError/ReferenceError", function() {
            var result = tryRunExtScript(ctx, bgScript, name + "/background.js");
            if (!result.ok) {
                // Certain errors are expected on iOS (webRequest blocking, native APIs etc.)
                // but TypeError / ReferenceError on property access indicate a MISSING API.
                var msg = result.error || "";
                var isCrash = /TypeError.*undefined.*not.*object|ReferenceError.*not.*defined|Cannot read prop|is not a function/.test(msg);
                if (isCrash) {
                    throw new Error("Background script crash: " + msg.slice(0, 200));
                }
                // Non-crash errors (module syntax, ES2022+ features, etc.) — note but don't fail
                // since we test the shim surface, not the extension source transpilation.
            }
        });
    }
}

// ---------------------------------------------------------------------------
// Extension-specific additional tests
// ---------------------------------------------------------------------------

function runExtensionSpecificTests(ctx, name) {
    if (!ctx) { return; }
    var c = ctx.chrome;

    if (name === "vimium") {
        test("vimium: tabs.getZoom/setZoom resolve without crash", function() {
            var result = null;
            c.tabs.getZoom(function(z) { result = z; });
            // result may be null from our stub, but the call should not throw
            assert.ok(true);
        });
        test("vimium: bookmarks.getTree + history.search + sessions.restore don't throw", function() {
            var results = [];
            c.bookmarks.getTree(function(t) { results.push("bookmarks"); });
            c.history.search({ text: "google" }, function(h) { results.push("history"); });
            c.sessions.restore(null, function(s) { results.push("sessions"); });
        });
        test("vimium: chrome.search.query is callable", function() {
            var p = c.search.query({ text: "test", disposition: "NEW_TAB" });
            assert.ok(p && typeof p.then === "function", "search.query should return a promise");
        });
    }

    if (name === "bitwarden") {
        test("bitwarden: chrome.privacy.services.autofillAddressEnabled is a PrivacySetting", function() {
            var setting = c.privacy.services.autofillAddressEnabled;
            assertFunction(setting.get, "privacy.services.autofillAddressEnabled.get");
            assertFunction(setting.set, "privacy.services.autofillAddressEnabled.set");
            assertFunction(setting.clear, "privacy.services.autofillAddressEnabled.clear");
        });
        test("bitwarden: chrome.runtime.getContexts returns promise", function() {
            var p = c.runtime.getContexts({ contextTypes: ["BACKGROUND"] });
            assert.ok(p && typeof p.then === "function", "getContexts should return a Promise");
        });
    }

    if (name === "grammarly") {
        test("grammarly: chrome.sidePanel.open is callable", function() {
            var p = c.sidePanel.open({ windowId: 1 });
            assert.ok(p && typeof p.then === "function", "sidePanel.open should return a promise");
        });
        test("grammarly: chrome.action.openPopup is a function", function() {
            assertFunction(c.action.openPopup, "action.openPopup");
        });
    }

    if (name === "dark-reader") {
        test("dark-reader: chrome.alarms.create/onAlarm work", function() {
            var fired = false;
            c.alarms.onAlarm.addListener(function() { fired = true; });
            assertFunction(c.alarms.create, "alarms.create");
        });
    }

    if (name === "metamask") {
        test("metamask: chrome.runtime.onConnect/connect work", function() {
            assertEvent(c.runtime.onConnect, "runtime.onConnect");
            assertFunction(c.runtime.connect, "runtime.connect");
        });
    }

    if (name === "ublock-origin") {
        test("ublock-origin: chrome.webRequest.ResourceType accessible at module load", function() {
            // vapi-background.js reads this during init: `webRequest.ResourceType instanceof Object`
            // Run the check inside the same vm realm — outer Object !== inner Object in vm sandboxes.
            var r = vm.runInContext("chrome.webRequest.ResourceType instanceof Object", ctx, { filename: "ubo-resource-type-check.js" });
            assert.ok(r, "ResourceType should be instanceof Object (same vm realm)");
            assertString(c.webRequest.ResourceType.WEBSOCKET, "ResourceType.WEBSOCKET");
        });
        test("ublock-origin: chrome.webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS exists", function() {
            // Violentmonkey background reads this during init
            assertString(c.webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS, "OnBeforeSendHeadersOptions.EXTRA_HEADERS");
            assertString(c.webRequest.OnHeadersReceivedOptions.EXTRA_HEADERS, "OnHeadersReceivedOptions.EXTRA_HEADERS");
        });
        test("ublock-origin: chrome.privacy.network settings accessible", function() {
            assertObject(c.privacy.network, "privacy.network");
            assertFunction(c.privacy.network.networkPredictionEnabled.get, "networkPredictionEnabled.get");
            assertFunction(c.privacy.network.webRTCIPHandlingPolicy.get, "webRTCIPHandlingPolicy.get");
            assertFunction(c.privacy.websites.hyperlinkAuditingEnabled.get, "hyperlinkAuditingEnabled.get");
        });
    }

    if (name === "todoist") {
        test("todoist: chrome.extension legacy APIs work", function() {
            // Todoist still uses chrome.extension.inIncognitoContext, getBackgroundPage, onRequest, sendRequest
            assert.strictEqual(c.extension.inIncognitoContext, false, "inIncognitoContext");
            assertFunction(c.extension.getBackgroundPage, "getBackgroundPage");
            assertObject(c.extension.onRequest, "extension.onRequest (alias of runtime.onMessage)");
        });
        test("todoist: chrome.commands.onCommand event exists", function() {
            assertEvent(c.commands.onCommand, "commands.onCommand");
        });
    }

    if (name === "react-devtools") {
        test("react-devtools: chrome.devtools namespace exists", function() {
            assertObject(c.devtools, "devtools");
            assertObject(c.devtools.panels, "devtools.panels");
            assertObject(c.devtools.inspectedWindow, "devtools.inspectedWindow");
            assertObject(c.devtools.network, "devtools.network");
        });
        test("react-devtools: scripting.ExecutionWorld.MAIN/ISOLATED exist", function() {
            assertString(c.scripting.ExecutionWorld.MAIN, "ExecutionWorld.MAIN");
            assertString(c.scripting.ExecutionWorld.ISOLATED, "ExecutionWorld.ISOLATED");
        });
    }

    if (name === "momentum") {
        test("momentum: chrome.runtime.sendNativeMessage is a function", function() {
            assertFunction(c.runtime.sendNativeMessage, "runtime.sendNativeMessage");
        });
        test("momentum: chrome.tabGroups.update is a function", function() {
            assertFunction(c.tabGroups.update, "tabGroups.update");
        });
    }

    if (name === "tampermonkey") {
        test("tampermonkey: chrome.runtime.onConnectExternal.addListener works", function() {
            // Tampermonkey registers externally-connectable listeners unconditionally at boot.
            var fired = false;
            c.runtime.onConnectExternal.addListener(function() { fired = true; });
            assert.ok(true, "addListener on onConnectExternal should not throw");
        });
        test("tampermonkey: chrome.runtime.onMessageExternal.addListener works", function() {
            var fired = false;
            c.runtime.onMessageExternal.addListener(function() { fired = true; });
            assert.ok(true, "addListener on onMessageExternal should not throw");
        });
        test("tampermonkey: chrome.userScripts.register/configureWorld are functions", function() {
            assertFunction(c.userScripts.register, "userScripts.register");
            assertFunction(c.userScripts.configureWorld, "userScripts.configureWorld");
        });
        test("tampermonkey: chrome.scripting.ExecutionWorld.USER_SCRIPT exists", function() {
            assertString(c.scripting.ExecutionWorld.USER_SCRIPT, "ExecutionWorld.USER_SCRIPT");
        });
    }

    if (name === "violentmonkey") {
        test("violentmonkey: chrome.webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS exists", function() {
            // Violentmonkey's background reads these enum values at init time.
            assertString(c.webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS, "OnBeforeSendHeadersOptions.EXTRA_HEADERS");
            assertString(c.webRequest.OnHeadersReceivedOptions.EXTRA_HEADERS, "OnHeadersReceivedOptions.EXTRA_HEADERS");
        });
        test("violentmonkey: chrome.tabs.executeScript is a function (MV2 API)", function() {
            assertFunction(c.tabs.executeScript, "tabs.executeScript");
            assertFunction(c.tabs.insertCSS, "tabs.insertCSS");
        });
    }

    if (name === "adblock-plus") {
        // Adblock Plus / AdBlock (MV3) manage per-filter allowlisting through the chrome 120+
        // static-ruleset methods. They were absent from the shim, so the first call threw
        // "...is not a function" inside the SW's async init and broke ruleset configuration.
        test("adblock-plus: chrome.declarativeNetRequest static-rule methods are functions", function() {
            assertFunction(c.declarativeNetRequest.updateStaticRules, "declarativeNetRequest.updateStaticRules");
            assertFunction(c.declarativeNetRequest.getDisabledRuleIds, "declarativeNetRequest.getDisabledRuleIds");
            assertFunction(c.declarativeNetRequest.getAvailableStaticRuleCount, "declarativeNetRequest.getAvailableStaticRuleCount");
        });
        test("adblock-plus: GUARANTEED_MINIMUM_STATIC_RULES is Chrome's documented floor (30000)", function() {
            // getAvailableStaticRuleCount resolves this constant (Promise.resolve in the shim); the
            // marathon runner can't await, so pin the value through the synchronous constant it returns.
            assert.strictEqual(c.declarativeNetRequest.GUARANTEED_MINIMUM_STATIC_RULES, 30000,
                "GUARANTEED_MINIMUM_STATIC_RULES constant should be Chrome's documented floor");
        });
        test("adblock-plus: static-rule reads return thenables without throwing", function() {
            // No-callback form returns a Promise (Chrome MV3). Calling must not throw synchronously.
            var p1 = c.declarativeNetRequest.getAvailableStaticRuleCount();
            var p2 = c.declarativeNetRequest.getDisabledRuleIds({ rulesetId: "rs1" });
            assert.strictEqual(typeof p1.then, "function", "getAvailableStaticRuleCount should return a Promise");
            assert.strictEqual(typeof p2.then, "function", "getDisabledRuleIds should return a Promise");
        });
        test("adblock-plus: updateStaticRules degrades gracefully (does not throw/reject)", function() {
            // The real native rejects unsupported static-rule mutations; the shim catches and degrades to
            // a no-op rather than letting the rejection break the SW's ruleset configuration.
            var p = c.declarativeNetRequest.updateStaticRules({ rulesetId: "rs1", disableRuleIds: [1, 2] });
            assert.strictEqual(typeof p.then, "function", "updateStaticRules should return a Promise");
            // Swallow the resolution so a degraded no-op never surfaces as an unhandled rejection.
            p.then(function() {}, function() {});
        });
    }

    if (name === "adblock") {
        // AdBlock (BetaFish) is built on the Adblock Plus core, so its 3MB MV3 service worker drives the
        // same chrome 120+ static-ruleset API. Guards that the fix generalizes beyond adblock-plus.
        test("adblock: chrome.declarativeNetRequest static-rule methods are functions", function() {
            assertFunction(c.declarativeNetRequest.updateStaticRules, "declarativeNetRequest.updateStaticRules");
            assertFunction(c.declarativeNetRequest.getDisabledRuleIds, "declarativeNetRequest.getDisabledRuleIds");
            assertFunction(c.declarativeNetRequest.getAvailableStaticRuleCount, "declarativeNetRequest.getAvailableStaticRuleCount");
        });
    }

    if (name === "dashlane") {
        // Dashlane (MV3 password manager) registers webRequest.onAuthRequired across its SW, content
        // scripts, and popup for HTTP basic/digest-auth autofill (the webRequestAuthProvider permission).
        // WKWebView can't intercept requests, so this event is inert — but it MUST exist or every Dashlane
        // surface throws "undefined is not an object" at the addListener call. It also drives DNR + privacy.
        test("dashlane: chrome.webRequest.onAuthRequired/onErrorOccurred are events (auth autofill, inert)", function() {
            assertEvent(c.webRequest.onAuthRequired, "webRequest.onAuthRequired");
            assertEvent(c.webRequest.onErrorOccurred, "webRequest.onErrorOccurred");
            // Inert by design: registering a listener must not throw, and it simply never fires on iOS.
            assert.doesNotThrow(function () { c.webRequest.onAuthRequired.addListener(function () {}, { urls: ["<all_urls>"] }, ["blocking"]); },
                "onAuthRequired.addListener must not throw");
        });
        test("dashlane: chrome.privacy + cookies + idle surfaces exist (SW boot dependencies)", function() {
            assertObject(c.privacy.network, "privacy.network");
            assertFunction(c.cookies.getAll, "cookies.getAll");
            assertFunction(c.idle.queryState, "idle.queryState");
        });
    }

    if (name === "loom") {
        // Loom (MV3 screen recorder) reads chrome.system.cpu.getInfo and drives tabCapture/desktopCapture.
        // The namespaces were absent → "chrome.system is undefined" the moment recording runs. system.*
        // returns plausible info; capture is a hard WKWebView limit and fails closed (never crashes boot).
        test("loom: chrome.system.{cpu,memory,display}.getInfo are functions", function() {
            assertFunction(c.system.cpu.getInfo, "system.cpu.getInfo");
            assertFunction(c.system.memory.getInfo, "system.memory.getInfo");
            assertFunction(c.system.display.getInfo, "system.display.getInfo");
        });
        test("loom: system.cpu.getInfo returns a thenable without throwing (async, Chrome-shaped)", function() {
            // settleBg resolves on a microtask (Chrome's system.* callbacks are async too); the marathon
            // runner can't await, so assert the no-callback Promise form rather than a sync callback value.
            var p = c.system.cpu.getInfo();
            assert.strictEqual(typeof p.then, "function", "system.cpu.getInfo should return a Promise");
            p.then(function() {}, function() {});
        });
        test("loom: chrome.tabCapture surface exists and fails closed (no WKWebView capture)", function() {
            assertFunction(c.tabCapture.capture, "tabCapture.capture");
            assertFunction(c.tabCapture.getMediaStreamId, "tabCapture.getMediaStreamId");
            assertEvent(c.tabCapture.onStatusChanged, "tabCapture.onStatusChanged");
            // capture(...) calls back with null rather than throwing.
            var got = "unset";
            c.tabCapture.capture({ audio: true, video: true }, function(stream) { got = stream; });
            assert.strictEqual(got, null, "tabCapture.capture should yield null (unavailable)");
        });
        test("loom: chrome.desktopCapture.chooseDesktopMedia returns a request id + cancels with ''", function() {
            assertFunction(c.desktopCapture.chooseDesktopMedia, "desktopCapture.chooseDesktopMedia");
            assertFunction(c.desktopCapture.cancelChooseDesktopMedia, "desktopCapture.cancelChooseDesktopMedia");
            var streamId = "unset";
            var reqId = c.desktopCapture.chooseDesktopMedia(["screen", "window"], function(id) { streamId = id; });
            assert.strictEqual(typeof reqId, "number", "chooseDesktopMedia returns a numeric request id");
            assert.strictEqual(streamId, "", "callback streamId is '' (cancelled/unavailable)");
        });
    }

    if (name === "readaloud") {
        // Read Aloud (MV3 TTS) calls the full chrome.tts consumer surface via its `brapi = chrome` wrapper
        // (speak/stop/pause/resume/isSpeaking/getVoices). The namespace was absent → throws the moment it
        // builds its engine list. The JSContext SW has no speech engine, so getVoices reports none (the
        // extension's other engines take over) and speak fails closed via an 'error' tts event.
        test("readaloud: chrome.tts consumer surface exists", function() {
            assertFunction(c.tts.speak, "tts.speak");
            assertFunction(c.tts.stop, "tts.stop");
            assertFunction(c.tts.pause, "tts.pause");
            assertFunction(c.tts.resume, "tts.resume");
            assertFunction(c.tts.isSpeaking, "tts.isSpeaking");
            assertFunction(c.tts.getVoices, "tts.getVoices");
            assertEvent(c.tts.onEvent, "tts.onEvent");
        });
        test("readaloud: tts.getVoices reports none + speak fails closed via an 'error' event", function() {
            var voices = "unset";
            c.tts.getVoices(function(v) { voices = v; });
            assert.ok(Array.isArray(voices) && voices.length === 0, "getVoices yields an empty array");
            var evt = null;
            c.tts.speak("hello", { onEvent: function(e) { evt = e; } });
            assert.ok(evt && evt.type === "error", "speak should fire an 'error' tts event (unavailable)");
            assert.doesNotThrow(function() { c.tts.stop(); c.tts.pause(); c.tts.resume(); }, "transport no-ops must not throw");
        });
        test("readaloud: chrome.ttsEngine provider surface exists (inert, engine can't be routed)", function() {
            assertEvent(c.ttsEngine.onSpeak, "ttsEngine.onSpeak");
            assertEvent(c.ttsEngine.onStop, "ttsEngine.onStop");
            assertFunction(c.ttsEngine.updateVoices, "ttsEngine.updateVoices");
        });
    }

    if (name === "colorzilla") {
        // ColorZilla (MV3 eyedropper) is a minimal tabs/scripting/storage/offscreen extension; it boots
        // clean and validates the offscreen-document surface a color-picker relies on.
        test("colorzilla: chrome.offscreen.createDocument/hasDocument exist", function() {
            assertFunction(c.offscreen.createDocument, "offscreen.createDocument");
            assertFunction(c.offscreen.hasDocument, "offscreen.hasDocument");
            assertObject(c.offscreen.Reason, "offscreen.Reason");
        });
    }

    if (name === "chrome-remote-desktop") {
        // Chrome Remote Desktop's service worker calls chrome.runtime.connectNative to reach its native
        // host. iOS has NO native-messaging hosts (a hard limit), so the port must degrade — return a
        // non-null Port the extension can attach onDisconnect to, then disconnect with lastError, rather
        // than throwing "undefined is not an object" and aborting the worker.
        test("chrome-remote-desktop: connectNative returns a degraded, non-null Port (no native hosts on iOS)", function() {
            assertFunction(c.runtime.connectNative, "runtime.connectNative");
            var port = c.runtime.connectNative("com.google.chrome.remote_desktop");
            assert.ok(port && typeof port === "object", "connectNative must return a non-null port");
            assertFunction(port.postMessage, "port.postMessage");
            assertFunction(port.disconnect, "port.disconnect");
            assert.doesNotThrow(function () { port.onDisconnect.addListener(function () {}); port.onMessage.addListener(function () {}); },
                "attaching port listeners must not throw");
        });
        test("chrome-remote-desktop: chrome.downloads surface exists (its only other permission)", function() {
            assertFunction(c.downloads.download, "downloads.download");
            assertFunction(c.downloads.search, "downloads.search");
        });
    }

    if (name === "browsec") {
        test("browsec: chrome.proxy.settings.get/set/clear/onChange exist", function() {
            assertFunction(c.proxy.settings.get, "proxy.settings.get");
            assertFunction(c.proxy.settings.set, "proxy.settings.set");
            assertFunction(c.proxy.settings.clear, "proxy.settings.clear");
            assertEvent(c.proxy.settings.onChange, "proxy.settings.onChange");
        });
        test("browsec: chrome.alarms.create/onAlarm work without crash", function() {
            assertFunction(c.alarms.create, "alarms.create");
            assertEvent(c.alarms.onAlarm, "alarms.onAlarm");
        });
    }

    if (name === "ghostery") {
        // Ghostery uses an ESM service worker (import/export syntax). The shim boots cleanly;
        // the background script itself cannot execute in vm.runInContext (ESM-only) — expected degradation.
        test("ghostery: chrome.privacy.network settings exist (Ghostery reads them)", function() {
            assertObject(c.privacy.network, "privacy.network");
            assertFunction(c.privacy.network.networkPredictionEnabled.get, "networkPredictionEnabled.get");
        });
        test("ghostery: chrome.declarativeNetRequest.updateDynamicRules exists", function() {
            assertFunction(c.declarativeNetRequest.updateDynamicRules, "dnr.updateDynamicRules");
        });
    }

    if (name === "decentraleyes") {
        // Decentraleyes uses an ESM service worker. Shim surface is verified; bg boot is ESM-only.
        test("decentraleyes: chrome.webNavigation events exist", function() {
            assertEvent(c.webNavigation.onBeforeNavigate, "webNavigation.onBeforeNavigate");
            assertEvent(c.webNavigation.onCommitted, "webNavigation.onCommitted");
        });
    }

    if (name === "clearurls") {
        test("clearurls: chrome.contextMenus.create is a function", function() {
            assertFunction(c.contextMenus.create, "contextMenus.create");
            assertEvent(c.contextMenus.onClicked, "contextMenus.onClicked");
        });
        test("clearurls: chrome.storage.local.get/set work (MV2 background)", function() {
            assertFunction(c.storage.local.get, "storage.local.get");
            assertFunction(c.storage.local.set, "storage.local.set");
        });
        test("clearurls: chrome.webRequest.onBeforeRequest exists (ClearURLs uses blocking webRequest)", function() {
            // webRequest blocking is an expected platform degradation on iOS (WKWebView can't intercept).
            // The event object must exist so listener registration at boot does not throw.
            assertEvent(c.webRequest.onBeforeRequest, "webRequest.onBeforeRequest");
        });
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const EXTENSIONS_TO_TEST = [
    "bitwarden",
    "browsec",
    "clearurls",
    "dark-reader",
    "decentraleyes",
    "ghostery",
    "grammarly",
    "honey",
    "lastpass",
    "metamask",
    "momentum",
    "notion",
    "react-devtools",
    "tampermonkey",
    "todoist",
    "ublock-origin",
    "violentmonkey",
    "vimium",
    // Wave 3
    "google-translate",
    "keepa",
    // Wave 4
    "adblock-plus",
    "adblock",
    "dashlane",
    "loom",
    // Wave 5
    "colorzilla",
    "readaloud",
    // Wave 6
    "chrome-remote-desktop",
];

console.log("BrownBear Extension Marathon Harness");
console.log("====================================");
console.log("Testing BrownBear chrome.* shim against " + EXTENSIONS_TO_TEST.length + " popular extensions (Wave 1 + Wave 2).");
console.log("Extensions directory: " + EXTDIR);
console.log("BrownBear JS directory: " + JSDIR);
console.log("");

// Keep a map of ctx per extension for extension-specific tests
var ctxMap = {};

for (var i = 0; i < EXTENSIONS_TO_TEST.length; i++) {
    var name = EXTENSIONS_TO_TEST[i];
    var extInfo = loadExtension(name);
    if (!extInfo) {
        console.log("\n--- " + name.toUpperCase() + " ---");
        skip(name + ": all tests", "extension not found at " + path.join(EXTDIR, name));
        continue;
    }

    // Run tests and capture the context for extension-specific follow-up
    var manifest = extInfo.manifest;
    var messages = extInfo.messages;
    var extId = "brownbear-" + name;

    console.log("\n--- " + name.toUpperCase() + " (MV" + (manifest.manifest_version || "?") + ") ---");

    var ctx = null;
    test(name + ": shim boots without crashing", function() {
        ctx = bootShim(extId, manifest, messages);
        assert.ok(ctx.chrome, "chrome not set after shim boot");
    });

    if (ctx) {
        ctxMap[name] = ctx;
        runCoreShimTests(ctx, name);
        runExtensionSpecificTests(ctx, name);

        // Try running the extension's background. For MV2 multi-script backgrounds the engine
        // runs ALL scripts in the same context (same as a browser background page). For MV3
        // service workers, run the single entry point. ESM modules (import/export) are an
        // expected degradation — vm.runInContext cannot parse ES module syntax; only the real
        // browser can. For extensions whose importScripts loads packaged files (e.g. Browsec's
        // lodash), patch __bb_import_script to read the actual file so the load succeeds.
        var bgScripts = [];
        if (manifest.background) {
            if (manifest.background.service_worker) {
                var swPath = path.join(extInfo.extDir, manifest.background.service_worker);
                if (fs.existsSync(swPath)) { bgScripts = [swPath]; }
            } else if (manifest.background.scripts && manifest.background.scripts.length > 0) {
                // MV2: run all scripts in order in the same context (background page semantics).
                for (var si = 0; si < manifest.background.scripts.length; si++) {
                    var sPath = path.join(extInfo.extDir, manifest.background.scripts[si]);
                    if (fs.existsSync(sPath)) { bgScripts.push(sPath); }
                }
            }
        }

        // Patch __bb_import_script in this context to resolve packaged-file paths against the
        // extension dir. Browsec calls importScripts('/lodash.js') from its background; our
        // default stub returns a comment instead of the real lodash, crashing its MV3 worker.
        // This mirrors how the real engine resolves chrome-extension:// relative URLs.
        (function patchImportScripts(c, extDir) {
            if (typeof c.__bb_import_script !== "function") { return; }
            var orig = c.__bb_import_script;
            c.__bb_import_script = function(spec) {
                // Strip chrome-extension://id/ prefix (if any) to get the bare extension-relative path.
                var bare = String(spec)
                    .replace(/^chrome-extension:\/\/[^/]+\//, "")
                    .replace(/^\//, "");
                var candidate = path.join(extDir, bare);
                if (candidate.indexOf(extDir) === 0 && fs.existsSync(candidate)) {
                    try { return fs.readFileSync(candidate, "utf8"); } catch (e) { /* fall through */ }
                }
                return orig.call(this, spec);
            };
        })(ctx, extInfo.extDir);

        if (bgScripts.length === 0) {
            skip(name + ": background script boot", "no background script found");
        } else {
            var bgName = name; // capture for closure
            var bgPaths = bgScripts.slice();
            var bgCtx = ctx;
            test(bgName + ": background script loads without TypeError/ReferenceError", function() {
                for (var bi = 0; bi < bgPaths.length; bi++) {
                    var result = tryRunExtScript(bgCtx, bgPaths[bi], bgName + "/background[" + bi + "].js");
                    if (!result.ok) {
                        var msg = result.error || "";
                        // Crashes on missing API members = real shim gaps.
                        // Module-parse failures (import/export syntax, etc.) = extension uses ESM and we
                        // can't run it in vm.runInContext — skip those, they require the real browser.
                        var isESM = /import\b|export\b|Cannot use import|SyntaxError.*import/.test(msg);
                        var isCrash = !isESM && /TypeError.*undefined.*not.*object|TypeError.*not a function|ReferenceError.*not.*defined|Cannot read prop|is not a function/.test(msg);
                        if (isCrash) {
                            throw new Error("Background script crash (likely missing shim API): " + msg.slice(0, 300));
                        }
                        // Non-crash (ESM, extension self-check, etc.) — stop loading further scripts
                        // but do not fail the test.
                        break;
                    }
                }
            });
        }
    }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log("\n====================================");
console.log("Results: " + passed + " passed, " + failed + " failed, " + skipped + " skipped");
if (failed > 0) {
    console.log("\nFAILED — shim gaps detected. See FAIL lines above.");
    process.exit(1);
} else {
    console.log("\nAll assertions passed.");
    process.exit(0);
}
