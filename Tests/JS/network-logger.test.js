//
//  network-logger.test.js
//  BrownBear
//
//  Tests the page-world network reporter (brownbear-network-logger.js): it transparently wraps `fetch` and
//  `XMLHttpRequest`, and posts one {kind, method, url, status, duration} record per request to the native
//  `brownbearNetLog` handler — without breaking the request or the page. Verifies the fetch success/failure
//  paths, the XHR loadend path, the no-handler bail-out, and the native-looking toString mask.
//
//  Pure Node, no deps. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/network-logger.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-network-logger.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// Boot the reporter over a mock page. `opts.noHandler` omits the native bridge; otherwise posts are
// collected. A mock fetch (resolve/reject controllable) and a mock XMLHttpRequest are installed.
function boot(opts) {
    opts = opts || {};
    const posts = [];
    const win = {};
    win.window = win;
    win.String = String;
    win.performance = { now: () => 1000 };
    win.webkit = opts.noHandler ? undefined
        : { messageHandlers: { brownbearNetLog: { postMessage: (r) => posts.push(r) } } };

    // Mock fetch — `state.next` is the next outcome ({status, body} to resolve, or an Error to reject).
    // The resolved value is a minimal Response with clone()/headers.get()/text() so the reporter can read
    // a (bounded) copy of the body without consuming the page's own read.
    const state = { next: { status: 200 }, origCalled: 0 };
    win.fetch = function () {
        state.origCalled++;
        if (state.next instanceof Error) { return Promise.reject(state.next); }
        const status = state.next.status;
        const bodyText = state.next.body != null ? String(state.next.body) : "";
        function makeResponse() {
            return {
                status: status,
                headers: { get: (k) => (String(k).toLowerCase() === "content-length" ? String(bodyText.length) : null) },
                clone: () => makeResponse(),
                text: () => Promise.resolve(bodyText)
            };
        }
        return Promise.resolve(makeResponse());
    };

    // Mock XMLHttpRequest — records open args; send is a no-op (the reporter's wrapper adds a loadend
    // listener which the test fires manually to simulate completion).
    function XHR() { this._listeners = {}; this.status = 0; }
    XHR.prototype.open = function (method, url) { this._openMethod = method; this._openUrl = url; };
    XHR.prototype.send = function () {};
    XHR.prototype.addEventListener = function (type, cb) {
        (this._listeners[type] = this._listeners[type] || []).push(cb);
    };
    win.XMLHttpRequest = XHR;

    const ctx = { window: win, console };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return { win, posts, state, XHR, ctx };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

(async function main() {
    console.log("network-logger reporter tests");

    // fetch success posts one record with method/url/status + the (bounded) response body. The body read
    // is async (clone().text()), so the record lands a microtask after the response resolves.
    {
        const { win, posts, state } = boot();
        state.next = { status: 204, body: '{"ok":true}' };
        const res = await win.fetch("https://api.example.com/x", { method: "post" });
        await tick();
        test("fetch success → {kind:fetch, method, url, status, responseBody} record", () => {
            assert.strictEqual(res.status, 204, "the original response passes through unchanged");
            assert.strictEqual(posts.length, 1, "one record posted");
            assert.strictEqual(posts[0].kind, "fetch");
            assert.strictEqual(posts[0].method, "POST", "method uppercased");
            assert.strictEqual(posts[0].url, "https://api.example.com/x");
            assert.strictEqual(posts[0].status, 204);
            assert.strictEqual(posts[0].responseBody, '{"ok":true}', "the response body is captured");
        });
    }

    // fetch rejection posts status 0 + error, and still rejects to the caller.
    {
        const { win, posts, state } = boot();
        state.next = new Error("network down");
        let threw = false;
        try { await win.fetch("https://x.com/y"); } catch (e) { threw = true; }
        test("fetch failure rejects AND posts status 0 + error", () => {
            assert.ok(threw, "the rejection still reaches the caller");
            assert.strictEqual(posts.length, 1);
            assert.strictEqual(posts[0].status, 0);
            assert.ok(/network down/.test(posts[0].error || ""));
        });
    }

    // XHR posts on loadend with the open() method/url, the final status, and the responseText body.
    {
        const { posts, XHR } = boot();
        const xhr = new XHR();
        xhr.open("GET", "https://x.com/data.json");
        xhr.send();
        xhr.status = 200;
        xhr.responseType = "";
        xhr.responseText = '{"data":1}';
        // Fire the loadend listener the reporter attached in send().
        (xhr._listeners.loadend || []).forEach((cb) => cb());
        test("XHR → {kind:xhr, method, url, status, responseBody} on loadend", () => {
            assert.strictEqual(posts.length, 1);
            assert.strictEqual(posts[0].kind, "xhr");
            assert.strictEqual(posts[0].method, "GET");
            assert.strictEqual(posts[0].url, "https://x.com/data.json");
            assert.strictEqual(posts[0].status, 200);
            assert.strictEqual(posts[0].responseBody, '{"data":1}');
        });
    }

    // No native handler → the reporter bails and leaves fetch untouched.
    {
        const { win, state } = boot({ noHandler: true });
        await win.fetch("https://x.com/z");
        test("no handler → reporter is inert (original fetch still runs, no wrapping crash)", () => {
            assert.strictEqual(state.origCalled, 1, "the page's fetch still ran");
        });
    }

    // The wrapped fetch masks its toString so a site can't fingerprint the wrapper.
    {
        const { win } = boot();
        test("wrapped fetch.toString() looks native", () => {
            assert.ok(/\[native code\]/.test(win.fetch.toString()));
        });
    }

    // Double-injection guard: running again in the same window doesn't re-wrap.
    {
        const { win, ctx } = boot();
        const fetchAfterFirst = win.fetch;
        vm.runInContext(SRC, ctx);
        test("re-injection is a no-op (the __bbNetLog guard holds)", () => {
            assert.strictEqual(win.fetch, fetchAfterFirst, "fetch isn't double-wrapped");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed === 0 ? 0 : 1);
})();
