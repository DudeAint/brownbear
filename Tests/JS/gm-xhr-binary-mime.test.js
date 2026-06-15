//
//  gm-xhr-binary-mime.test.js
//  BrownBear
//
//  GM_xmlhttpRequest at Tampermonkey/Violentmonkey parity for two long-tail features (brownbear-runtime.js):
//    1. BINARY REQUEST BODY — an ArrayBuffer / typed array / DataView `data` must cross the bridge byte-
//       exact (base64 + a `dataIsBase64` flag), NOT coerced to the lossy string "[object ArrayBuffer]".
//    2. overrideMimeType — passed through to native so it can force byte-preserving response decoding
//       (the `text/plain; charset=x-user-defined` binary-string trick) and tag a Blob response's `type`.
//  Both the ISOLATED-world serializer (serializeXHRDetails) and the PAGE-world one (xhrSerialize) are
//  covered, plus the response builder using `contentType` for a Blob's type.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/gm-xhr-binary-mime.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-runtime.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

function b64(bytes) { return Buffer.from(bytes).toString("base64"); }
function nodeBtoa(s) { return Buffer.from(s, "latin1").toString("base64"); }
function nodeAtob(s) { return Buffer.from(s, "base64").toString("latin1"); }

// A minimal Blob shim that records the parts + the `type` from its options (so we can assert a Blob
// response carries the overrideMimeType/Content-Type).
function BlobShim(parts, opts) { this.parts = parts; this.type = (opts && opts.type) || ""; }

// Boot the ISOLATED runtime running `source` (a script granting GM_xmlhttpRequest, @inject-into content
// so it stays isolated). Returns the recorded native bridge messages + the page window (for __brownbear).
function bootIsolated(source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-xhr", name: "xhrtest", uuid: "55555555-5555-5555-5555-555555555555",
                runAt: "document-start", grants: ["GM_xmlhttpRequest"], grantNone: false, noFrames: false,
                injectInto: "content", requires: [], resources: {}, source: source, values: {},
                info: { scriptHandler: "BrownBear" }
            }]);
        }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        return Promise.resolve(null);
    }
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, console, CustomEvent: function () {},
        atob: nodeAtob, btoa: nodeBtoa
    };
    win.window = win; win.self = win; win.top = win;
    const document = { readyState: "complete", addEventListener() {} };
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined, Blob: BlobShim };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(SRC, ctx);
    return { calls, win };
}

// Boot a GRANTED script (injectInto auto, GM_xmlhttpRequest only ⇒ page world) and run its injected
// page-world source in a page context whose vault (__bbPageGM) records every posted request.
function bootPageWorld(source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-pw-xhr", name: "pwxhr", uuid: "66666666-6666-6666-6666-666666666666",
                runAt: "document-start", grants: ["GM_xmlhttpRequest"], grantNone: false, noFrames: false,
                injectInto: "auto", requires: [], resources: {}, source: source, values: {},
                info: { scriptHandler: "BrownBear" }
            }]);
        }
        if (msg.api === "fetchResource") { return Promise.resolve({ text: "" }); }
        return Promise.resolve(null);
    }
    const win = {
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, console, CustomEvent: function () {}
    };
    win.window = win; win.self = win; win.top = win;
    const document = { readyState: "complete", addEventListener() {} };
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(SRC, ctx);
    return calls;
}

function runPageWorldXHR(code) {
    const writes = [];
    function bbPageGM(token, api, payload) { writes.push({ token, api, payload }); }
    bbPageGM.xhr = function () { return "pw-rid-1"; };
    bbPageGM.xhrDone = function () {};
    const pageDoc = {
        head: { appendChild(n) { return n; } }, documentElement: { appendChild(n) { return n; } },
        createElement(tag) { return { tagName: tag, setAttribute() {}, appendChild() {} }; }
    };
    const pageWin = {
        document: pageDoc, JSON, Object, Array, Promise, console, __bbPageGM: bbPageGM,
        btoa: nodeBtoa, atob: nodeAtob
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageDoc, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    // Expose the page realm's own typed-array ctors on window (as a real browser does) so the client's
    // `data instanceof W.ArrayBuffer` matches the body the script built in this same realm.
    pageWin.ArrayBuffer = vm.runInContext("ArrayBuffer", ctx);
    pageWin.Uint8Array = vm.runInContext("Uint8Array", ctx);
    vm.runInContext(code, ctx);
    return writes;
}

(async function main() {
    console.log("GM_xmlhttpRequest: binary request body (base64) + overrideMimeType");

    // ---- Isolated world: request serialization -------------------------------------------------
    {
        const src = "GM_xmlhttpRequest({ method: 'POST', url: 'https://google.com/u', "
            + "data: new Uint8Array([1,2,3]).buffer, overrideMimeType: 'text/plain; charset=x-user-defined' });";
        const { calls } = bootIsolated(src);
        await new Promise((r) => setTimeout(r, 10));
        const xhr = calls.filter((c) => c.api === "GM_xmlhttpRequest")[0];
        test("isolated: a binary ArrayBuffer body is sent base64 (NOT '[object ArrayBuffer]')", () => {
            assert.ok(xhr, "a GM_xmlhttpRequest was posted");
            assert.strictEqual(xhr.payload.request.dataIsBase64, true, "flagged base64");
            assert.strictEqual(xhr.payload.request.data, b64([1, 2, 3]), "exact bytes preserved");
        });
        test("isolated: overrideMimeType is passed through to native", () => {
            assert.strictEqual(xhr.payload.request.overrideMimeType, "text/plain; charset=x-user-defined");
        });
    }

    // ---- Isolated world: a typed-array (Uint8Array, not its .buffer) body -----------------------
    {
        const src = "GM_xmlhttpRequest({ method: 'PUT', url: 'https://google.com/u', data: new Uint8Array([255,0,128]) });";
        const { calls } = bootIsolated(src);
        await new Promise((r) => setTimeout(r, 10));
        const xhr = calls.filter((c) => c.api === "GM_xmlhttpRequest")[0];
        test("isolated: a typed-array body is sent base64 of its own bytes", () => {
            assert.strictEqual(xhr.payload.request.dataIsBase64, true);
            assert.strictEqual(xhr.payload.request.data, b64([255, 0, 128]));
        });
    }

    // ---- Isolated world: a STRING body is unchanged (no false base64) ---------------------------
    {
        const src = "GM_xmlhttpRequest({ method: 'POST', url: 'https://google.com/u', data: 'hello=1' });";
        const { calls } = bootIsolated(src);
        await new Promise((r) => setTimeout(r, 10));
        const xhr = calls.filter((c) => c.api === "GM_xmlhttpRequest")[0];
        test("isolated: a string body stays a plain string (dataIsBase64 not set)", () => {
            assert.strictEqual(xhr.payload.request.data, "hello=1");
            assert.ok(!xhr.payload.request.dataIsBase64, "string body is not flagged base64");
        });
    }

    // ---- Isolated world: a Blob response uses contentType for its type --------------------------
    {
        const src = "GM_xmlhttpRequest({ method: 'GET', url: 'https://google.com/i.png', responseType: 'blob', "
            + "overrideMimeType: 'image/png', onload: function (r) { window.__resp = r; } });";
        const { calls, win } = bootIsolated(src);
        await new Promise((r) => setTimeout(r, 10));
        const xhr = calls.filter((c) => c.api === "GM_xmlhttpRequest")[0];
        const rid = xhr.payload.requestId;
        win.__brownbear.dispatchXHR(rid, "load", {
            isBase64: true, response: b64([137, 80, 78, 71]), status: 200, responseText: "",
            contentType: "image/png", readyState: 4
        });
        test("isolated: a blob response carries the contentType as its Blob type", () => {
            assert.ok(win.__resp && win.__resp.response, "onload delivered a response");
            assert.strictEqual(win.__resp.response.type, "image/png");
        });
    }

    // ---- Isolated world: byte-preserving responseText passes through untouched ------------------
    {
        const src = "GM_xmlhttpRequest({ method: 'GET', url: 'https://google.com/b', "
            + "overrideMimeType: 'text/plain; charset=x-user-defined', onload: function (r) { window.__rt = r.responseText; } });";
        const { calls, win } = bootIsolated(src);
        await new Promise((r) => setTimeout(r, 10));
        const xhr = calls.filter((c) => c.api === "GM_xmlhttpRequest")[0];
        const binaryText = "ÿ";   // native builds this 1-char-per-byte string
        win.__brownbear.dispatchXHR(xhr.payload.requestId, "load", {
            isBase64: false, responseText: binaryText, response: binaryText, status: 200, readyState: 4
        });
        test("isolated: the native byte-preserving responseText reaches the script intact", () => {
            assert.strictEqual(win.__rt, binaryText);
            assert.strictEqual(win.__rt.charCodeAt(1), 0xFF);
        });
    }

    // ---- Page world: request serialization (binary body + overrideMimeType) --------------------
    {
        const src = "GM_xmlhttpRequest({ method: 'POST', url: 'https://google.com/u', "
            + "data: new Uint8Array([1,2,3]).buffer, overrideMimeType: 'text/plain; charset=x-user-defined' });";
        const calls = bootPageWorld(src);
        await new Promise((r) => setTimeout(r, 10));
        const injects = calls.filter((c) => c.api === "injectPageWorld");
        test("page world: the GM_xmlhttpRequest script routed to the page world", () => {
            assert.strictEqual(injects.length, 1);
        });
        const writes = runPageWorldXHR(injects[0].payload.code);
        const xhrWrite = writes.filter((w) => w.api === "GM_xmlhttpRequest")[0];
        test("page world: a binary body is sent base64 through the vault", () => {
            assert.ok(xhrWrite, "a GM_xmlhttpRequest was posted via the vault");
            assert.strictEqual(xhrWrite.payload.request.dataIsBase64, true);
            assert.strictEqual(xhrWrite.payload.request.data, b64([1, 2, 3]));
        });
        test("page world: overrideMimeType is passed through to native", () => {
            assert.strictEqual(xhrWrite.payload.request.overrideMimeType, "text/plain; charset=x-user-defined");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
