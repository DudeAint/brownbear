//
//  gm-resource-blob-url.test.js
//  BrownBear
//
//  GM_getResourceURL (brownbear-runtime.js) must hand back a blob: URL, not the data: URL the resource
//  crosses the bridge as — matching Violentmonkey/Tampermonkey. The very common `img-src 'self' blob:` CSP
//  permits a blob: URL but BLOCKS a data: URL, so `img.src = GM_getResourceURL('icon')` renders under VM
//  yet was silently dropped here. The conversion is lazy + memoized (one blob: per resource name) and must
//  fall back to the original data: URL when Blob/createObjectURL aren't available, so it can never make a
//  resource LESS usable. This pins both the isolated-world and the page-world (granted, VM-parity) paths.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/gm-resource-blob-url.test.js`. Exits non-zero on any failure.
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

const ICON_BYTES = [1, 2, 3, 4, 250];
const ICON_B64 = Buffer.from(ICON_BYTES).toString("base64");
const ICON_MIME = "image/png";

// atob + Blob + URL.createObjectURL stubs. `opts.noURL`/`opts.noBlob` exercise the data: fallback path.
function blobStubs(opts) {
    opts = opts || {};
    const objectURLs = [];   // the Blob objects handed to createObjectURL, in order
    const URLStub = {
        createObjectURL(blob) { objectURLs.push(blob); return "blob:bb/" + objectURLs.length; },
        revokeObjectURL() {}
    };
    function Blob(parts, options) { this.parts = parts; this.type = options ? options.type : undefined; }
    const stubs = {
        // WebKit's atob THROWS on invalid base64; opts.throwAtob simulates that to prove the fail-closed path.
        atob: opts.throwAtob
            ? () => { throw new Error("invalid base64"); }
            : (b64) => Buffer.from(b64, "base64").toString("binary"),
        Uint8Array
    };
    if (!opts.noBlob) { stubs.Blob = Blob; }
    if (!opts.noURL) { stubs.URL = URLStub; }
    return { stubs, objectURLs };
}

// Boot the runtime and run an ISOLATED (@inject-into content) script that reads a @resource twice (+ a
// missing one). Returns the script window + the Blobs createObjectURL was handed.
function bootIsolatedResource(opts) {
    const { stubs, objectURLs } = blobStubs(opts);
    const script = {
        token: "tok", name: "restest", uuid: "55555555-5555-5555-5555-555555555555",
        runAt: "document-start", grants: ["GM_getResourceURL"], grantNone: false, noFrames: false,
        injectInto: "content", requires: [], resources: { icon: "https://cdn.example.com/icon.png" },
        source: "window.__u1 = GM_getResourceURL('icon');"
            + "window.__u2 = GM_getResourceURL('icon');"
            + "window.__missing = GM_getResourceURL('nope');",
        values: {}, info: { scriptHandler: "BrownBear" }
    };
    function postMessage(msg) {
        if (msg.api === "getScripts") { return Promise.resolve([script]); }
        if (msg.api === "fetchResource") {
            return Promise.resolve({ base64: ICON_B64, mimeType: ICON_MIME, text: "" });
        }
        return Promise.resolve(null);
    }
    const win = Object.assign({
        webkit: { messageHandlers: { brownbear: { postMessage } } },
        history: { pushState() {}, replaceState() {} },
        location: { href: "https://example.com/page" },
        addEventListener() {}, removeEventListener() {}, console, CustomEvent: function () {}
    }, stubs);
    win.window = win; win.self = win; win.top = win;
    const document = {
        readyState: "complete", addEventListener() {},
        head: { appendChild(n) { return n; } }, documentElement: { appendChild(n) { return n; } },
        createElement() { return { setAttribute() {}, appendChild() {} }; }
    };
    const ctx = { console, window: win, document, location: win.location, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return { win, objectURLs };
}

// Boot the runtime for a GRANTED page-world-safe script (only GM_getResourceURL ⇒ routes to the page world),
// capturing the native bridge calls; the injectPageWorld payload is its page-world source.
function bootPageWorldResource() {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-pw", name: "pwrestest", uuid: "66666666-6666-6666-6666-666666666666",
                runAt: "document-start", grants: ["GM_getResourceURL"], grantNone: false, noFrames: false,
                injectInto: "auto", requires: [], resources: { icon: "https://cdn.example.com/icon.png" },
                source: "window.__pwu = GM_getResourceURL('icon');", values: {},
                info: { scriptHandler: "BrownBear" }
            }]);
        }
        if (msg.api === "fetchResource") {
            return Promise.resolve({ base64: ICON_B64, mimeType: ICON_MIME, text: "" });
        }
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

// Run an emitted page-world payload in a PAGE context that has the blob/atob stubs; returns its window.
function runPageWorldCode(code) {
    const { stubs, objectURLs } = blobStubs();
    const pageWin = Object.assign({
        JSON, Object, Array, Promise, console, __obs: {},
        history: { pushState() {}, replaceState() {} }, location: { href: "https://example.com/p" },
        addEventListener() {}, removeEventListener() {}, CustomEvent: function () {}, __bbPageGM: function () {}
    }, stubs);
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const pageDoc = {
        head: { appendChild(n) { return n; } }, documentElement: { appendChild(n) { return n; } },
        createElement() { return { setAttribute() {}, appendChild() {} }; }
    };
    pageWin.document = pageDoc;
    const ctx = { window: pageWin, document: pageDoc, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    return { pageWin, objectURLs };
}

(async function main() {
    console.log("GM_getResourceURL returns a blob: URL (Violentmonkey CSP/img-src parity)");
    await new Promise((r) => setTimeout(r, 15));   // let getScripts → loadResources → run() settle

    // 1) Isolated world: a @resource read returns a blob: URL built from the right bytes + mime, cached.
    {
        const { win, objectURLs } = bootIsolatedResource();
        await new Promise((r) => setTimeout(r, 15));
        test("isolated: GM_getResourceURL returns a blob: URL, not a data: URL", () => {
            assert.strictEqual(typeof win.__u1, "string");
            assert.ok(win.__u1.indexOf("blob:") === 0, "expected blob:, got " + win.__u1);
        });
        test("isolated: the Blob carries the resource's mime and exact bytes", () => {
            assert.strictEqual(objectURLs.length, 1);
            const blob = objectURLs[0];
            assert.strictEqual(blob.type, ICON_MIME);
            const bytes = blob.parts[0];
            assert.strictEqual(bytes.length, ICON_BYTES.length);
            assert.deepStrictEqual(Array.from(bytes), ICON_BYTES);
        });
        test("isolated: repeated calls are memoized (same URL, createObjectURL called once)", () => {
            assert.strictEqual(win.__u1, win.__u2);
            assert.strictEqual(objectURLs.length, 1);
        });
        test("isolated: an unknown resource name is undefined", () => {
            assert.strictEqual(win.__missing, undefined);
        });
    }

    // 2) Fallback: without URL.createObjectURL, GM_getResourceURL returns the original data: URL (no throw).
    {
        const { win, objectURLs } = bootIsolatedResource({ noURL: true });
        await new Promise((r) => setTimeout(r, 15));
        test("fallback: with no createObjectURL, the original data: URL is returned unchanged", () => {
            assert.strictEqual(typeof win.__u1, "string");
            assert.ok(win.__u1.indexOf("data:" + ICON_MIME + ";base64,") === 0,
                "expected the data: URL, got " + win.__u1);
            assert.strictEqual(objectURLs.length, 0, "no blob URL was minted");
        });
    }

    // 2b) Fail-closed: a throwing atob (WebKit's behavior on bad base64) must fall back to the data: URL,
    //     never throw out of GM_getResourceURL or mint a blob from garbage.
    {
        const { win, objectURLs } = bootIsolatedResource({ throwAtob: true });
        await new Promise((r) => setTimeout(r, 15));
        test("fail-closed: a throwing atob falls back to the data: URL (no throw, no blob)", () => {
            assert.strictEqual(typeof win.__u1, "string");
            assert.ok(win.__u1.indexOf("data:") === 0, "expected the data: URL, got " + win.__u1);
            assert.strictEqual(objectURLs.length, 0, "no blob URL minted from un-decodable bytes");
        });
    }

    // 3) Page world (granted, VM-parity main-world execution): same blob: behavior.
    {
        const calls = bootPageWorldResource();
        await new Promise((r) => setTimeout(r, 15));
        const injects = calls.filter((c) => c.api === "injectPageWorld");
        test("the granted GM_getResourceURL script routed to the page world", () => {
            assert.strictEqual(injects.length, 1);
        });
        const { pageWin, objectURLs } = runPageWorldCode(injects[0].payload.code);
        test("page world: GM_getResourceURL returns a blob: URL", () => {
            assert.strictEqual(typeof pageWin.__pwu, "string");
            assert.ok(pageWin.__pwu.indexOf("blob:") === 0, "expected blob:, got " + pageWin.__pwu);
        });
        test("page world: the Blob carries the resource's mime and exact bytes", () => {
            assert.strictEqual(objectURLs.length, 1);
            assert.strictEqual(objectURLs[0].type, ICON_MIME);
            assert.deepStrictEqual(Array.from(objectURLs[0].parts[0]), ICON_BYTES);
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
