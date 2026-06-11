//
//  offscreen-client-messaging.test.js
//  BrownBear
//
//  Service-worker → CLIENT messaging for OFFSCREEN documents — the reverse of sw-client-messaging.test.js.
//  An MV3 worker reaches its offscreen document via `self.clients.matchAll()` + `client.postMessage(data,
//  [port])`; the document receives it on `navigator.serviceWorker.onmessage` with the transferred port as
//  `event.ports[0]`. WKWebView exposes no real SW and the headless worker can't open a port toward a page,
//  so the offscreen page opens a "__bb_swclient_host" chrome.runtime port and the worker pushes back over
//  it. Stylus runs its WHOLE offscreen pipeline this way: usercss parsing in a NESTED Web Worker whose
//  port it transfers BACK to the SW (so the SW talks to worker.js directly), blob URLs, prefers-color-
//  scheme. Without it `self.clients.matchAll()` is empty, findOffscreenClient never resolves, and usercss
//  build/install hang.
//
//  This boots the REAL bg + page shims in two contexts, wires the port hub between them, and asserts:
//   (1) clients.matchAll() returns the offscreen client (right url);
//   (2) client.postMessage([port]) reaches the document's navigator.serviceWorker.onmessage with the port;
//   (3) a simple RPC round-trips over that channel;
//   (4) the NESTED transfer works: the document hands a SECOND MessagePort back to the SW over the channel,
//       and the SW RPCs over that nested port (the worker.js path) and gets its echo.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/offscreen-client-messaging.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const appJS = (f) => fs.readFileSync(path.join(DIR, f), "utf8");
const EXT_ID = "offscreentestidaaaaaaaaaaaaaaaaa";
const BASE = `chrome-extension://${EXT_ID}/`;
const OFFSCREEN_URL = BASE + "offscreen.html";

// The port hub (offscreen page ↔ worker) — the only native piece this path uses.
let workerBg = null, pageExt = null;
function pageConnect(name) {
    const portId = "p" + Math.random().toString(36).slice(2);
    setTimeout(() => {
        try { workerBg.dispatchPortConnect(portId, JSON.stringify(name || ""), JSON.stringify({ id: EXT_ID, url: OFFSCREEN_URL })); }
        catch (e) { /* noop */ }
    }, 0);
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
    return sb;
}

function bootOffscreen() {
    const sb = {}; baseGlobals(sb); sb.window = sb;
    sb.navigator = { userAgent: "UA", language: "en" };
    sb.location = { href: OFFSCREEN_URL, protocol: "chrome-extension:", host: EXT_ID, origin: BASE.slice(0, -1) };
    sb.addEventListener = () => {}; sb.removeEventListener = () => {};
    sb.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => {
        const api = msg.api, p = msg.payload || {};
        if (api === "port.connect") { return Promise.resolve({ portId: pageConnect(p.name) }); }
        if (api === "port.postMessage") { setTimeout(() => { try { workerBg.dispatchPortMessage(p.portId, JSON.stringify(p.message == null ? null : p.message)); } catch (e) { /* noop */ } }, 0); return Promise.resolve(undefined); }
        if (api === "port.disconnect") { setTimeout(() => { try { workerBg.dispatchPortDisconnect(p.portId); } catch (e) { /* noop */ } }, 0); return Promise.resolve(undefined); }
        return new Promise(() => {});
    } } } };
    sb.__bbExtPage = { token: "t", extensionId: EXT_ID, manifestJSON: "{}", baseURL: BASE, messages: {}, placeholders: {}, kind: "offscreen" };
    // A DOM-faithful MessageChannel for the offscreen context (its real WKWebView has a native one). Used
    // to model the nested Web Worker port the document transfers back to the SW.
    sb.MessageChannel = function MessageChannel() {
        function mk() {
            const port = { _peer: null, _started: false, _q: [], _ls: [], _on: null,
                postMessage(x, transfer) { const peer = this._peer; setTimeout(() => { const ev = { data: x, ports: transfer || [] }; if (peer._started) { peer._d(ev); } else { peer._q.push(ev); } }, 0); },
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
    const offscreen = bootOffscreen();

    // The offscreen document's receiver — a faithful miniature of Stylus's offscreen.js onmessage: greet
    // over the transferred port, echo RPCs, and on a 'getWorkerPort' request hand a SECOND port back
    // (the nested Web Worker channel) and echo over it.
    offscreen.navigator.serviceWorker.onmessage = function (e) {
        const port = e.ports[0];
        if (!port) { return; }
        port.onmessage = function (ev) {
            const msg = ev.data;
            if (msg && msg.cmd === "getWorkerPort") {
                const mc = new offscreen.MessageChannel();
                mc.port2.onmessage = function (we) { mc.port2.postMessage({ workerEcho: we.data }); };
                port.postMessage({ portReply: true }, [mc.port1]);   // transfer the nested port to the SW
            } else {
                port.postMessage({ echo: msg });
            }
        };
        port.postMessage({ hello: "offscreen", init: e.data });
    };

    await delay(60);   // let the offscreen page register its __bb_swclient_host port

    // (1) clients.matchAll returns the offscreen client.
    let client = null;
    try {
        const clients = await worker.clients.matchAll({ type: "window" });
        assert.ok(Array.isArray(clients) && clients.length === 1, "clients.matchAll must return the one offscreen client");
        assert.strictEqual(clients[0].url, OFFSCREEN_URL, "the client must carry the offscreen document's url (findOffscreenClient matches on it)");
        assert.strictEqual(typeof clients[0].postMessage, "function", "the WindowClient must expose postMessage");
        client = clients[0];
        passed++; console.log("  ok   clients.matchAll() returns the offscreen WindowClient (right url)");
    } catch (e) { failed++; console.log("  FAIL clients.matchAll\n       " + e.message); }

    if (!client) { console.log(`\n${passed} passed, ${failed} failed`); process.exit(1); }

    // (2)+(3) client.postMessage([port]) reaches the document; RPC round-trips.
    let hello = null, rpc = null, nested = null, nestedEcho = null;
    const mc = new worker.MessageChannel();
    let nestedPort = null;
    mc.port1.onmessage = function (e) {
        const d = e.data;
        if (d && d.hello) { hello = d; }
        else if (d && d.portReply) { nested = d; nestedPort = e.ports && e.ports[0]; }
        else if (d && d.workerEcho !== undefined) { nestedEcho = d; }
        else { rpc = d; }
    };
    client.postMessage({ from: "sw" }, [mc.port2]);
    await delay(60);
    mc.port1.postMessage({ cmd: "ping", n: 5 });
    await delay(80);

    try {
        assert.ok(hello && hello.hello === "offscreen", "the document's navigator.serviceWorker.onmessage must fire and reach the SW over the port");
        assert.deepStrictEqual(hello.init, { from: "sw" }, "the client.postMessage payload reaches the document as event.data");
        passed++; console.log("  ok   client.postMessage([port]) → document onmessage (init + port delivered)");
    } catch (e) { failed++; console.log("  FAIL document receipt\n       " + e.message); }

    try {
        assert.ok(rpc && rpc.echo, "an RPC over the SW's port reaches the document and is answered over the same channel");
        assert.deepStrictEqual(rpc.echo, { cmd: "ping", n: 5 }, "the document's reply round-trips back to the SW's port1");
        passed++; console.log("  ok   bidirectional RPC round-trips over the bridged channel");
    } catch (e) { failed++; console.log("  FAIL rpc round-trip\n       " + e.message); }

    // (4) NESTED transfer: ask for a worker port; the document transfers a second port back; RPC over it.
    mc.port1.postMessage({ cmd: "getWorkerPort" });
    await delay(80);
    try {
        assert.ok(nested && nested.portReply === true, "getWorkerPort reply must arrive");
        assert.ok(nestedPort && typeof nestedPort.postMessage === "function", "the document's transferred (nested) port must arrive as event.ports[0] on the SW side");
        nestedPort.onmessage = function (e) { if (e.data && e.data.workerEcho !== undefined) { nestedEcho = e.data; } };
        nestedPort.postMessage({ parse: "usercss" });
        await delay(80);
        assert.ok(nestedEcho && nestedEcho.workerEcho, "the SW must RPC over the NESTED transferred port (the worker.js path) and get its echo");
        assert.deepStrictEqual(nestedEcho.workerEcho, { parse: "usercss" }, "the nested port echoes the SW's message (port transfer is recursive)");
        passed++; console.log("  ok   nested MessagePort transfer: SW ↔ document's worker.js port round-trips");
    } catch (e) { failed++; console.log("  FAIL nested transfer\n       " + e.message); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
