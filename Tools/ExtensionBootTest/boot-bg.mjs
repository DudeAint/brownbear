// /tmp/bbtest/boot-bg.mjs
// Boot ONE extension's BACKGROUND moving part (MV3 service worker OR MV2 background page/scripts)
// through BrownBear's REAL background shim (brownbear-webext-background.js), in a clean Node global
// (one process per extension = full isolation, matching /tmp/ubo-full/harness.mjs's runInThisContext
// model). Reports every boot error and every chrome.* namespace/method the extension touched that the
// shim does not provide.
//
// Usage:  node boot-bg.mjs <extDir> <extId>
// Prints exactly ONE line of JSON (the verdict) to stdout. All diagnostics go to stderr.
//
// Scope (honest): this catches what a headless boot can catch — the background graph LINKING
// (module-not-found / parse error → the extension never starts), top-level synchronous throws,
// unhandled rejections during init, and access to chrome.<ns>[.<method>] that the shim leaves
// undefined. It does NOT exercise real network, real tabs, or anything that needs the live app.

import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

// The shim/runtime JS lives in the app bundle source. Resolve it relative to this script's location
// (Tools/ExtensionBootTest/ → ../../BrownBear/Resources/JS), with an env override for ad-hoc runs.
const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_JS_DIR = process.env.BB_APP_JS_DIR
    || (existsSync(path.join(HERE, '..', '..', 'BrownBear', 'Resources', 'JS'))
        ? path.join(HERE, '..', '..', 'BrownBear', 'Resources', 'JS')
        : '/Users/romanzhylych/Downloads/BrownBear - Userscripts & Power Browser/BrownBear/Resources/JS');
const EXT_DIR = process.argv[2];
const EXT_ID = process.argv[3] || 'testextid';
const BASE_URL = `chrome-extension://${EXT_ID}/`;

// ---------------------------------------------------------------- result accumulators
const errors = [];          // {phase, message, stack}
const missing = new Set();   // "chrome.<ns>" or "chrome.<ns>.<method>" the ext touched but shim lacks
const unhandled = [];
function recordError(phase, e) {
    errors.push({ phase, message: String((e && e.message) || e), stack: String((e && e.stack) || '').split('\n').slice(0, 4).join(' | ') });
}
process.on('unhandledRejection', (e) => { unhandled.push(String((e && e.message) || e)); });
process.on('uncaughtException', (e) => { recordError('uncaught', e); });
// Capture the harness's own process hooks before we hide `process` from the extension (see runEntries).
const _exit = process.exit.bind(process);
const _stdoutWrite = process.stdout.write.bind(process.stdout);

function readExt(p) { try { return readFileSync(path.join(EXT_DIR, p), 'utf8'); } catch { return null; } }

// ---------------------------------------------------------------- timers (captured before the shim
// overwrites globalThis.setTimeout with its __bb_set_timeout wrapper — else infinite recursion).
const _setTimeout = globalThis.setTimeout;
const _setInterval = globalThis.setInterval;
const _clearTimeout = globalThis.clearTimeout;
const _clearInterval = globalThis.clearInterval;
const timerMap = new Map();
let timerSeq = 1;

// ---------------------------------------------------------------- native bridge mocks
// Shapes mirror /tmp/ubo-full/harness.mjs so the shim's promise-wrapping resolves with the data
// shapes it expects. A faithful in-memory storage store avoids false errors from extensions that
// read-after-write during init.
const store = { local: {}, sync: {}, session: {}, managed: {} };
function __bb_storage_get(area, keysJSON, cb) {
    const a = store[area] || {};
    let keys; try { keys = JSON.parse(keysJSON); } catch { keys = null; }
    let out = {};
    if (keys === null || keys === undefined) { out = Object.assign({}, a); }
    else if (Array.isArray(keys)) { for (const k of keys) { if (k in a) { out[k] = a[k]; } } }
    else if (typeof keys === 'object') { for (const k in keys) { out[k] = (k in a) ? a[k] : keys[k]; } }
    else if (typeof keys === 'string') { if (keys in a) { out[keys] = a[keys]; } }
    cb(JSON.stringify(out));
}
function __bb_storage_set(area, itemsJSON, cb) {
    const a = store[area] || (store[area] = {});
    try { Object.assign(a, JSON.parse(itemsJSON || '{}')); } catch {}
    if (typeof cb === 'function') { cb(); }
}
function __bb_storage_remove(area, keysJSON, cb) {
    const a = store[area] || {};
    let keys; try { keys = JSON.parse(keysJSON); } catch { keys = []; }
    if (!Array.isArray(keys)) { keys = [keys]; }
    for (const k of keys) { delete a[k]; }
    if (typeof cb === 'function') { cb(); }
}
function __bb_storage_clear(area, cb) { store[area] = {}; if (typeof cb === 'function') { cb(); } }

function __bb_set_timeout(fn, ms, repeat) {
    const id = timerSeq++;
    if (repeat) {
        const t = _setInterval(() => { try { fn(); } catch (e) { /* timer body */ } }, ms || 0);
        timerMap.set(id, { type: 'interval', t });
    } else {
        const t = _setTimeout(() => { timerMap.delete(id); try { fn(); } catch (e) { /* timer body */ } }, ms || 0);
        timerMap.set(id, { type: 'timeout', t });
    }
    return id;
}
function __bb_clear_timer(id) {
    const e = timerMap.get(id);
    if (!e) { return; }
    if (e.type === 'interval') { _clearInterval(e.t); } else { _clearTimeout(e.t); }
    timerMap.delete(id);
}

// Generic neutral-callback natives. method-aware array returns where a caller commonly iterates.
function cbNull(...args) { const cb = args[args.length - 1]; if (typeof cb === 'function') { try { cb(JSON.stringify(null)); } catch {} } }
function __bb_log(level, msg) { /* swallow ext logging */ }
function __bb_fetch(reqJSON, cb) { cb(JSON.stringify({ ok: false, status: 0, statusText: '', headers: {}, body: '', error: 'no network in harness' })); }
function __bb_fetch_image(src, cb) { cb(JSON.stringify({ error: 'no image loading in harness' })); }
function __bb_send_message(msgJSON, cb) { cb(JSON.stringify({ __bbNoReceiver: true })); }
function __bb_message_response(responseId, valueJSON) { /* harness has no peer */ }
function __bb_tabs(method, argsJSON, cb) { cb(JSON.stringify(method === 'query' ? [] : null)); }
function __bb_tabs_send_message(argsJSON, cb) { cb(JSON.stringify(null)); }
function __bb_scripting(method, argsJSON, cb) { cb(JSON.stringify(method === 'getRegisteredContentScripts' ? [] : null)); }
function __bb_windows(method, argsJSON, cb) { cb(JSON.stringify(method === 'getAll' ? [] : null)); }
function __bb_management(method, argsJSON, cb) { cb(JSON.stringify(method === 'getAll' ? [] : null)); }
function __bb_permissions(method, argsJSON, cb) { cb(JSON.stringify(method === 'getAll' ? { permissions: [], origins: [] } : (method === 'contains' ? true : true))); }
function __bb_dnr(method, argsJSON, cb) { cb(JSON.stringify((method === 'getDynamicRules' || method === 'getSessionRules' || method === 'getEnabledRulesets' || method === 'getAvailableStaticRuleCount') ? [] : null)); }
function __bb_action(method, argsJSON, cb) { cb(JSON.stringify(null)); }
function __bb_context_menus(method, argsJSON, cb) { cb(JSON.stringify(null)); }
function __bb_offscreen(method, argsJSON, cb) { cb(JSON.stringify({ hasDocument: false })); }
function __bb_userscripts(method, argsJSON, cb) { cb(JSON.stringify((method === 'getScripts' || method === 'getWorldConfigurations') ? [] : null)); }
function __bb_cookies(method, argsJSON, cb) { cb(JSON.stringify(method === 'getAll' || method === 'getAllCookieStores' ? [] : null)); }
function __bb_notifications(method, argsJSON, cb) { cb(JSON.stringify(method === 'getAll' ? {} : null)); }
function __bb_browser_data(method, argsJSON, cb) { cb(JSON.stringify(null)); }
function __bb_idle(method, argsJSON, cb) { cb(JSON.stringify('active')); }
function __bb_downloads(method, argsJSON, cb) { cb(JSON.stringify(method === 'search' ? [] : null)); }
function __bb_i18n_detect(text, cb) { cb(JSON.stringify({ isReliable: false, languages: [] })); }
function __bb_runtime_open_options(cb) { if (typeof cb === 'function') { cb(); } }
function __bb_runtime_set_uninstall_url(url, cb) { if (typeof cb === 'function') { cb(); } }
function __bb_get_contexts(filterJSON, cb) { cb(JSON.stringify([])); }
function __bb_search(payloadJSON, cb) { if (typeof cb === 'function') { cb(); } }
function __bb_capture_visible_tab(optsJSON, cb) { cb(JSON.stringify({ error: 'no visible tab in harness' })); }
function __bb_proxy(method, argsJSON, cb) { if (typeof cb === 'function') { cb(JSON.stringify(null)); } }
function __bb_alarm_create(name, when, period) {}
function __bb_alarm_clear(name, cb) { cb(JSON.stringify(true)); }
function __bb_alarm_clear_all(cb) { cb(JSON.stringify(true)); }
function __bb_alarm_get(name, cb) { cb(JSON.stringify(null)); }
function __bb_alarm_get_all(cb) { cb(JSON.stringify([])); }
function __bb_subtle(op, paramsJSON) { return JSON.stringify({ error: 'subtle not available in harness' }); }
function __bb_crypto_random(byteLen) { const a = []; for (let i = 0; i < byteLen; i++) { a.push(Math.floor(Math.random() * 256)); } return JSON.stringify(a); }
function __bb_crypto_uuid() { return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => { const r = Math.floor(Math.random() * 16); const v = c === 'x' ? r : ((r & 0x3) | 0x8); return v.toString(16); }); }
function __bb_crypto_digest(algo, bytes) { return null; }
function __bb_import_script(spec) { return null; }
function __bb_eval_global(src, spec) { return null; }
function __bb_port_post(portId, msgJSON) {}
function __bb_port_disconnect(portId) {}

// ---------------------------------------------------------------- config + manifest
let manifestStr = readExt('manifest.json');
let manifest;
try { manifest = JSON.parse(manifestStr); } catch (e) {
    process.stdout.write(JSON.stringify({ id: EXT_ID, ok: false, fatal: 'manifest.json unreadable/invalid: ' + String(e && e.message || e) }) + '\n');
    process.exit(0);
}
const mv = manifest.manifest_version || 2;
const vendor = (manifest.browser_specific_settings && manifest.browser_specific_settings.gecko) || (manifest.applications && manifest.applications.gecko) ? 'firefox' : 'chrome';
const defaultLocale = manifest.default_locale;
let messagesStr = '{}';
if (defaultLocale) {
    const m = readExt(path.join('_locales', defaultLocale, 'messages.json'));
    if (m) {
        // The native localizer flattens {key:{message,placeholders}} → {key:"text"} before handing the
        // shim __bbBgMessages. Match that here, or getMessage's `messages[key].replace` throws on the raw
        // object (a harness-only false "message.replace is not a function").
        try {
            const raw = JSON.parse(m);
            const flat = {};
            for (const k in raw) { flat[k] = (raw[k] && typeof raw[k] === 'object' && 'message' in raw[k]) ? raw[k].message : raw[k]; }
            messagesStr = JSON.stringify(flat);
        } catch { messagesStr = m; }
    }
}

// ---------------------------------------------------------------- web/DOM globals the shim or a bg
// page may touch. A service worker (MV3) gets a worker-shaped global (no document/window); an MV2
// background page gets a permissive DOM stub (Chrome gives MV2 bg pages a real DOM) so DOM access
// doesn't masquerade as a shim error.
globalThis.self = globalThis;
globalThis.requestAnimationFrame = (fn) => _setTimeout(() => fn(Date.now()), 16);
globalThis.cancelAnimationFrame = (id) => _clearTimeout(id);
globalThis.requestIdleCallback = (fn) => _setTimeout(() => fn({ didTimeout: false, timeRemaining: () => 0 }), 1);
globalThis.cancelIdleCallback = (id) => _clearTimeout(id);
if (typeof globalThis.crypto === 'undefined' || !globalThis.crypto.subtle) {
    try {
        const nodeCrypto = (await import('node:crypto')).webcrypto;
        if (nodeCrypto) { globalThis.crypto = nodeCrypto; }
    } catch {}
}
if (typeof globalThis.Promise.withResolvers !== 'function') {
    globalThis.Promise.withResolvers = function () { let resolve, reject; const promise = new Promise((res, rej) => { resolve = res; reject = rej; }); return { promise, resolve, reject }; };
}

// A permissive "anything" stub: every property read returns another stub, calling/constructing it
// returns a stub, so deep chains (document.getElementById('x').classList.add('y')) never throw.
function makeStub(label) {
    const target = function () {};
    return new Proxy(target, {
        get(t, prop) {
            if (prop === Symbol.toPrimitive) { return () => ''; }
            if (prop === Symbol.iterator) { return undefined; }
            if (prop === 'then') { return undefined; }      // not a thenable
            if (prop === 'toString' || prop === 'valueOf') { return () => ''; }
            if (prop === 'length') { return 0; }
            if (prop === 'nodeType') { return 1; }
            if (prop === 'style' || prop === 'dataset' || prop === 'classList') { return makeStub(label + '.' + String(prop)); }
            return makeStub(label + '.' + String(prop));
        },
        set() { return true; },
        has() { return true; },
        apply() { return makeStub(label + '()'); },
        construct() { return makeStub('new ' + label); },
    });
}
const isWorker = !!(manifest.background && manifest.background.service_worker) && mv === 3;
if (!isWorker) {
    globalThis.window = globalThis;
    globalThis.document = makeStub('document');
    globalThis.navigator = globalThis.navigator || makeStub('navigator');
    globalThis.location = { href: BASE_URL + 'background.html', protocol: 'chrome-extension:', hostname: EXT_ID, search: '', hash: '', pathname: '/background.html', origin: 'chrome-extension://' + EXT_ID, assign() {}, replace() {}, reload() {} };
}

// ---------------------------------------------------------------- install natives, then the shim
Object.assign(globalThis, {
    __bbBgExtId: EXT_ID, __bbBgBaseURL: BASE_URL, __bbBgManifest: manifestStr, __bbBgMessages: messagesStr,
    __bbUserAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    __bbLanguage: 'en-US',
    __bb_log, __bb_set_timeout, __bb_clear_timer, __bb_fetch, __bb_fetch_image, __bb_send_message,
    __bb_message_response, __bb_storage_get, __bb_storage_set, __bb_storage_remove, __bb_storage_clear,
    __bb_alarm_create, __bb_alarm_clear, __bb_alarm_clear_all, __bb_alarm_get, __bb_alarm_get_all,
    __bb_tabs, __bb_tabs_send_message, __bb_scripting, __bb_windows, __bb_management, __bb_permissions,
    __bb_dnr, __bb_action, __bb_context_menus, __bb_offscreen, __bb_userscripts, __bb_cookies,
    __bb_notifications, __bb_browser_data, __bb_idle, __bb_downloads, __bb_i18n_detect, __bb_proxy,
    __bb_runtime_open_options, __bb_runtime_set_uninstall_url, __bb_get_contexts, __bb_search,
    __bb_capture_visible_tab, __bb_subtle, __bb_crypto_random, __bb_crypto_uuid, __bb_crypto_digest,
    __bb_import_script, __bb_eval_global, __bb_port_post, __bb_port_disconnect,
});

function runClassicGlobal(file, label) {
    const src = readFileSync(path.join(APP_JS_DIR, file), 'utf8');
    vm.runInThisContext(src, { filename: label || file });
}

// Match the on-device boot order (WebExtensionBackgroundContext.boot): the IndexedDB engine is
// installed BEFORE the runtime so `indexedDB` exists when the background source runs. The bg context
// is a bare JSContext (not a WKWebView) — without this engine, `indexedDB is not defined` is a FALSE
// positive here, since the device provides it via brownbear-indexeddb.js (fake-indexeddb).
try {
    runClassicGlobal('brownbear-indexeddb.js', 'brownbear-indexeddb.js');
} catch (e) {
    recordError('indexeddb-load', e);
}
try {
    runClassicGlobal('brownbear-acorn.js', 'brownbear-acorn.js');
    runClassicGlobal('brownbear-esm-linker.js', 'brownbear-esm-linker.js');
    runClassicGlobal('brownbear-esm-page-bundler.js', 'brownbear-esm-page-bundler.js');
} catch (e) {
    recordError('linker-load', e);
}
try {
    runClassicGlobal('brownbear-webext-background.js', 'brownbear-webext-background.js');
} catch (e) {
    recordError('shim-load', e);
    process.stdout.write(JSON.stringify({ id: EXT_ID, name: nameOf(manifest), mv, vendor, kind: 'shim-load-fail', ok: false, errors }) + '\n');
    process.exit(0);
}

// ---------------------------------------------------------------- recording proxy over chrome/browser
// Replace globalThis.chrome (and browser) with a 2-level proxy that records access to any namespace
// the shim left undefined, and any undefined method on a defined namespace. The shim's own closure
// captured chrome locally, so this only observes the EXTENSION's background code — exactly the goal.
const realChrome = globalThis.chrome;
// Bundler/JS-engine interop probes, not real API gaps: webpack/esbuild set or test `__esModule`,
// thenable checks read `then`, structured-clone reads `toJSON`, etc. Reading them as undefined is
// the correct, harmless outcome — don't report them as missing chrome.* surface.
const NOISE = new Set(['__esModule', 'then', 'toJSON', '$$typeof', 'constructor', 'prototype',
    'nodeType', 'length', 'name', 'default', 'inspect', 'Symbol(nodejs.util.inspect.custom)']);
function isNoise(prop) { return NOISE.has(prop) || prop.startsWith('@@') || prop.startsWith('Symbol('); }
function wrapNamespace(nsName, nsObj) {
    if (!nsObj || (typeof nsObj !== 'object' && typeof nsObj !== 'function')) { return nsObj; }
    return new Proxy(nsObj, {
        get(t, prop) {
            if (typeof prop === 'symbol') { return t[prop]; }
            const v = t[prop];
            if (v === undefined && !(prop in t) && !isNoise(String(prop))) { missing.add('chrome.' + nsName + '.' + String(prop)); }
            return v;
        },
    });
}
function wrapChrome(c) {
    if (!c) { return c; }
    return new Proxy(c, {
        get(t, prop) {
            if (typeof prop === 'symbol') { return t[prop]; }
            const v = t[prop];
            if (v === undefined && !(prop in t)) { if (!isNoise(String(prop))) { missing.add('chrome.' + String(prop)); } return undefined; }
            if (v && typeof v === 'object') { return wrapNamespace(String(prop), v); }
            return v;
        },
    });
}
try {
    const wrapped = wrapChrome(realChrome);
    globalThis.chrome = wrapped;
    globalThis.browser = wrapped;
} catch (e) { /* keep real if proxy fails */ }

// importScripts for classic SWs that pull in sibling files. An absolute chrome-/moz-extension URL
// (often from getURL()) reduces to its package path; a bare relative path resolves against the SW's
// own directory (importScripts is relative to the importing worker's URL, like Chrome).
function resolveScriptPath(p, baseDir) {
    p = String(p);
    if (/^(?:chrome|moz)-extension:\/\//i.test(p)) { return p.replace(/^(?:chrome|moz)-extension:\/\/[^/]+\//i, ''); }
    if (/^[a-z]+:\/\//i.test(p)) { return null; }   // http(s)/data — can't import in this harness
    if (p.startsWith('/')) { return p.slice(1); }
    return (baseDir && baseDir !== '.') ? baseDir + '/' + p : p;
}
globalThis.importScripts = function (...paths) {
    for (const p of paths) {
        const rel = resolveScriptPath(p, globalThis.__bbSwDir || '.');
        if (rel == null) { continue; }
        const s = readExt(rel);
        if (s == null) { recordError('importScripts', new Error('importScripts: file not found: ' + rel)); continue; }
        try { vm.runInThisContext(s, { filename: rel }); } catch (e) { recordError('importScripts:' + rel, e); }
    }
};

function nameOf(m) { try { return (m.name || '').replace(/^__MSG_.*__$/, m.short_name || '') || EXT_ID; } catch { return EXT_ID; } }

// ---------------------------------------------------------------- determine + run the background entry
function parseHtmlScripts(html) {
    const out = []; let anyModule = false;
    const re = /<script\b([^>]*)>/gi; let m;
    while ((m = re.exec(html)) !== null) {
        const attrs = m[1];
        const srcM = /\bsrc\s*=\s*["']([^"']+)["']/i.exec(attrs);
        if (!srcM) { continue; }
        if (/\btype\s*=\s*["']module["']/i.test(attrs)) { anyModule = true; }
        out.push(srcM[1]);
    }
    return { entries: out, anyModule };
}

const bg = manifest.background || {};
let kind = 'none';
let entries = [];
let isModule = false;
let entriesHtmlPath = '__bgroot__.html';

if (bg.service_worker) {
    kind = 'sw'; entries = [bg.service_worker]; isModule = bg.type === 'module';
    globalThis.__bbSwDir = path.dirname(bg.service_worker);   // importScripts resolves relative to this
} else if (Array.isArray(bg.scripts) && bg.scripts.length) {
    kind = 'mv2-scripts'; entries = bg.scripts.slice();
    isModule = bg.type === 'module';   // Firefox MV3 event page can be type:module scripts
} else if (bg.page) {
    const html = readExt(bg.page);
    if (html == null) { recordError('bg-page-read', new Error('background.page not found: ' + bg.page)); kind = 'mv2-page'; }
    else {
        const parsed = parseHtmlScripts(html);
        entries = parsed.entries; isModule = parsed.anyModule;
        kind = parsed.anyModule ? 'mv2-page(module)' : 'mv2-page';
        entriesHtmlPath = bg.page;
    }
}

// Set the module reader for the bundler/linker (resolves ext-relative module paths).
globalThis.__bbModuleSource = function (p) {
    try { return readFileSync(path.join(EXT_DIR, p), 'utf8'); } catch { return null; }
};
globalThis.__bbBgBaseURL = BASE_URL;

function runEntries() {
    if (kind === 'none') { return; }
    if (isModule) {
        // Pre-link the module graph into one classic script (same path BrownBear uses on-device), then
        // execute it; per-entry link/run errors land in globalThis.__bbPageBundle.
        let code;
        try {
            const htmlPath = (kind.startsWith('mv2-page')) ? entriesHtmlPath : '__bgroot__.html';
            code = globalThis.__bbBundlePage(JSON.stringify(entries), htmlPath, BASE_URL);
        } catch (e) { recordError('bundle-link', e); return; }
        try { vm.runInThisContext(code, { filename: '__bgbundle__.js' }); } catch (e) { recordError('bundle-run', e); return; }
        const rep = globalThis.__bbPageBundle;
        if (rep && rep.errors && rep.errors.length) {
            for (const er of rep.errors) { recordError('module-entry:' + er.entry, { message: er.message, stack: er.stack }); }
        }
    } else {
        // Classic background scripts (and MV2 bg-page classic scripts) run in order, sharing one global.
        const dir = (kind.startsWith('mv2-page')) ? path.dirname(entriesHtmlPath) : '.';
        for (const e of entries) {
            const rel = (kind.startsWith('mv2-page') && dir !== '.' && !e.startsWith('/')) ? path.join(dir, e) : e.replace(/^\//, '');
            const src = readExt(rel);
            if (src == null) { recordError('script-read', new Error('background script not found: ' + rel)); continue; }
            try { vm.runInThisContext(src, { filename: rel }); } catch (er) { recordError('script-run:' + rel, er); }
        }
    }
}

// A real MV3 service worker runs in a JSContext with NO Node globals. Node's process/module/global/
// require being visible makes isomorphic libs take their Node code path — js-sha1 in DuckDuckGo's
// bundle does `if (NODE_JS) nodeWrap()` → `eval("require('crypto')")` → "require is not defined" (ESM
// has no require). Hide them so the harness boots the extension the way the device's JSContext does.
globalThis.process = undefined;
globalThis.module = undefined;
globalThis.global = undefined;
globalThis.require = undefined;

runEntries();

// Let async init settle (registrations, microtasks), then report.
await new Promise((r) => _setTimeout(r, 350));

const verdict = {
    id: EXT_ID,
    name: nameOf(manifest),
    mv, vendor, kind,
    isModule,
    ok: errors.length === 0,
    errorCount: errors.length,
    errors: errors.slice(0, 12),
    unhandled: unhandled.slice(0, 8),
    missing: Array.from(missing).sort(),
};
// Sentinel-prefix the verdict so the driver can pick it out even if the extension wrote its own
// lines to stdout, and flush BEFORE exiting (process.exit can truncate a still-buffered write).
_stdoutWrite('BBVERDICT:' + JSON.stringify(verdict) + '\n', () => {
    // Hard-exit so lingering timers/intervals from the ext don't keep the process alive.
    _exit(0);
});
// Safety net: if the write callback never fires (closed pipe), still exit shortly.
_setTimeout(() => _exit(0), 500);
