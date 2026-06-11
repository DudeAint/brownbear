//
//  sw-client-messaging.test.js
//  BrownBear
//
//  Service-worker CLIENT messaging bridge. Some popups talk to their MV3 worker ENTIRELY over
//  navigator.serviceWorker — Stylus's createPortExec posts `controller.postMessage(data, [MessagePort])`
//  and RPCs over the transferred MessageChannel; the worker receives it via self.onmessage and replies
//  on event.ports[0]. WKWebView exposes no Service Worker for the custom scheme, so the page shim
//  presents a WORKING controller/ready that tunnels the channel through a chrome.runtime port (the
//  popup↔worker port hub) to the worker, where dispatchPortConnect("__bb_swclient") turns it back into
//  a 'message' event with a MessagePort.
//
//  Regression: with an inert controller (null) + a never-resolving `ready`, createPortExec awaited
//  forever and every invokeAPI hung → Stylus's popup rendered blank. This boots the REAL page + bg
//  shims in two contexts, wires a minimal port hub between them, and asserts the full popup→worker→
//  popup round-trip (the init message + an RPC reply over the channel).
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/sw-client-messaging.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const appJS = (f) => fs.readFileSync(path.join(DIR, f), "utf8");
const EXT_ID = "swclienttestidaaaaaaaaaaaaaaaaaa";
const BASE = `chrome-extension://${EXT_ID}/`;

// The popup↔worker port hub — the only native piece this path uses.
let workerBg = null, pageExt = null;
function popupConnect(name) {
    const portId = "p" + Math.random().toString(36).slice(2);
    setTimeout(() => { try { workerBg.dispatchPortConnect(portId, JSON.stringify(name || ""), JSON.stringify({ id: EXT_ID, url: BASE + "popup.html" })); } catch (e) { /* noop */ } }, 0);
    return portId;
}

function baseGlobals(sb) {
    sb.globalThis = sb; sb.self = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp, Map, Set, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
}

function bootWorker() {
    const sb = {}; baseGlobals(sb);
    const cb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { try { c(JSON.stringify(null)); } catch (e) { /* noop */ } } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set", "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr", "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_alarm_create", "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all", "__bb_fetch"]) { sb[n] = cb; }
    sb.__bb_set_timeout = (fn, ms, r) => r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0); sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bb_port_post = (portId, msgJSON) => { let m; try { m = JSON.parse(msgJSON); } catch { m = null; } setTimeout(() => { try { pageExt.onPortMessage(portId, m); } catch (e) { /* noop */ } }, 0); };
    sb.__bb_port_disconnect = (portId) => { setTimeout(() => { try { pageExt.onPortDisconnect(portId); } catch (e) { /* noop */ } }, 0); };
    sb.__bbBgExtId = EXT_ID; sb.__bbBgBaseURL = BASE; sb.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1", background: { service_worker: "sw.js" } }); sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(appJS("brownbear-webext-background.js"), sb, { filename: "brownbear-webext-background.js" });
    workerBg = sb.__bbBg;
    // A worker that handles SW-client messages like Stylus's initRemotePort: greet, then echo RPCs.
    sb.onmessage = (e) => { const port = e.ports[0]; port.onmessage = (ev) => { port.postMessage({ echo: ev.data, viaPort: true }); }; port.postMessage({ hello: "from-worker", initData: e.data }); };
    return sb;
}

function bootPopup() {
    const sb = {}; baseGlobals(sb); sb.window = sb;
    sb.navigator = { userAgent: "UA", language: "en" };
    sb.location = { href: BASE + "popup.html", protocol: "chrome-extension:", host: EXT_ID, origin: BASE.slice(0, -1) };
    sb.addEventListener = () => {}; sb.removeEventListener = () => {};
    sb.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => {
        const api = msg.api, p = msg.payload || {};
        if (api === "port.connect") { return Promise.resolve({ portId: popupConnect(p.name) }); }
        if (api === "port.postMessage") { setTimeout(() => { try { workerBg.dispatchPortMessage(p.portId, JSON.stringify(p.message == null ? null : p.message)); } catch (e) { /* noop */ } }, 0); return Promise.resolve(undefined); }
        if (api === "port.disconnect") { setTimeout(() => { try { workerBg.dispatchPortDisconnect(p.portId); } catch (e) { /* noop */ } }, 0); return Promise.resolve(undefined); }
        return new Promise(() => {});
    } } } };
    sb.__bbExtPage = { token: "t", extensionId: EXT_ID, manifestJSON: "{}", baseURL: BASE, messages: {}, placeholders: {} };
    sb.MessageChannel = function MessageChannel() {
        function mk() {
            const port = { _peer: null, _started: false, _q: [], _ls: [], _on: null,
                postMessage(x) { const peer = this._peer; setTimeout(() => { const ev = { data: x }; if (peer._started) { peer._d(ev); } else { peer._q.push(ev); } }, 0); },
                start() { if (this._started) { return; } this._started = true; const q = this._q; this._q = []; for (const ev of q) { this._d(ev); } },
                close() {}, addEventListener(t, f) { if (t === "message") { this._ls.push(f); this.start(); } }, removeEventListener() {},
                _d(ev) { if (typeof this._on === "function") { try { this._on(ev); } catch (e) { /* noop */ } } for (const l of this._ls.slice()) { try { l(ev); } catch (e) { /* noop */ } } } };
            Object.defineProperty(port, "onmessage", { get() { return this._on; }, set(fn) { this._on = fn; if (typeof fn === "function") { this.start(); } } });
            return port;
        }
        const a = mk(), b = mk(); a._peer = b; b._peer = a; this.port1 = a; this.port2 = b;
    };
    vm.createContext(sb);
    vm.runInContext(appJS("brownbear-webext-page.js"), sb, { filename: "brownbear-webext-page.js" });
    pageExt = sb.__brownbearExtPage;
    return sb;
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    let passed = 0, failed = 0;
    const worker = bootWorker();
    const popup = bootPopup();
    await delay(40);

    const sw = popup.navigator.serviceWorker;
    try {
        assert.ok(sw && sw.controller && typeof sw.controller.postMessage === "function", "page shim must present a working navigator.serviceWorker.controller");
        assert.ok(sw.ready && typeof sw.ready.then === "function", "navigator.serviceWorker.ready must resolve (not hang)");
        const reg = await sw.ready; assert.ok(reg && reg.active, "ready resolves to a registration with an active worker");
        passed++; console.log("  ok   controller + resolving ready present (createPortExec can connect)");
    } catch (e) { failed++; console.log("  FAIL controller/ready\n       " + e.message); }

    // Exactly Stylus's createPortExec: post to the controller with a transferred port, RPC over it.
    let workerHello = null, rpcReply = null;
    const mc = new popup.MessageChannel();
    mc.port1.onmessage = (e) => { if (e.data && e.data.hello) { workerHello = e.data; } else { rpcReply = e.data; } };
    popup.navigator.serviceWorker.controller.postMessage({ lock: "swPath" }, [mc.port2]);
    await delay(60);
    mc.port1.postMessage({ args: ["styles.getSectionsByUrl", "http://example.com"], id: 7 });
    await delay(150);

    try {
        assert.ok(workerHello && workerHello.hello === "from-worker", "worker's self.onmessage must fire and reach the popup over the port");
        assert.deepStrictEqual(workerHello.initData, { lock: "swPath" }, "the controller.postMessage payload reaches the worker as event.data");
        passed++; console.log("  ok   controller.postMessage([port]) → worker self.onmessage (init + port both delivered)");
    } catch (e) { failed++; console.log("  FAIL worker receipt\n       " + e.message); }

    try {
        assert.ok(rpcReply && rpcReply.viaPort === true, "an RPC over the popup's port reaches the worker and is answered over the same channel");
        assert.strictEqual(rpcReply.echo.id, 7, "the worker's reply round-trips back to the popup's port1");
        passed++; console.log("  ok   bidirectional RPC round-trips over the bridged MessageChannel");
    } catch (e) { failed++; console.log("  FAIL rpc round-trip\n       " + e.message); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
