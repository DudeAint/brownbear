//
//  runtime-getbrowserinfo-gate.test.js
//  BrownBear
//
//  chrome.runtime.getBrowserInfo is a FIREFOX-ONLY runtime API. Real Chrome leaves it undefined, and it
//  is THE canonical feature-detect extensions use to tell Firefox from Chrome. FireShot's MV3 service
//  worker, for example, runs `ge(){return typeof browser<"u"&&typeof browser.runtime?.getBrowserInfo
//  =="function"}` and, when ge() is true, executes a bare-`window` branch (`window.chrome=window.browser`)
//  — which throws "window is not defined" in a real MV3 worker (no window). On real Chrome ge() is FALSE
//  (getBrowserInfo absent), so that branch is dead code and FireShot boots clean. BrownBear used to expose
//  getBrowserInfo UNCONDITIONALLY on all three shims, so a Chrome-build extension wrongly looked like
//  Firefox and tripped that branch.
//
//  The fix gates getBrowserInfo on the extension's serving scheme (the single native source of truth for
//  which browser we emulate): Chrome builds get chrome-extension:// and must see getBrowserInfo === undefined
//  (exactly like real Chrome); Firefox builds get moz-extension:// and still see it present (exactly like
//  real Firefox), so a Firefox port that awaits getBrowserInfo() at init (Tree Style Tab, Simple Tab Groups,
//  Sidebery) keeps working. This boots all three REAL shims — background (MV3 service worker), runtime
//  (content script) and page (popup/options/sidebar) — under both schemes and pins that contract, including
//  a malformed/garbage baseURL (which must NOT be mistaken for Firefox → getBrowserInfo stays absent).
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/runtime-getbrowserinfo-gate.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const JSDIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const BG_SRC = fs.readFileSync(path.join(JSDIR, "brownbear-webext-background.js"), "utf8");
const RUNTIME_SRC = fs.readFileSync(path.join(JSDIR, "brownbear-webext-runtime.js"), "utf8");
const PAGE_SRC = fs.readFileSync(path.join(JSDIR, "brownbear-webext-page.js"), "utf8");

const ID = "getbrowserinfogatetestidaaaaaaaa";

// ---- BACKGROUND (MV3 service worker) harness --------------------------------------------------------
// Mirrors firefox-scheme.test.js: feed JSC-native globals only so the shim's own polyfills run, then read
// globalThis.browser.runtime.getBrowserInfo. baseURL carries the scheme that gates the API.
function bootBg(baseURL) {
    const ctx = {}; ctx.globalThis = ctx; ctx.self = ctx;
    for (const k of ["Object", "Array", "JSON", "Math", "Date", "RegExp", "Error", "TypeError",
        "Symbol", "Map", "Set", "WeakMap", "WeakSet", "Proxy", "Reflect", "Function", "String",
        "Number", "Boolean", "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent",
        "decodeURIComponent", "Promise", "ArrayBuffer", "Uint8Array"]) {
        if (global[k] !== undefined) { ctx[k] = global[k]; }
    }
    const noop = function () { var a = arguments, cb = a[a.length - 1]; if (typeof cb === "function") { cb("null"); } };
    for (const f of ["__bb_set_timeout", "__bb_clear_timer", "__bb_log", "__bb_storage_get",
        "__bb_storage_set", "__bb_send_message", "__bb_message_response", "__bb_alarm_get_all",
        "__bb_idle", "__bb_dnr", "__bb_userscripts", "__bb_import_script", "__bb_fetch",
        "__bb_crypto_uuid", "__bb_subtle"]) { ctx[f] = noop; }
    ctx.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1" });
    ctx.__bbBgExtId = ID;
    ctx.__bbBgBaseURL = baseURL;
    ctx.__bbBgMessages = "{}";
    ctx.__bbUserAgent = "Mozilla/5.0";
    ctx.__bbLanguage = "en-US";
    ctx.__bbModuleSource = function () { return null; };
    vm.createContext(ctx);
    vm.runInContext(BG_SRC, ctx, { filename: "brownbear-webext-background.js" });
    return ctx.browser;   // browser === chrome
}

// ---- RUNTIME (content script) harness ---------------------------------------------------------------
// Mirrors content-message-dead-frame.test.js: getContentScripts hands back one ISOLATED script whose
// baseURL sets the scheme; the injected script captures its own chrome.runtime onto a global probe so the
// test can read getBrowserInfo from the exact per-content-script surface.
function bootContent(baseURL) {
    const TOKEN = "tkn-gbi-1";
    const sb = {};
    sb.globalThis = sb; sb.self = sb; sb.window = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp, Map, Set, Error, Function, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    sb.location = { href: "https://example.com/page", protocol: "https:", host: "example.com", origin: "https://example.com" };
    sb.addEventListener = () => {}; sb.removeEventListener = () => {};
    sb.document = {
        readyState: "interactive",
        addEventListener: () => {}, removeEventListener: () => {},
        documentElement: { appendChild() {} }, head: { appendChild() {} }, body: null,
        createElement: () => ({ textContent: "", setAttribute() {}, style: {}, appendChild() {}, get parentNode() { return null; } }),
        querySelector: () => null
    };
    const CONTENT_JS = "window.__gbiProbe = chrome.runtime;";
    sb.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => {
        const api = msg.api, p = msg.payload || {};
        if (api === "getContentScripts") {
            return Promise.resolve([{
                token: TOKEN, extensionId: ID, baseURL: baseURL, manifestJSON: "{}",
                messages: {}, world: "ISOLATED", runAt: "document_start", js: CONTENT_JS
            }]);
        }
        return Promise.resolve(null);
    } } } };
    vm.createContext(sb);
    vm.runInContext(RUNTIME_SRC, sb, { filename: "brownbear-webext-runtime.js" });
    return sb;
}

// ---- PAGE (popup / options / sidebar) harness -------------------------------------------------------
// Mirrors sessions-theme-api.test.js: __bbExtPage.baseURL carries the scheme; read win.browser.runtime.
function bootPage(baseURL, scheme) {
    const win = {};
    win.window = win; win.self = win; win.globalThis = win;
    win.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    win.navigator = { language: "en-US", userAgent: "Mozilla/5.0", serviceWorker: undefined };
    win.location = new URL(scheme + "://" + ID + "/popup.html");
    win.URL = URL; win.JSON = JSON; win.Object = Object; win.Array = Array;
    win.Promise = Promise; win.Error = Error; win.TypeError = TypeError;
    win.Proxy = Proxy; win.Reflect = Reflect; win.Symbol = Symbol;
    win.structuredClone = (x) => JSON.parse(JSON.stringify(x));
    win.setTimeout = (fn) => { fn(); return 0; }; win.clearTimeout = () => {};
    win.addEventListener = () => {}; win.removeEventListener = () => {}; win.dispatchEvent = () => false;
    win.document = { addEventListener() {}, removeEventListener() {}, readyState: "complete",
                     currentScript: null, visibilityState: "visible" };
    win.fetch = undefined;
    win.webkit = { messageHandlers: { brownbearWebext: { postMessage: () => Promise.resolve(null) } } };
    win.__bbExtPage = {
        token: "tok-test", extensionId: ID, baseURL: baseURL,
        manifestJSON: JSON.stringify({ manifest_version: 3, name: "t", version: "1" }), messages: {}
    };
    vm.createContext(win);
    vm.runInContext(PAGE_SRC, win, { filename: "brownbear-webext-page.js" });
    return win.browser;   // browser === chrome
}

let passed = 0, failed = 0;
const ok = (n) => { console.log("  ok   " + n); passed++; };
const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

// Assert a runtime surface has getBrowserInfo gated correctly: present (function resolving real info) when
// `expectPresent`, otherwise strictly `undefined` (matching the browser we emulate).
async function assertGate(label, runtime, expectPresent) {
    if (expectPresent) {
        assert.strictEqual(typeof runtime.getBrowserInfo, "function",
            label + ": Firefox build must expose getBrowserInfo as a function");
        const info = await runtime.getBrowserInfo();
        assert.ok(info && typeof info === "object" && typeof info.name === "string" && typeof info.version === "string",
            label + ": getBrowserInfo() must resolve {name,version,...}");
        // callback form, too
        await new Promise((resolve, reject) => {
            try { runtime.getBrowserInfo(function (i) {
                try { assert.ok(i && i.name, label + ": callback form yields info"); resolve(); }
                catch (e) { reject(e); }
            }); } catch (e) { reject(e); }
        });
    } else {
        assert.strictEqual(typeof runtime.getBrowserInfo, "undefined",
            label + ": Chrome build must leave getBrowserInfo undefined (real-Chrome feature-detect)");
        assert.strictEqual("getBrowserInfo" in runtime, false,
            label + ": getBrowserInfo must be entirely absent (not an own/inherited key)");
    }
}

(async () => {
    // Table: each row boots a surface under a baseURL and declares whether getBrowserInfo MUST be present.
    // A garbage/malformed baseURL must fail closed to "Chrome" (absent) — it is NOT moz-extension://.
    const CHROME = "chrome-extension://" + ID + "/";
    const FIREFOX = "moz-extension://" + ID + "/";
    const cases = [
        { surface: "background", label: "MV3 SW · chrome-extension", baseURL: CHROME, present: false },
        { surface: "background", label: "MV3 SW · moz-extension",    baseURL: FIREFOX, present: true },
        { surface: "content",    label: "content · chrome-extension", baseURL: CHROME, present: false },
        { surface: "content",    label: "content · moz-extension",    baseURL: FIREFOX, present: true },
        { surface: "page",       label: "page · chrome-extension",    baseURL: CHROME, scheme: "chrome-extension", present: false },
        { surface: "page",       label: "page · moz-extension",       baseURL: FIREFOX, scheme: "moz-extension", present: true },
        // Malformed-input cases: garbage that is NOT the moz-extension scheme must stay Chrome-shaped (absent).
        { surface: "background", label: "MV3 SW · garbage baseURL",        baseURL: "://////not a url", present: false },
        { surface: "background", label: "MV3 SW · moz-substring-not-scheme", baseURL: "https://evil.test/moz-extension://" + ID + "/", present: false },
        { surface: "background", label: "MV3 SW · empty baseURL",          baseURL: "", present: false }
    ];

    for (const c of cases) {
        try {
            let runtime;
            if (c.surface === "background") { runtime = bootBg(c.baseURL).runtime; }
            else if (c.surface === "content") {
                const sb = bootContent(c.baseURL);
                // let loadAndRun's getContentScripts promise resolve and inject the probe
                await new Promise((r) => setTimeout(r, 30));
                assert.ok(sb.__gbiProbe, c.label + ": content script must register its chrome.runtime probe");
                runtime = sb.__gbiProbe;
            } else { runtime = bootPage(c.baseURL, c.scheme || "chrome-extension").runtime; }
            await assertGate(c.label, runtime, c.present);
            ok(c.label + " → getBrowserInfo " + (c.present ? "present (Firefox)" : "absent (Chrome)"));
        } catch (e) { bad(c.label, e); }
    }

    // Cross-check the live regression: the FireShot detector ge() must be FALSE on a Chrome build (so its
    // bare-`window` branch never runs) and TRUE on a Firefox build. We reproduce ge() verbatim.
    try {
        const ge = (browser) => typeof browser !== "undefined"
            && typeof (browser.runtime && browser.runtime.getBrowserInfo) === "function";
        assert.strictEqual(ge(bootBg(CHROME)), false,
            "FireShot's ge() must be false on a Chrome build (no Firefox signal → bare-window branch is dead)");
        assert.strictEqual(ge(bootBg(FIREFOX)), true,
            "ge() must be true on a Firefox build (real Firefox would expose getBrowserInfo)");
        ok("FireShot ge() discriminator: false on Chrome build, true on Firefox build");
    } catch (e) { bad("FireShot ge() discriminator", e); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
