//
//  content-message-dead-frame.test.js
//  BrownBear
//
//  Guards the contract that lets native short-circuit a doomed chrome.tabs.sendMessage push instead of
//  stranding the caller for the full 30s timeout. When the worker broadcasts to a tab, the native router
//  (WebExtensionMessageRouter.pushMessage) evaluates a tiny wrapper into EACH content frame:
//
//      (function(){var h=window.__bbExtContent&&window.__bbExtContent['<token>'];
//       if(!h||typeof h.onMessage!=='function'){return 0;}
//       h.onMessage(<msg>,<sender>,'<responseId>');return 1;})()
//
//  `1` means a live onMessage handler ran — a sendResponse (sync or async) WILL come back over the bridge,
//  so native waits. `0` (or an eval error) means the content world is gone — a removed/stale iframe whose
//  session lingers, or a token that never registered — so NOTHING will answer and native resolves the push
//  immediately. Regression: a single dead frame used to serial-block a whole broadcast (e.g. Stylus fires
//  `urlChanged` to every frame on each in-page navigation) for 30s, tripping the worker boot-stall watchdog.
//
//  This boots the REAL brownbear-webext-runtime.js, injects a content script through the getContentScripts
//  bridge (so window.__bbExtContent[token] is registered exactly as on device), then runs the SAME wrapper
//  string the native side builds and asserts: registered token -> 1 (+ a sendResponse arrives over the
//  bridge), unregistered token -> 0 (no side effects). If the registry shape changes, native's 0/1 sentinel
//  silently breaks and reintroduces the stall — this test fails first.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/content-message-dead-frame.test.js`. Exits non-zero on failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const JSDIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const runtimeSrc = fs.readFileSync(path.join(JSDIR, "brownbear-webext-runtime.js"), "utf8");

const EXT_ID = "deadframetestidaaaaaaaaaaaaaaaaa";
const BASE = `chrome-extension://${EXT_ID}/`;
const TOKEN = "tkn-live-1";

// The content script we inject — a faithful miniature of Stylus's apply.js onMessage discipline:
// `urlChanged` returns undefined (the runtime auto-responds), `ping` answers synchronously with a value.
const CONTENT_JS = [
    "chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {",
    "  var m = msg && msg.data && msg.data.method;",
    "  if (m === 'ping') { sendResponse({ pong: true }); return; }",
    "  /* urlChanged + everything else: return undefined → runtime sends the default response */",
    "});"
].join("\n");

// Captured sendResponses (the bridge's runtime.messageResponse calls), keyed by responseId.
const responses = {};

function bootContentWorld() {
    const sb = {};
    sb.globalThis = sb; sb.self = sb; sb.window = sb;
    sb.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp, Map, Set, Error, Function, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    sb.location = { href: "https://example.com/page", protocol: "https:", host: "example.com", origin: "https://example.com" };
    sb.addEventListener = () => {}; sb.removeEventListener = () => {};
    // Minimal DOM — document_start ISOLATED scripts need readyState + (for css, unused here) createElement.
    sb.document = {
        readyState: "interactive",
        addEventListener: () => {}, removeEventListener: () => {},
        documentElement: { appendChild() {} }, head: { appendChild() {} }, body: null,
        createElement: () => ({ textContent: "", setAttribute() {}, style: {}, appendChild() {}, get parentNode() { return null; } }),
        querySelector: () => null
    };
    // The native bridge. getContentScripts hands back our one ISOLATED content script; runtime.messageResponse
    // records the content script's answer (this is what resolves the native push on device).
    sb.webkit = { messageHandlers: { brownbearWebext: { postMessage: (msg) => {
        const api = msg.api, p = msg.payload || {};
        if (api === "getContentScripts") {
            return Promise.resolve([{
                token: TOKEN, extensionId: EXT_ID, baseURL: BASE, manifestJSON: "{}",
                messages: {}, world: "ISOLATED", runAt: "document_start", js: CONTENT_JS
            }]);
        }
        if (api === "runtime.messageResponse") { responses[p.responseId] = p.value; return Promise.resolve(undefined); }
        return Promise.resolve(null);   // storage / pageLog / everything else: inert
    } } } };
    vm.createContext(sb);
    vm.runInContext(runtimeSrc, sb, { filename: "brownbear-webext-runtime.js" });
    return sb;
}

// The EXACT wrapper the native router builds (WebExtensionMessageRouter.pushMessage). Kept in sync by hand —
// if these diverge, native's early-resolve sentinel is wrong and the 30s stall returns.
function nativeWrapper(token, messageJSON, senderJSON, responseId) {
    return "(function(){var h=window.__bbExtContent&&window.__bbExtContent['" + token + "'];"
        + "if(!h||typeof h.onMessage!=='function'){return 0;}"
        + "h.onMessage(" + messageJSON + "," + senderJSON + ",'" + responseId + "');return 1;})()";
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    let passed = 0, failed = 0;
    const ok = (name) => { console.log("  ok   " + name); passed++; };
    const bad = (name, e) => { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; };

    const world = bootContentWorld();
    await delay(30);   // let loadAndRun's getContentScripts promise resolve and inject the content script

    try {
        assert.ok(world.__bbExtContent && typeof world.__bbExtContent[TOKEN] === "object",
            "the injected content script must register window.__bbExtContent[token]");
        assert.strictEqual(typeof world.__bbExtContent[TOKEN].onMessage, "function",
            "the registry entry must expose onMessage (native's typeof check gates the 1/0 sentinel)");
        ok("content script registered __bbExtContent[token].onMessage");
    } catch (e) { bad("registry shape", e); }

    // 1) Registered token, urlChanged (handler returns undefined) → wrapper returns 1, default response arrives.
    try {
        const msg = JSON.stringify({ data: { method: "urlChanged", top: true, iid: 0, url: "https://example.com/x#y" } });
        const sender = JSON.stringify({ id: EXT_ID, origin: BASE.slice(0, -1) });
        const r = vm.runInContext(nativeWrapper(TOKEN, msg, sender, "r-url"), world, { filename: "native-push" });
        assert.strictEqual(r, 1, "a live handler must make the wrapper return 1 (native waits for the response)");
        await delay(10);
        assert.ok("r-url" in responses, "the runtime must auto-send a response for an unhandled urlChanged (no 30s strand)");
        assert.strictEqual(responses["r-url"], null, "the default response value is null (undefined → null over the bridge)");
        ok("live frame + urlChanged → wrapper 1 and a default sendResponse arrives");
    } catch (e) { bad("urlChanged live path", e); }

    // 2) Registered token, ping (handler answers synchronously) → wrapper returns 1, real value round-trips.
    try {
        const msg = JSON.stringify({ data: { method: "ping" } });
        const r = vm.runInContext(nativeWrapper(TOKEN, msg, JSON.stringify({ id: EXT_ID }), "r-ping"), world, { filename: "native-push" });
        assert.strictEqual(r, 1, "ping handler ran → wrapper returns 1");
        await delay(10);
        assert.deepStrictEqual(responses["r-ping"], { pong: true }, "a synchronous sendResponse value must round-trip (never clobbered by an early-resolve)");
        ok("live frame + sync sendResponse → wrapper 1 and the real value round-trips");
    } catch (e) { bad("ping sync path", e); }

    // 3) Unregistered token (the dead/stale-frame signature) → wrapper returns 0, native resolves immediately.
    try {
        const before = Object.keys(responses).length;
        const r = vm.runInContext(nativeWrapper("tkn-does-not-exist", JSON.stringify({ data: { method: "urlChanged" } }), "{}", "r-dead"), world, { filename: "native-push" });
        assert.strictEqual(r, 0, "an unregistered token must make the wrapper return 0 so native early-resolves instead of waiting 30s");
        await delay(10);
        assert.strictEqual(Object.keys(responses).length, before, "a 0-token push must produce no onMessage side effects");
        assert.ok(!("r-dead" in responses), "no response is sent for a dead frame (native supplies nil itself)");
        ok("dead frame (unregistered token) → wrapper 0, no response, native early-resolves");
    } catch (e) { bad("dead-frame path", e); }

    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
})();
