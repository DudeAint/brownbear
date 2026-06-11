// /tmp/bbtest/engine.mjs
// BrownBear OFFLINE ENGINE — runs an extension's background worker (JSContext) AND its popup
// (WKWebView) together in one Node process, wired by a faithful re-implementation of BrownBear's
// native layer: shared chrome.storage, the popup↔worker runtime-message router, the port hub, and the
// service-worker fetch bridge. This lets the real popup↔worker handshake happen offline so deep
// cross-context bugs (Bitwarden's state migration, Stylus's SW-client messaging) reproduce here.
//
// Usage:  node engine.mjs <extDir> <extId> [popupHtmlRel]
//   - boots the worker, fires onInstalled+onStartup, optionally boots the popup HTML, runs a few
//     seconds, then dumps: worker logs, popup logs, the shared storage, and a verdict.
//
// Honest scope: the popup runs against a permissive DOM (no real layout), so DOM-heavy rendering is
// best-effort — but storage, messaging, ports, and the SW-fetch path are REAL, which is what these
// bugs live in.

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { MessageChannel as NodeMessageChannel } from 'node:worker_threads';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_JS_DIR = process.env.BB_APP_JS_DIR
    || (existsSync(path.join(HERE, '..', '..', 'BrownBear', 'Resources', 'JS'))
        ? path.join(HERE, '..', '..', 'BrownBear', 'Resources', 'JS')
        : '/Users/romanzhylych/Downloads/BrownBear - Userscripts & Power Browser/BrownBear/Resources/JS');
const EXT_DIR = process.argv[2];
const EXT_ID = process.argv[3] || 'engineextid';
let POPUP_HTML = process.argv[4] || null;
const BASE_URL = `chrome-extension://${EXT_ID}/`;
const appJS = (f) => readFileSync(path.join(APP_JS_DIR, f), 'utf8');
const extFile = (p) => { try { return readFileSync(path.join(EXT_DIR, String(p).replace(/^\//, '')), 'utf8'); } catch { return null; } };
const extBytes = (p) => { try { return readFileSync(path.join(EXT_DIR, String(p).replace(/^\//, ''))); } catch { return null; } };

const manifest = JSON.parse(extFile('manifest.json'));
const mv = manifest.manifest_version || 3;
const vendor = (manifest.browser_specific_settings?.gecko || manifest.applications?.gecko) ? 'firefox' : 'chrome';
let messages = {};
if (manifest.default_locale) {
    const m = extFile(path.join('_locales', manifest.default_locale, 'messages.json'));
    if (m) { try { const raw = JSON.parse(m); for (const k in raw) { messages[k] = (raw[k] && typeof raw[k] === 'object' && 'message' in raw[k]) ? raw[k].message : raw[k]; } } catch {} }
}

// ============================================================ THE SHARED NATIVE HOST
const log = [];
function L(tag, msg) { log.push(`[${tag}] ${String(msg).slice(0, 300)}`); }
// Keep the engine alive through a context's async throws so we still reach the summary.
process.on('uncaughtException', (e) => { L('UNCAUGHT', (e && e.message || e) + '  @ ' + String(e && e.stack || '').split('\n').slice(1, 3).join(' | ')); });
process.on('unhandledRejection', (e) => { L('REJECT', (e && e.message || e) + '  @ ' + String(e && e.stack || '').split('\n').slice(1, 3).join(' | ')); });

const _bcChannels = {};   // same-context BroadcastChannel registry (popup)
// chrome.storage — ONE store shared by worker + popup (native-backed, per-extension), like the device.
const storage = { local: {}, sync: {}, session: {}, managed: {} };
function storageGet(area, keys) {
    const a = storage[area] || {};
    if (keys == null) { return { ...a }; }
    const out = {};
    if (Array.isArray(keys)) { for (const k of keys) { if (k in a) { out[k] = a[k]; } } }
    else if (typeof keys === 'object') { for (const k in keys) { out[k] = (k in a) ? a[k] : keys[k]; } }
    else if (typeof keys === 'string') { if (keys in a) { out[keys] = a[keys]; } }
    return out;
}
function storageSet(area, items) {
    const a = storage[area] || (storage[area] = {});
    const changes = {};
    for (const k in items) { changes[k] = { oldValue: a[k], newValue: items[k] }; a[k] = items[k]; }
    fanStorageChanged(area, changes);
}
function storageRemove(area, keys) {
    const a = storage[area] || {}; const ks = Array.isArray(keys) ? keys : [keys]; const changes = {};
    for (const k of ks) { if (k in a) { changes[k] = { oldValue: a[k], newValue: undefined }; delete a[k]; } }
    fanStorageChanged(area, changes);
}
function storageClear(area) {
    const a = storage[area] || {}; const changes = {};
    for (const k in a) { changes[k] = { oldValue: a[k], newValue: undefined }; }
    storage[area] = {}; fanStorageChanged(area, changes);
}
// Fan a storage change to BOTH contexts (worker via __bbBg, popup via __brownbearExtPage).
function fanStorageChanged(area, changes) {
    if (!Object.keys(changes).length) { return; }
    if (worker && worker.__bbBg && typeof worker.__bbBg.dispatchStorageChanged === 'function') {
        try { worker.__bbBg.dispatchStorageChanged(area, jsonChanges(changes)); } catch (e) {}
    }
    if (popup && popup.extPage && typeof popup.extPage.dispatchStorageChanged === 'function') {
        try { popup.extPage.dispatchStorageChanged(area, jsonChanges(changes)); } catch (e) {}
    }
}
function jsonChanges(changes) {
    const out = {};
    for (const k in changes) { out[k] = { oldValue: changes[k].oldValue === undefined ? null : JSON.stringify(changes[k].oldValue), newValue: changes[k].newValue === undefined ? null : JSON.stringify(changes[k].newValue) }; }
    return JSON.stringify(out);
}

// Runtime messaging router (popup ↔ worker), mirroring WebExtensionRuntime.sendRuntimeMessage.
let responseSeq = 0;
const pendingWorkerResponses = new Map();   // responseId -> resolve  (worker → popup direction)
const pendingPopupResponses = new Map();    // responseId -> resolve  (popup → worker direction)

// popup → worker runtime.sendMessage. Returns a Promise of the worker's reply ({value} / null / noReceiver).
function deliverMessageToWorker(message, sender) {
    return new Promise((resolve) => {
        if (!worker || !worker.__bbBg) { resolve({ __bbNoReceiver: true }); return; }
        const rid = 'w' + (++responseSeq);
        let settled = false;
        pendingPopupResponses.set(rid, (payload) => { if (settled) { return; } settled = true; pendingPopupResponses.delete(rid); resolve(payload); });
        try { worker.__bbBg.dispatchMessage(message, sender, rid); }
        catch (e) { L('host', 'dispatchMessage threw: ' + e.message); if (!settled) { settled = true; resolve(null); } }
        setTimeout(() => { if (!settled) { settled = true; pendingPopupResponses.delete(rid); resolve(null); } }, 4000);
    });
}
// worker → popup runtime.sendMessage (broadcast to the open popup).
function deliverMessageToPopup(message, sender) {
    return new Promise((resolve) => {
        if (!popup || !popup.extPage || typeof popup.extPage.dispatchMessage !== 'function') { resolve({ __bbNoReceiver: true }); return; }
        const rid = 'p' + (++responseSeq);
        let settled = false;
        pendingWorkerResponses.set(rid, (value) => { if (settled) { return; } settled = true; pendingWorkerResponses.delete(rid); resolve(value == null ? null : { value }); });
        try { popup.extPage.dispatchMessage(message, sender, rid); }
        catch (e) { resolve(null); }
        setTimeout(() => { if (!settled) { settled = true; pendingWorkerResponses.delete(rid); resolve(null); } }, 4000);
    });
}

// Port hub (popup ↔ worker), mirroring WebExtensionPortHub.
let portSeq = 0;
const portPeers = new Map();   // portId -> 'worker' | 'popup'  (which side is the WORKER end)
function portConnectFromPopup(name, sender) {
    const portId = 'port' + (++portSeq);
    portPeers.set(portId, true);
    if (worker && worker.__bbBg && typeof worker.__bbBg.dispatchPortConnect === 'function') {
        try { worker.__bbBg.dispatchPortConnect(portId, JSON.stringify(name || ''), JSON.stringify(sender || { id: EXT_ID })); }
        catch (e) { L('host', 'dispatchPortConnect threw: ' + e.message); }
    }
    return portId;
}

// SW fetch bridge — serve an unpackaged extension-scheme request via the worker's fetch handler.
const pendingFetch = new Map();
let fetchSeq = 0;
function serviceWorkerFetch(urlString) {
    return new Promise((resolve) => {
        if (!worker || typeof worker.dispatchFetch !== 'function') { resolve(null); return; }
        const rid = 'f' + (++fetchSeq);
        let settled = false;
        pendingFetch.set(rid, (json) => { if (settled) { return; } settled = true; pendingFetch.delete(rid); try { resolve(JSON.parse(json)); } catch { resolve(null); } });
        try { worker.dispatchFetch(urlString, 'GET', '{}', rid); } catch (e) { resolve(null); }
        setTimeout(() => { if (!settled) { settled = true; pendingFetch.delete(rid); resolve(null); } }, 4000);
    });
}

// ============================================================ WORKER CONTEXT (background JSContext)
let worker = null;
function bootWorker() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb;
    sb.console = { log: (...a) => L('wkr', a.join(' ')), warn: (...a) => L('wkr', a.join(' ')), error: (...a) => L('wkr!', a.join(' ')), info: (...a) => L('wkr', a.join(' ')), debug: () => {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Error, Symbol, Promise, String, Number, Boolean, RegExp, Map, Set, WeakMap, WeakSet, ArrayBuffer, Uint8Array, Int8Array, Uint16Array, Int16Array, Uint32Array, Int32Array, Float32Array, Float64Array, DataView, Proxy, Reflect, Function, parseInt, parseFloat, isNaN, isFinite, encodeURIComponent, decodeURIComponent, encodeURI, decodeURI, escape, unescape, TextEncoder, TextDecoder, URL, URLSearchParams, WebAssembly, structuredClone });
    sb.crypto = webcrypto; sb.atob = (s) => Buffer.from(s, 'base64').toString('binary'); sb.btoa = (s) => Buffer.from(s, 'binary').toString('base64');
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    sb.queueMicrotask = queueMicrotask; sb.structuredClone = structuredClone; sb.Blob = Blob;
    // NOTE: caches / createImageBitmap / OffscreenCanvas are intentionally NOT provided here — the bg
    // shim now supplies them; leaving them out validates that real fix through the engine.
    if (typeof sb.Promise.withResolvers !== 'function') { sb.Promise.withResolvers = function () { let r, j; const p = new Promise((a, b) => { r = a; j = b; }); return { promise: p, resolve: r, reject: j }; }; }
    // Native bridges → host
    sb.__bb_log = (lvl, msg) => L('wkr', '[' + lvl + '] ' + msg);
    sb.__bb_set_timeout = (fn, ms, repeat) => repeat ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0);
    sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bb_storage_get = (area, keysJSON, cb) => { let keys; try { keys = JSON.parse(keysJSON); } catch { keys = null; } cb(JSON.stringify(storageGet(area, keys))); };
    sb.__bb_storage_set = (area, itemsJSON, cb) => { try { storageSet(area, JSON.parse(itemsJSON || '{}')); } catch {} if (cb) { cb(); } };
    sb.__bb_storage_remove = (area, keysJSON, cb) => { let keys; try { keys = JSON.parse(keysJSON); } catch { keys = []; } storageRemove(area, keys); if (cb) { cb(); } };
    sb.__bb_storage_clear = (area, cb) => { storageClear(area); if (cb) { cb(); } };
    sb.__bb_send_message = (msgJSON, cb) => {
        let parsed; try { parsed = JSON.parse(msgJSON); } catch { parsed = {}; }
        deliverMessageToPopup(parsed.message, parsed.sender || { id: EXT_ID }).then((res) => cb(JSON.stringify(res == null ? null : res)));
    };
    sb.__bb_message_response = (responseId, valueJSON) => {
        let v = null; try { v = valueJSON ? JSON.parse(valueJSON) : null; } catch {}
        const r = pendingPopupResponses.get(responseId); if (r) { r(v); }
    };
    sb.__bb_port_post = (portId, msgJSON) => { let m; try { m = JSON.parse(msgJSON); } catch { m = null; } if (popup && popup.extPage && typeof popup.extPage.onPortMessage === 'function') { try { popup.extPage.onPortMessage(portId, m); } catch (e) {} } };
    sb.__bb_port_disconnect = (portId) => { if (popup && popup.extPage && typeof popup.extPage.onPortDisconnect === 'function') { try { popup.extPage.onPortDisconnect(portId); } catch (e) {} } };
    sb.__bb_sw_fetch_response = (requestId, json) => { const r = pendingFetch.get(requestId); if (r) { r(json); } };
    // Method-aware natives (match the device's shapes — list methods return [], not null, or the
    // extension's `x.map(...)` / spread throws, which is NOT a device bug).
    sb.__bb_tabs = (m, a, cb) => cb(JSON.stringify(m === 'query' ? [] : null));
    sb.__bb_scripting = (m, a, cb) => cb(JSON.stringify(m === 'getRegisteredContentScripts' ? [] : null));
    sb.__bb_dnr = (m, a, cb) => cb(JSON.stringify((m === 'getDynamicRules' || m === 'getSessionRules' || m === 'getEnabledRulesets') ? [] : null));
    sb.__bb_management = (m, a, cb) => cb(JSON.stringify(m === 'getAll' ? [] : null));
    sb.__bb_windows = (m, a, cb) => cb(JSON.stringify(m === 'getAll' ? [] : null));
    sb.__bb_cookies = (m, a, cb) => cb(JSON.stringify((m === 'getAll' || m === 'getAllCookieStores') ? [] : null));
    sb.__bb_permissions = (m, a, cb) => cb(JSON.stringify(m === 'getAll' ? { permissions: [], origins: [] } : true));
    sb.__bb_userscripts = (m, a, cb) => cb(JSON.stringify((m === 'getScripts' || m === 'getWorldConfigurations') ? [] : null));
    sb.__bb_downloads = (m, a, cb) => cb(JSON.stringify(m === 'search' ? [] : null));
    sb.__bb_idle = (m, a, cb) => cb(JSON.stringify('active'));
    sb.__bb_notifications = (m, a, cb) => cb(JSON.stringify(m === 'getAll' ? {} : null));
    sb.__bb_get_contexts = (f, cb) => cb(JSON.stringify([]));
    sb.__bb_i18n_detect = (t, cb) => cb(JSON.stringify({ isReliable: false, languages: [] }));
    sb.__bb_fetch = (reqJSON, cb) => {
        let req; try { req = JSON.parse(reqJSON); } catch { req = {}; }
        const url = String(req.url || '');
        const m = /^(?:chrome|moz)-extension:\/\/[^/]+\/(.+)$/.exec(url);   // serve extension-local files (icons, etc.)
        if (m) { const rel = m[1].split('?')[0]; const bytes = extBytes(rel); if (bytes) { cb(JSON.stringify({ ok: true, status: 200, statusText: 'OK', url, headers: { 'content-type': 'application/octet-stream' }, bodyBase64: bytes.toString('base64') })); return; } }
        cb(JSON.stringify({ ok: false, status: 0, statusText: '', headers: {}, body: '', error: 'no network' }));
    };
    const cbNull = (...a) => { const c = a[a.length - 1]; if (typeof c === 'function') { try { c(JSON.stringify(null)); } catch {} } };
    for (const n of ['__bb_fetch_image', '__bb_tabs_send_message', '__bb_action', '__bb_context_menus', '__bb_offscreen', '__bb_browser_data', '__bb_search', '__bb_capture_visible_tab', '__bb_proxy', '__bb_alarm_create', '__bb_alarm_clear', '__bb_alarm_clear_all', '__bb_alarm_get', '__bb_alarm_get_all', '__bb_runtime_open_options', '__bb_runtime_set_uninstall_url']) { sb[n] = cbNull; }
    sb.__bb_subtle = () => JSON.stringify({ error: 'n/a' }); sb.__bb_crypto_random = (n) => { const a = []; for (let i = 0; i < n; i++) { a.push((i * 37) & 255); } return JSON.stringify(a); }; sb.__bb_crypto_uuid = () => '00000000-0000-4000-8000-000000000000'; sb.__bb_crypto_digest = () => null; sb.__bb_import_script = () => null; sb.__bb_eval_global = () => null; sb.__bb_runtime_reload = () => {};
    sb.__bbBgExtId = EXT_ID; sb.__bbBgBaseURL = BASE_URL; sb.__bbBgManifest = JSON.stringify(manifest); sb.__bbBgMessages = JSON.stringify(messages); sb.__bbBgPlaceholders = '{}';
    sb.__bbUserAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Chrome/121.0.0.0 Mobile/15E148 Safari/604.1'; sb.__bbLanguage = 'en-US';
    sb.importScripts = (...paths) => { for (const p of paths) { const rel = String(p).replace(/^(?:chrome|moz)-extension:\/\/[^/]+\//i, ''); const s = extFile(rel); if (s != null) { try { vm.runInContext(s, sb, { filename: rel }); } catch (e) { L('wkr!', 'importScripts ' + rel + ': ' + e.message); } } } };

    vm.createContext(sb);
    const runW = (file, label) => vm.runInContext(appJS(file), sb, { filename: label || file });
    try { runW('brownbear-indexeddb.js'); } catch (e) { L('wkr!', 'idb: ' + e.message); }
    try { runW('brownbear-acorn.js'); runW('brownbear-esm-linker.js'); runW('brownbear-esm-page-bundler.js'); } catch (e) { L('wkr!', 'linker: ' + e.message); }
    sb.__bbModuleSource = (p) => extFile(p);
    try { runW('brownbear-webext-background.js'); } catch (e) { L('wkr!', 'SHIM LOAD FAILED: ' + e.message); }

    worker = { sb, __bbBg: sb.__bbBg, dispatchFetch: sb.__bbDispatchFetch };

    // Run the extension's background.
    const bg = manifest.background || {};
    try {
        if (bg.service_worker) {
            const swPath = bg.service_worker;
            if (bg.type === 'module') { const code = sb.__bbBundlePage(JSON.stringify([swPath]), '__sw__.html', BASE_URL); vm.runInContext(code, sb, { filename: '__swbundle__.js' }); }
            else { const src = extFile(swPath); if (src != null) { vm.runInContext(src, sb, { filename: swPath }); } }
        } else if (Array.isArray(bg.scripts)) { for (const s of bg.scripts) { const src = extFile(s); if (src != null) { vm.runInContext(src, sb, { filename: s }); } } }
    } catch (e) { L('wkr!', 'bg source threw: ' + e.message + ' @ ' + String(e.stack || '').split('\n')[1]); }
}

// ============================================================ POPUP CONTEXT (WKWebView page)
let popup = null;
function makeStub(label) {
    const t = function () {};
    return new Proxy(t, {
        get(o, p) { if (p === Symbol.toPrimitive) { return () => ''; } if (p === Symbol.iterator) { return undefined; } if (p === 'then') { return undefined; } if (p === 'toString' || p === 'valueOf') { return () => ''; } if (p === 'length') { return 0; } if (p === 'nodeType') { return 1; } if (typeof p === 'string' && ['querySelectorAll', 'getElementsByTagName', 'getElementsByClassName', 'children', 'childNodes'].includes(p)) { return () => []; } return makeStub(label + '.' + String(p)); },
        set() { return true; }, has() { return true; }, apply() { return makeStub(label + '()'); }, construct() { return makeStub('new ' + label); }
    });
}
async function bootPopup(htmlRel) {
    const sb = {};
    sb.globalThis = sb; sb.self = sb; sb.window = sb; sb.top = sb; sb.parent = sb; sb.frames = sb; sb.opener = null; sb.frameElement = null; sb.length = 0;
    sb.console = { log: (...a) => L('pop', a.join(' ')), warn: (...a) => L('pop', a.join(' ')), error: (...a) => L('pop!', a.join(' ')), info: (...a) => L('pop', a.join(' ')), debug: () => {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Error, Symbol, Promise, String, Number, Boolean, RegExp, Map, Set, WeakMap, WeakSet, ArrayBuffer, Uint8Array, Int8Array, Uint16Array, Uint32Array, Int32Array, Float32Array, Float64Array, DataView, Proxy, Reflect, Function, parseInt, parseFloat, isNaN, isFinite, encodeURIComponent, decodeURIComponent, encodeURI, decodeURI, TextEncoder, TextDecoder, URL, URLSearchParams, WebAssembly, structuredClone });
    sb.crypto = webcrypto; sb.atob = (s) => Buffer.from(s, 'base64').toString('binary'); sb.btoa = (s) => Buffer.from(s, 'binary').toString('base64');
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    sb.requestAnimationFrame = (fn) => setTimeout(() => fn(Date.now()), 16); sb.cancelAnimationFrame = clearTimeout;
    sb.requestIdleCallback = (fn) => setTimeout(() => fn({ didTimeout: false, timeRemaining: () => 0 }), 1); sb.cancelIdleCallback = clearTimeout;
    sb.devicePixelRatio = 2; sb.innerWidth = 380; sb.innerHeight = 600; sb.scrollX = 0; sb.scrollY = 0;
    sb.addEventListener = () => {}; sb.removeEventListener = () => {}; sb.dispatchEvent = () => true;
    sb.onerror = function () {}; sb.onunhandledrejection = null; sb.onload = null; sb.onunload = null; sb.onbeforeunload = null; sb.onmessage = null;
    sb.createImageBitmap = () => Promise.resolve({ width: 16, height: 16, close() {} });
    sb.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
    sb.getComputedStyle = () => makeStub('cs');
    if (typeof sb.Promise.withResolvers !== 'function') { sb.Promise.withResolvers = function () { let r, j; const p = new Promise((a, b) => { r = a; j = b; }); return { promise: p, resolve: r, reject: j }; }; }
    // document.write injects scripts that the parser then loads (Stylus's get-client-data.js writes
    // `<script src="data?…">`, served by the SW fetch handler). Capture those so the loader runs them.
    const writeQueue = [];
    const docStub = makeStub('document');
    sb.document = new Proxy(function () {}, {
        get(t, p) {
            if (p === 'write' || p === 'writeln') { return (...args) => { const html = args.join(''); const re = /<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>/gi; let m; while ((m = re.exec(html)) !== null) { writeQueue.push(m[1]); } }; }
            if (typeof p === 'symbol') { return docStub[p]; }
            return docStub[p];
        }, set() { return true; }, has() { return true; }, apply() { return makeStub('document()'); }, construct() { return makeStub('new document'); }
    });
    sb.__writeQueue = writeQueue;
    sb.EventTarget = class EventTarget { constructor() { this.__l = {}; } addEventListener(t, f) { (this.__l[t] = this.__l[t] || []).push(f); } removeEventListener(t, f) { const a = this.__l[t]; if (a) { const i = a.indexOf(f); if (i >= 0) { a.splice(i, 1); } } } dispatchEvent(e) { const a = this.__l[e && e.type] || []; for (const f of a.slice()) { try { f(e); } catch (x) {} } return true; } };
    for (const n of ['Element', 'HTMLElement', 'HTMLDivElement', 'HTMLInputElement', 'Node', 'Text', 'DocumentFragment', 'ShadowRoot', 'Window', 'Document', 'Event', 'CustomEvent', 'MouseEvent', 'KeyboardEvent', 'CSSStyleSheet', 'CSSStyleRule', 'AbortController', 'AbortSignal']) { if (typeof sb[n] === 'undefined') { sb[n] = class extends sb.EventTarget {}; } }
    // A DOM-faithful MessageChannel (Stylus's createPortExec relies on it): port.postMessage queues to the
    // peer; setting onmessage (or start()/addEventListener) starts delivery, flushing any queue.
    sb.MessageChannel = function MessageChannel() {
        function makePort() {
            const port = { _peer: null, _started: false, _queue: [], _ls: [], _onmessage: null, onmessageerror: null,
                postMessage(x) { const peer = this._peer; const ev = { data: x, ports: [], type: 'message' }; setTimeout(() => { if (peer._started) { peer._deliver(ev); } else { peer._queue.push(ev); } }, 0); },
                start() { if (this._started) { return; } this._started = true; const q = this._queue; this._queue = []; for (const ev of q) { this._deliver(ev); } },
                close() { this._started = false; },
                addEventListener(t, f) { if (t === 'message' && typeof f === 'function') { this._ls.push(f); this.start(); } },
                removeEventListener(t, f) { const i = this._ls.indexOf(f); if (i >= 0) { this._ls.splice(i, 1); } },
                _deliver(ev) { if (typeof this._onmessage === 'function') { try { this._onmessage(ev); } catch (e) {} } for (const l of this._ls.slice()) { try { l(ev); } catch (e) {} } } };
            Object.defineProperty(port, 'onmessage', { get() { return this._onmessage; }, set(fn) { this._onmessage = fn; if (typeof fn === 'function') { this.start(); } } });
            return port;
        }
        const p1 = makePort(), p2 = makePort(); p1._peer = p2; p2._peer = p1;
        this.port1 = p1; this.port2 = p2;
    };
    sb.MessagePort = function MessagePort() {};
    for (const n of ['IntersectionObserver', 'MutationObserver', 'ResizeObserver']) { sb[n] = class { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } }; }
    sb.customElements = { define() {}, get() {}, whenDefined() { return Promise.resolve(); } };
    sb.CSS = { supports: () => false, escape: (s) => String(s) };
    sb.queueMicrotask = queueMicrotask;
    // BroadcastChannel (WKWebView has it natively; the engine sandbox needs a same-context loopback).
    // Stylus's popup does `new BroadcastChannel("sw")` and uses it as a port.
    sb.BroadcastChannel = function BroadcastChannel(name) {
        this.name = String(name); this.onmessage = null; this.onmessageerror = null; this._closed = false;
        (_bcChannels[this.name] = _bcChannels[this.name] || []).push(this);
        this.postMessage = (data) => { for (const ch of (_bcChannels[this.name] || [])) { if (ch !== this && !ch._closed) { setTimeout(() => { if (typeof ch.onmessage === 'function') { try { ch.onmessage({ data, type: 'message' }); } catch (e) {} } }, 0); } } };
        this.close = () => { this._closed = true; const a = _bcChannels[this.name]; if (a) { const i = a.indexOf(this); if (i >= 0) { a.splice(i, 1); } } };
        this.addEventListener = (t, f) => { if (t === 'message' && typeof f === 'function') { this.onmessage = f; } };
        this.removeEventListener = () => {};
    };
    sb.navigator = { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Chrome/121.0.0.0 Mobile/15E148 Safari/604.1', language: 'en-US', languages: ['en-US', 'en'], onLine: true, clipboard: makeStub('clip'), locks: { request: (n, o, cb) => { if (typeof o === 'function') { cb = o; } return Promise.resolve().then(() => typeof cb === 'function' ? cb({ name: String(n), mode: 'exclusive' }) : undefined); }, query: () => Promise.resolve({ held: [], pending: [] }) } };
    sb.location = { href: BASE_URL + (htmlRel || 'popup.html'), protocol: 'chrome-extension:', host: EXT_ID, hostname: EXT_ID, pathname: '/' + (htmlRel || 'popup.html'), search: '', hash: '', origin: 'chrome-extension://' + EXT_ID, assign() {}, replace() {}, reload() {} };

    // The native bridge the page shim calls.
    sb.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => hostBridge(msg) } } };
    sb.__bbExtPage = { token: 'engine-token', extensionId: EXT_ID, manifestJSON: JSON.stringify(manifest), baseURL: BASE_URL, messages, placeholders: {} };

    vm.createContext(sb);
    const runP = (file, label) => vm.runInContext(appJS(file), sb, { filename: label || file });
    try { runP('brownbear-idle-callback.js'); } catch (e) {}
    try { runP('brownbear-webext-page.js'); } catch (e) { L('pop!', 'page shim load: ' + e.message); }
    try { runP('brownbear-acorn.js'); runP('brownbear-esm-linker.js'); runP('brownbear-esm-page-bundler.js'); } catch (e) {}
    sb.__bbModuleSource = (p) => extFile(p);
    sb.__bbBgBaseURL = BASE_URL;
    popup = { sb, extPage: sb.__brownbearExtPage };

    // Load the popup HTML's scripts (module graph pre-linked, classics eval'd).
    const html = extFile(htmlRel);
    if (html == null) { L('host', 'popup html not found: ' + htmlRel); return; }
    const modules = [], classics = [];
    const re = /<script\b([^>]*)>/gi; let m;
    while ((m = re.exec(html)) !== null) { const a = m[1]; const s = /\bsrc\s*=\s*["']([^"']+)["']/i.exec(a); if (!s) { continue; } if (/\btype\s*=\s*["']module["']/i.test(a)) { modules.push(s[1]); } else { classics.push(s[1]); } }
    if (modules.length) {
        try { const code = sb.__bbBundlePage(JSON.stringify(modules), htmlRel, BASE_URL); vm.runInContext(code, sb, { filename: '__popupbundle__.js' }); const rep = sb.__bbPageBundle; if (rep && rep.errors && rep.errors.length) { for (const er of rep.errors) { L('pop!', 'module ' + er.entry + ': ' + er.message); } } }
        catch (e) { L('pop!', 'popup link fail: ' + e.message); }
    }
    const dir = path.dirname(htmlRel);
    async function evalPopupScript(srcAttr) {
        if (/^[a-z]+:\/\//i.test(srcAttr)) { return; }
        const rel = srcAttr.startsWith('/') ? srcAttr.slice(1) : (dir && dir !== '.' ? path.join(dir, srcAttr) : srcAttr);
        const qIdx = rel.indexOf('?');
        const filePath = qIdx >= 0 ? rel.slice(0, qIdx) : rel;
        let src = extFile(filePath);
        if (src == null) {
            // Not a packaged file → serve it through the worker's fetch handler (Stylus's /data?…).
            const resp = await serviceWorkerFetch(BASE_URL + srcAttr.replace(/^\//, ''));
            if (resp && resp.matched && resp.bodyBase64) { src = Buffer.from(resp.bodyBase64, 'base64').toString('utf8'); L('host', 'popup loaded "' + srcAttr.slice(0, 40) + '" via SW-fetch (' + src.length + 'b)'); }
            else { L('pop!', 'popup script not served: ' + srcAttr.slice(0, 60)); return; }
        }
        try { vm.runInContext(src, sb, { filename: rel }); } catch (e) { L('pop!', 'script ' + filePath + ': ' + e.message); }
        while (writeQueue.length) { await evalPopupScript(writeQueue.shift()); }   // run document.write-injected scripts in order
    }
    for (const c of classics) { await evalPopupScript(c); }
}

// The popup→native bridge. Returns a Promise (WKScriptMessageHandlerWithReply).
function hostBridge(msg) {
    const api = msg && msg.api; const p = (msg && msg.payload) || {};
    switch (api) {
        case 'storage.get': return Promise.resolve(JSON.stringify(storageGet(p.area || 'local', p.keys ?? null)));
        case 'storage.set': storageSet(p.area || 'local', p.items || {}); return Promise.resolve(undefined);
        case 'storage.remove': storageRemove(p.area || 'local', p.keys); return Promise.resolve(undefined);
        case 'storage.clear': storageClear(p.area || 'local'); return Promise.resolve(undefined);
        case 'runtime.sendMessage': return deliverMessageToWorker(p.message, { id: EXT_ID, url: p.url, origin: BASE_URL.slice(0, -1) });
        case 'runtime.messageResponse': { const r = pendingWorkerResponses.get(p.responseId); if (r) { r(p.value); } return Promise.resolve(undefined); }
        case 'port.connect': return Promise.resolve({ portId: portConnectFromPopup(p.name, { id: EXT_ID, url: p.url, origin: BASE_URL.slice(0, -1) }) });
        case 'port.postMessage': if (worker && worker.__bbBg && typeof worker.__bbBg.dispatchPortMessage === 'function') { try { worker.__bbBg.dispatchPortMessage(p.portId, JSON.stringify(p.message ?? null)); } catch (e) {} } return Promise.resolve(undefined);
        case 'port.disconnect': if (worker && worker.__bbBg && typeof worker.__bbBg.dispatchPortDisconnect === 'function') { try { worker.__bbBg.dispatchPortDisconnect(p.portId); } catch (e) {} } return Promise.resolve(undefined);
        case 'runtime.pageLog': L('pop', '[' + (p.level || 'log') + '] ' + p.message); return Promise.resolve(undefined);
        case 'i18n.detectLanguage': return Promise.resolve({ isReliable: false, languages: [] });
        default: return new Promise(() => {});   // unhandled apis pend (popup boot must not depend on them)
    }
}

// ============================================================ DRIVER
async function main() {
    const W = process.stdout;
    bootWorker();
    // Fire the lifecycle the device fires after boot — this is what triggers chrome.runtime.onInstalled,
    // and thus Bitwarden's migrate() / most workers' init.
    await new Promise((r) => setTimeout(r, 50));
    try { if (worker.__bbBg && worker.__bbBg.fireStartup) { worker.__bbBg.fireStartup(); } } catch (e) { L('host', 'fireStartup: ' + e.message); }
    try { if (worker.__bbBg && worker.__bbBg.fireInstalled) { worker.__bbBg.fireInstalled('install', ''); } } catch (e) { L('host', 'fireInstalled: ' + e.message); }
    await new Promise((r) => setTimeout(r, 1200));   // let the worker's onInstalled/migration run

    // Directly exercise the SW fetch path for Stylus's /data?… (the popup loads it as a <script>; if the
    // worker's onfetch didn't register or doesn't claim it, this is the blank-popup root cause).
    const dataUrl = BASE_URL + 'data?dark=true&frameId=0&url=' + encodeURIComponent(BASE_URL + 'popup.html');
    const dataResp = await serviceWorkerFetch(dataUrl);
    L('host', '/data SW-fetch → ' + (dataResp ? ('matched=' + dataResp.matched + ' status=' + dataResp.status + ' body=' + (dataResp.bodyBase64 ? JSON.stringify(Buffer.from(dataResp.bodyBase64, 'base64').toString('utf8').slice(0, 90)) : '(empty)')) : 'NULL (worker had no fetch handler / no response)'));

    // Auto-pick the popup if not given.
    if (!POPUP_HTML) { POPUP_HTML = manifest.action?.default_popup || manifest.browser_action?.default_popup || null; }
    if (POPUP_HTML) { L("host", "opening popup: " + POPUP_HTML); await bootPopup(POPUP_HTML); }
    await new Promise((r) => setTimeout(r, 2500));   // run the handshake

    W.write('\n================ ENGINE RUN: ' + (manifest.name || EXT_ID) + ' (mv' + mv + ' ' + vendor + ') ================\n');
    W.write('--- shared storage.local keys: ' + JSON.stringify(Object.keys(storage.local)) + '\n');
    W.write('    stateVersion=' + JSON.stringify(storage.local.stateVersion) + '  (Bitwarden migration sentinel)\n');
    W.write('--- worker + popup logs (last 60) ---\n');
    for (const line of log.slice(-60)) { W.write('  ' + line + '\n'); }
    W.write('================ end ================\n');
    process.exit(0);
}
main();
setTimeout(() => process.exit(0), 12000);
