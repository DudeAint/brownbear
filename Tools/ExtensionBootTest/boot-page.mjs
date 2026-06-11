// /tmp/bbtest/boot-page.mjs
// Boot ONE extension's PAGE moving parts (action popup, options page, newtab/history/bookmarks
// overrides, devtools page, side panel) through BrownBear's REAL page runtime: the idle-callback
// polyfill + brownbear-webext-page.js (the page shim that bridges chrome.* to the background) +
// the acorn/esm-linker/page-bundler used to pre-link a page's `<script type=module>` graph (WebKit
// won't load module scripts over the custom scheme, so a link failure = a BLANK page on device).
//
// Usage:  node boot-page.mjs <extDir> <extId>
// Prints exactly ONE line of JSON, prefixed `BBVERDICT:`. Diagnostics go to stderr.
//
// Scope (honest): this catches the page failures in OUR control — a module graph that won't LINK
// (blank page), a page script that THROWS at top level, and access to a chrome.* method the PAGE
// shim doesn't provide. It runs against a permissive DOM stub (real rendering / "broken elements"
// needs the device WKWebView), and bridge calls to the background don't resolve here — so a page that
// merely *awaits* data won't be flagged; a page that *throws* or *fails to link* will.

import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_JS_DIR = process.env.BB_APP_JS_DIR
    || (existsSync(path.join(HERE, '..', '..', 'BrownBear', 'Resources', 'JS'))
        ? path.join(HERE, '..', '..', 'BrownBear', 'Resources', 'JS')
        : '/Users/romanzhylych/Downloads/BrownBear - Userscripts & Power Browser/BrownBear/Resources/JS');
const EXT_DIR = process.argv[2];
const EXT_ID = process.argv[3] || 'testextid';
const BASE_URL = `chrome-extension://${EXT_ID}/`;

const _setTimeout = globalThis.setTimeout;
const missing = new Set();
const bridgeCalls = [];
function readExt(p) { try { return readFileSync(path.join(EXT_DIR, p.replace(/^\//, '')), 'utf8'); } catch { return null; } }

// ---------------------------------------------------------------- manifest + flattened messages
let manifestStr = readExt('manifest.json');
let manifest;
try { manifest = JSON.parse(manifestStr); } catch (e) {
    process.stdout.write('BBVERDICT:' + JSON.stringify({ id: EXT_ID, ok: false, fatal: 'manifest unreadable: ' + String(e && e.message || e) }) + '\n');
    process.exit(0);
}
const mv = manifest.manifest_version || 2;
const vendor = (manifest.browser_specific_settings && manifest.browser_specific_settings.gecko) || (manifest.applications && manifest.applications.gecko) ? 'firefox' : 'chrome';
let messages = {};
if (manifest.default_locale) {
    const m = readExt(path.join('_locales', manifest.default_locale, 'messages.json'));
    if (m) { try { const raw = JSON.parse(m); for (const k in raw) { messages[k] = (raw[k] && typeof raw[k] === 'object' && 'message' in raw[k]) ? raw[k].message : raw[k]; } } catch {} }
}

// ---------------------------------------------------------------- permissive DOM + bridge stubs
const ITERABLE_DOM = new Set(['querySelectorAll', 'getElementsByTagName', 'getElementsByClassName',
    'getElementsByName', 'childNodes', 'children', 'getRegisteredEntries']);
function makeStub(label) {
    const target = function () {};
    return new Proxy(target, {
        get(t, prop) {
            if (prop === Symbol.toPrimitive) { return () => ''; }
            if (prop === Symbol.iterator) { return undefined; }
            if (prop === 'then') { return undefined; }
            if (prop === 'toString' || prop === 'valueOf') { return () => ''; }
            if (prop === 'length') { return 0; }
            if (prop === 'nodeType') { return 1; }
            // DOM collection accessors are iterated (for..of / spread); return an empty array so a page
            // that loops over query results doesn't throw "not iterable" (a harness-only artifact).
            if (typeof prop === 'string' && ITERABLE_DOM.has(prop)) { return () => []; }
            return makeStub(label + '.' + String(prop));
        },
        set() { return true; },
        has() { return true; },
        apply() { return makeStub(label + '()'); },
        construct() { return makeStub('new ' + label); },
    });
}

globalThis.self = globalThis;
globalThis.window = globalThis;
// Window self-references a real frame always has; a page that reads `window.top === window` to detect
// being top-level (Stylus's popup) hits a bare ReferenceError without them.
globalThis.top = globalThis;
globalThis.parent = globalThis;
globalThis.frames = globalThis;
globalThis.opener = null;
globalThis.frameElement = null;
globalThis.length = 0;
globalThis.document = makeStub('document');
// Named DOM globals a real WKWebView provides. Defined as empty classes so `class X extends HTMLElement`,
// `instanceof`, and bare reads all work — without them a page script throws a ReferenceError that has
// nothing to do with our shim (pure harness noise).
for (const n of ['Element', 'HTMLElement', 'HTMLDivElement', 'HTMLInputElement', 'HTMLSelectElement',
    'HTMLTextAreaElement', 'HTMLButtonElement', 'HTMLAnchorElement', 'HTMLImageElement', 'HTMLFormElement',
    'HTMLScriptElement', 'HTMLStyleElement', 'HTMLTemplateElement', 'HTMLCanvasElement', 'SVGElement',
    'Node', 'Text', 'Comment', 'DocumentFragment', 'ShadowRoot', 'Window', 'Document', 'Event', 'UIEvent',
    'CustomEvent', 'MouseEvent', 'KeyboardEvent', 'PointerEvent', 'FocusEvent', 'InputEvent', 'NodeList',
    'HTMLCollection', 'DOMTokenList', 'CSSStyleSheet', 'CSSStyleRule', 'StyleSheet', 'DOMParser',
    'XMLSerializer', 'Range', 'AbortController', 'AbortSignal']) {
    if (typeof globalThis[n] === 'undefined') { globalThis[n] = class { constructor() {} }; }
}
for (const n of ['IntersectionObserver', 'MutationObserver', 'ResizeObserver', 'PerformanceObserver']) {
    if (typeof globalThis[n] === 'undefined') { globalThis[n] = class { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } }; }
}
globalThis.customElements = { define() {}, get() {}, whenDefined() { return Promise.resolve(); }, upgrade() {} };
globalThis.CSS = { supports: () => false, escape: (s) => String(s), registerProperty() {} };
globalThis.HTMLElement = globalThis.HTMLElement;   // keep extends-able
globalThis.navigator = { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15', language: 'en-US', languages: ['en-US', 'en'], onLine: true, clipboard: makeStub('clipboard') };
globalThis.location = { href: BASE_URL + 'popup.html', protocol: 'chrome-extension:', hostname: EXT_ID, host: EXT_ID, search: '', hash: '', pathname: '/popup.html', origin: 'chrome-extension://' + EXT_ID, assign() {}, replace() {}, reload() {} };
globalThis.devicePixelRatio = 2;
globalThis.innerWidth = 380; globalThis.innerHeight = 600;
globalThis.scrollX = 0; globalThis.scrollY = 0;
globalThis.requestAnimationFrame = (fn) => _setTimeout(() => fn(Date.now()), 16);
globalThis.cancelAnimationFrame = (id) => clearTimeout(id);
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.dispatchEvent = () => true;
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
globalThis.getComputedStyle = () => makeStub('computedStyle');
if (typeof globalThis.Promise.withResolvers !== 'function') {
    globalThis.Promise.withResolvers = function () { let resolve, reject; const promise = new Promise((res, rej) => { resolve = res; reject = rej; }); return { promise, resolve, reject }; };
}
// The native page bridge: brownbear-webext-page.js posts {api,payload,token} to this handler. Record
// the api calls; never resolve (matches a popup whose background hasn't replied yet — boot must not
// depend on a reply).
// On device this is a WKScriptMessageHandlerWithReply — its postMessage returns a PROMISE that
// settles when the background replies. Return a never-resolving promise: the page's bridge(...).then()
// chains stay pending (the boot doesn't depend on a reply) instead of crashing on undefined.then.
globalThis.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => { try { bridgeCalls.push(msg && msg.api); } catch {} return new Promise(() => {}); } } } };
// The identity the page shim reads at document-start.
globalThis.__bbExtPage = { token: 'harness-token', extensionId: EXT_ID, manifestJSON: manifestStr, baseURL: BASE_URL, messages, placeholders: {} };

// ---------------------------------------------------------------- load idle polyfill + page shim + bundler
const errors = [];
function recordError(phase, e) { errors.push({ phase, message: String((e && e.message) || e), stack: String((e && e.stack) || '').split('\n').slice(0, 3).join(' | ') }); }
process.on('unhandledRejection', () => {});   // page bridge calls never resolve here; ignore
function runClassicGlobal(file, label) { vm.runInThisContext(readFileSync(path.join(APP_JS_DIR, file), 'utf8'), { filename: label || file }); }

try { runClassicGlobal('brownbear-idle-callback.js', 'brownbear-idle-callback.js'); } catch (e) { recordError('idle-load', e); }
try { runClassicGlobal('brownbear-webext-page.js', 'brownbear-webext-page.js'); } catch (e) { recordError('page-shim-load', e); }
try {
    runClassicGlobal('brownbear-acorn.js', 'brownbear-acorn.js');
    runClassicGlobal('brownbear-esm-linker.js', 'brownbear-esm-linker.js');
    runClassicGlobal('brownbear-esm-page-bundler.js', 'brownbear-esm-page-bundler.js');
} catch (e) { recordError('bundler-load', e); }
globalThis.__bbModuleSource = function (p) { try { return readFileSync(path.join(EXT_DIR, p), 'utf8'); } catch { return null; } };
globalThis.__bbBgBaseURL = BASE_URL;

// ---------------------------------------------------------------- recording proxy over chrome/browser
const NOISE = new Set(['__esModule', 'then', 'toJSON', '$$typeof', 'constructor', 'prototype', 'nodeType', 'length', 'name', 'default']);
function isNoise(p) { return NOISE.has(p) || p.startsWith('@@') || p.startsWith('Symbol('); }
function wrapNs(nsName, o) {
    if (!o || (typeof o !== 'object' && typeof o !== 'function')) { return o; }
    return new Proxy(o, { get(t, prop) { if (typeof prop === 'symbol') { return t[prop]; } const v = t[prop]; if (v === undefined && !(prop in t) && !isNoise(String(prop))) { missing.add('chrome.' + nsName + '.' + String(prop)); } return v; } });
}
function wrapChrome(c) {
    if (!c) { return c; }
    return new Proxy(c, { get(t, prop) { if (typeof prop === 'symbol') { return t[prop]; } const v = t[prop]; if (v === undefined && !(prop in t)) { if (!isNoise(String(prop))) { missing.add('chrome.' + String(prop)); } return undefined; } if (v && typeof v === 'object') { return wrapNs(String(prop), v); } return v; } });
}
try { const w = wrapChrome(globalThis.chrome); globalThis.chrome = w; globalThis.browser = w; } catch {}

// ---------------------------------------------------------------- enumerate page parts
function parseHtmlScripts(html, htmlPath) {
    const modules = []; const classics = [];
    const re = /<script\b([^>]*)>/gi; let m;
    while ((m = re.exec(html)) !== null) {
        const attrs = m[1];
        const srcM = /\bsrc\s*=\s*["']([^"']+)["']/i.exec(attrs);
        if (!srcM) { continue; }
        if (/\btype\s*=\s*["']module["']/i.test(attrs)) { modules.push(srcM[1]); } else { classics.push(srcM[1]); }
    }
    return { modules, classics };
}

const parts = [];
function addPart(kind, htmlRel) {
    if (!htmlRel) { return; }
    const html = readExt(htmlRel);
    if (html == null) { parts.push({ kind, htmlRel, missingHtml: true }); return; }
    parts.push({ kind, htmlRel, ...parseHtmlScripts(html, htmlRel) });
}
const action = manifest.action || manifest.browser_action || manifest.page_action || {};
addPart('popup', action.default_popup);
addPart('options', (manifest.options_ui && manifest.options_ui.page) || manifest.options_page);
const over = manifest.chrome_url_overrides || {};
addPart('newtab', over.newtab); addPart('history', over.history); addPart('bookmarks', over.bookmarks);
addPart('devtools', manifest.devtools_page);
addPart('sidepanel', (manifest.side_panel && manifest.side_panel.default_path) || (manifest.sidebar_action && manifest.sidebar_action.default_panel));

// ---------------------------------------------------------------- run each page part
const pageResults = [];
for (const part of parts) {
    const r = { kind: part.kind, htmlRel: part.htmlRel, ok: true, errors: [] };
    if (part.missingHtml) { r.ok = false; r.errors.push('HTML not found: ' + part.htmlRel); pageResults.push(r); continue; }
    // Module graph → pre-link (blank-page guard). Per-entry link/run errors are reported by the bundle.
    if (part.modules && part.modules.length) {
        let code;
        try { code = globalThis.__bbBundlePage(JSON.stringify(part.modules), part.htmlRel, BASE_URL); }
        catch (e) { r.ok = false; r.errors.push('LINK FAIL (blank page): ' + String(e && e.message || e)); }
        if (code) {
            globalThis.__bbPageBundle = undefined;
            try { vm.runInThisContext(code, { filename: '__pagebundle_' + part.kind + '__.js' }); }
            catch (e) { r.ok = false; r.errors.push('bundle-run: ' + String(e && e.message || e)); }
            const rep = globalThis.__bbPageBundle;
            if (rep && rep.errors && rep.errors.length) { r.ok = false; for (const er of rep.errors) { r.errors.push('entry ' + er.entry + ': ' + er.message); } }
        }
    }
    // Classic page scripts run in order (DOM-heavy; permissive stub absorbs DOM, real throws surface).
    for (const s of (part.classics || [])) {
        const dir = path.dirname(part.htmlRel);
        const rel = s.startsWith('/') ? s.slice(1) : (dir && dir !== '.' ? path.join(dir, s) : s);
        if (/^[a-z]+:\/\//i.test(s)) { continue; }   // external script — can't load, would also need CSP on device
        const src = readExt(rel);
        if (src == null) { r.ok = false; r.errors.push('script not found: ' + rel); continue; }
        try { vm.runInThisContext(src, { filename: rel }); } catch (e) {
            r.ok = false; r.errors.push('classic ' + rel + ': ' + String(e && e.message || e));
            if (process.env.BB_STACK) { r.errors.push('   @ ' + String((e && e.stack) || '').split('\n').slice(1, 4).join(' | ')); }
        }
    }
    pageResults.push(r);
}

await new Promise((r) => _setTimeout(r, 250));

const verdict = {
    id: EXT_ID, name: (manifest.name || EXT_ID), mv, vendor,
    pageCount: parts.length,
    ok: errors.length === 0 && pageResults.every((p) => p.ok),
    loadErrors: errors,
    pages: pageResults,
    missing: Array.from(missing).sort(),
    bridgeApis: Array.from(new Set(bridgeCalls.filter(Boolean))).slice(0, 20),
};
process.stdout.write('BBVERDICT:' + JSON.stringify(verdict) + '\n', () => process.exit(0));
_setTimeout(() => process.exit(0), 500);
