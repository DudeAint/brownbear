//
//  war-script-csp-bridge.test.js
//  BrownBear
//
//  A content script commonly runs a page-world helper by appending <script src=chrome.runtime.getURL(
//  'x.js')>. On a strict-CSP site (YouTube, GitHub, X) the page's script-src lists no chrome-extension:
//  source, so WebKit refuses that subresource and the helper silently never runs ("the extension's
//  features don't work"). The content runtime bridges it: it intercepts insertion of an extension-origin
//  <script src>, fetches the resource over the CSP-immune content-world fetch, and runs it in the page
//  MAIN world via the native eval (page.injectMainWorld). This boots the REAL brownbear-webext-runtime.js
//  and asserts the divert (fetch + MAIN-world inject + src neutered + load event), and that NORMAL
//  appendChild (a non-extension script, a plain element) passes straight through untouched.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/war-script-csp-bridge.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const JSDIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const runtimeSrc = fs.readFileSync(path.join(JSDIR, "brownbear-webext-runtime.js"), "utf8");

const EXT_ID = "warbridgetestidaaaaaaaaaaaaaaaaa";
const BASE = `chrome-extension://${EXT_ID}/`;
const WAR_URL = BASE + "inpage.js";
const WAR_BODY = "window.__OLDYTP_RAN = true; /* the page-world helper */";

const warScriptCalls = [];   // urls handed to the native injectWarScript bridge (read + MAIN-world eval)

function bootContentWorld() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb; sb.window = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean,
        RegExp, Map, Set, Error, Function, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout;
    sb.location = { href: "https://www.youtube.com/", protocol: "https:", host: "www.youtube.com",
                    origin: "https://www.youtube.com" };
    sb.addEventListener = () => {}; sb.removeEventListener = () => {};

    // Node/Element constructors whose prototypes carry the REAL appendChild/insertBefore (Node) and
    // append/prepend (Element) the bridge wraps. Element inherits Node so an element has all four.
    function Node() {}
    function record(parent, node) { (parent.__children || (parent.__children = [])).push(node); }
    Node.prototype.appendChild = function (node) { record(this, node); return node; };
    Node.prototype.insertBefore = function (node) { record(this, node); return node; };
    function Element() {}
    Element.prototype = Object.create(Node.prototype);
    Element.prototype.append = function () { for (let i = 0; i < arguments.length; i++) { record(this, arguments[i]); } };
    Element.prototype.prepend = function () { for (let i = 0; i < arguments.length; i++) { record(this, arguments[i]); } };
    sb.Node = Node; sb.Element = Element;
    sb.Event = function (type) { this.type = type; };
    sb.AbortController = function () { this.signal = {}; this.abort = () => {}; };

    function makeElement(tag, connected) {
        const el = Object.create(Element.prototype);
        let _src = "";
        Object.defineProperties(el, {
            nodeType: { value: 1 }, tagName: { value: String(tag).toUpperCase() },
            src: { get() { return _src; }, set(v) { _src = String(v); }, configurable: true },
            __events: { value: [], writable: true },
            isConnected: { value: connected !== false, writable: true, configurable: true }
        });
        el.removeAttribute = (n) => { if (n === "src") { _src = ""; } };
        el.setAttribute = () => {}; el.dataset = {}; el.style = {}; el.textContent = "";
        el.remove = () => {}; el.dispatchEvent = (e) => { el.__events.push(e.type); return true; };
        return el;
    }
    const documentElement = makeElement("html");
    sb.document = {
        readyState: "interactive", documentElement, head: makeElement("head"), body: null,
        addEventListener: () => {}, removeEventListener: () => {},
        createElement: (t) => makeElement(t), querySelector: () => null
    };

    // Native bridge: capture injectWarScript (native reads the WAR file + evals it MAIN-world, both
    // CSP-immune) and report it found, as on device; inert otherwise. There is deliberately NO page fetch —
    // a content-world fetch of chrome-extension:// is CSP-gated on device ("Load failed" on YouTube).
    sb.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => {
        const api = msg.api, p = msg.payload || {};
        if (api === "getContentScripts") { return Promise.resolve([]); }   // no auto content scripts here
        if (api === "injectWarScript") { warScriptCalls.push(p.url); return Promise.resolve({ found: true }); }
        return Promise.resolve(null);
    } } } };

    vm.createContext(sb);
    vm.runInContext(runtimeSrc, sb, { filename: "brownbear-webext-runtime.js" });
    return sb;
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    let passed = 0, failed = 0;
    const ok = (n) => { console.log("  ok   " + n); passed++; };
    const bad = (n, e) => { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; };

    const world = bootContentWorld();

    // 1) An extension-origin <script src> is diverted: native reads + runs it MAIN-world, src neutered, inserted.
    try {
        vm.runInContext(
            "var s = document.createElement('script'); s.src = '" + WAR_URL + "';" +
            "document.documentElement.appendChild(s); window.__s = s;", world, { filename: "content-script" });
        await delay(20);   // let the bridge promise chain settle
        assert.ok(warScriptCalls.includes(WAR_URL),
            "the WAR resource is read + run NATIVELY (injectWarScript) — not fetched in the CSP-gated page");
        assert.strictEqual(world.__s.src, "", "the script's src is neutered so the page makes no CSP-blocked load");
        assert.ok((world.document.documentElement.__children || []).includes(world.__s),
            "the (now inert) script element is still inserted so the page DOM is unchanged");
        assert.ok(world.__s.__events.includes("load"), "a load event fires so code awaiting script.onload proceeds");
        ok("extension-origin <script src> is diverted to a native CSP-immune MAIN-world injection");
    } catch (e) { bad("divert ext script", e); }

    // 2) A NORMAL (non-extension) <script src> passes straight through — never bridged, src untouched, inserted.
    try {
        const warsBefore = warScriptCalls.length;
        vm.runInContext(
            "var n = document.createElement('script'); n.src = 'https://www.youtube.com/normal.js';" +
            "document.documentElement.appendChild(n); window.__n = n;", world, { filename: "content-script" });
        await delay(10);
        assert.strictEqual(warScriptCalls.length, warsBefore, "a normal page script is NOT bridged");
        assert.strictEqual(world.__n.src, "https://www.youtube.com/normal.js", "a normal script's src is left untouched");
        assert.ok((world.document.documentElement.__children || []).includes(world.__n), "a normal script is inserted normally");
        ok("a normal (non-extension) <script src> passes through untouched");
    } catch (e) { bad("passthrough normal script", e); }

    // 3) A non-script element passes straight through (appendChild not diverted).
    try {
        const warsBefore = warScriptCalls.length;
        vm.runInContext(
            "var d = document.createElement('div'); document.documentElement.appendChild(d); window.__d = d;",
            world, { filename: "content-script" });
        await delay(5);
        assert.strictEqual(warScriptCalls.length, warsBefore, "appending a non-script element triggers no bridge call");
        assert.ok((world.document.documentElement.__children || []).includes(world.__d), "the element is inserted normally");
        ok("a non-script element passes through appendChild untouched");
    } catch (e) { bad("passthrough non-script", e); }

    // 4) An ext-script staged on a DISCONNECTED parent is NOT diverted (a real browser runs it on
    //    connection, not at stage time) — no premature read/execution.
    try {
        const warsBefore = warScriptCalls.length;
        world.__detached = world.document.createElement("div");
        Object.defineProperty(world.__detached, "isConnected", { value: false, configurable: true });
        vm.runInContext(
            "var sd = document.createElement('script'); sd.src = '" + WAR_URL + "';" +
            "window.__detached.appendChild(sd); window.__sd = sd;", world, { filename: "content-script" });
        await delay(10);
        assert.strictEqual(warScriptCalls.length, warsBefore, "an ext-script on a disconnected parent is NOT bridged");
        assert.strictEqual(world.__sd.src, WAR_URL, "its src is left intact (not yet diverted)");
        ok("an ext-script staged on a disconnected node is not diverted (no premature execution)");
    } catch (e) { bad("disconnected parent gate", e); }

    // 5) The modern variadic insert verb Element.prototype.append is also bridged.
    try {
        const warsBefore = warScriptCalls.length;
        vm.runInContext(
            "var sa = document.createElement('script'); sa.src = '" + WAR_URL + "';" +
            "document.documentElement.append(sa); window.__sa = sa;", world, { filename: "content-script" });
        await delay(20);
        assert.ok(warScriptCalls.length > warsBefore, "append(script) also diverts to a native MAIN-world injection");
        assert.strictEqual(world.__sa.src, "", "append(script) neuters the src too");
        ok("Element.prototype.append(<ext script>) is bridged");
    } catch (e) { bad("append coverage", e); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
