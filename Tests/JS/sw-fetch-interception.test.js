//
//  sw-fetch-interception.test.js
//  BrownBear
//
//  Service-worker FETCH interception in the background shim (brownbear-webext-background.js). A real
//  MV3 service worker can serve its OWN extension-scheme requests from a `fetch` event handler — Stylus
//  serves chrome-extension://<id>/data?… (the per-frame client data its popup/content pages load as a
//  script) entirely from the worker, never from a packaged file. BrownBear's background is a headless
//  JSContext, so WebKit never fires a fetch event; the URL scheme handler instead calls the shim's
//  `__bbDispatchFetch(url, method, headers, callback)` when a request has no packaged file, and serves
//  the worker's respondWith Response.
//
//  Regression: the shim stored 'fetch' listeners but never dispatched them, and didn't honor the
//  self.onfetch property form or e.addRoutes() (Static Routing API) Stylus uses — so /data?… 404'd,
//  the popup's `clientData` was never defined, and its message handlers deadlocked ("listener returned
//  true but sendResponse never called"). This locks the dispatch contract in.
//
//  Pure Node, no deps. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/sw-fetch-interception.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const SHIM_SRC = fs.readFileSync(
    path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-background.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    Promise.resolve()
        .then(fn)
        .then(() => { console.log("  ok   " + name); passed++; })
        .catch((e) => { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; });
}

/** Boot the real background shim in a fresh sandbox with the minimal native surface it needs at load. */
function bootShim() {
    const sandbox = {};
    sandbox.globalThis = sandbox;
    sandbox.self = sandbox;
    sandbox.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    sandbox.setTimeout = setTimeout; sandbox.clearTimeout = clearTimeout;
    sandbox.setInterval = setInterval; sandbox.clearInterval = clearInterval;
    sandbox.TextEncoder = TextEncoder; sandbox.TextDecoder = TextDecoder;
    sandbox.URL = URL; sandbox.URLSearchParams = URLSearchParams;
    sandbox.Promise = Promise; sandbox.JSON = JSON; sandbox.Math = Math; sandbox.Date = Date;
    sandbox.Object = Object; sandbox.Array = Array; sandbox.Error = Error;
    // Minimal native bridges referenced during shim load / event setup.
    const cb = function () { const a = arguments; const c = a[a.length - 1]; if (typeof c === "function") { try { c(JSON.stringify(null)); } catch (e) { /* noop */ } } };
    for (const n of ["__bb_log", "__bb_send_message", "__bb_storage_get", "__bb_storage_set",
        "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr",
        "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_alarm_create", "__bb_alarm_clear",
        "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all", "__bb_fetch"]) {
        sandbox[n] = cb;
    }
    sandbox.__bb_set_timeout = (fn, ms, repeat) => repeat ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0);
    sandbox.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sandbox.__bbBgExtId = "stylusfakeidaaaaaaaaaaaaaaaaaaaa";
    sandbox.__bbBgBaseURL = "chrome-extension://stylusfakeidaaaaaaaaaaaaaaaaaaaa/";
    sandbox.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "T", version: "1",
        background: { service_worker: "sw.js" } });
    sandbox.__bbBgMessages = "{}";
    sandbox.__bbUserAgent = "UA"; sandbox.__bbLanguage = "en-US";
    vm.createContext(sandbox);
    vm.runInContext(SHIM_SRC, sandbox, { filename: "brownbear-webext-background.js" });
    return sandbox;
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

test("self.onfetch serves /data?… via respondWith; addRoutes doesn't throw", async () => {
    const ctx = bootShim();
    let installFired = false;
    ctx.oninstall = (e) => {
        installFired = true;
        // The SW Static Routing API — must not throw even though we don't honor routes natively.
        e.addRoutes({ condition: { urlPattern: ctx.__bbBgBaseURL + "data?*" }, source: "fetch-event" });
    };
    ctx.onfetch = (e) => {
        const u = e.request.url;
        if (u.indexOf("/data?") >= 0) {
            const dark = new ctx.URL(u).searchParams.get("dark") || "0";
            e.respondWith(Promise.resolve(new ctx.Response("clientData={\"dark\":" + dark + "}",
                { headers: { "content-type": "text/javascript", "cache-control": "no-cache" } })));
        }
    };
    await delay(30);   // let the synthetic install event fire (deferred via the timer shim)
    assert.strictEqual(installFired, true, "install event with addRoutes should fire without throwing");

    const matchedJSON = await ctx.__bbDispatchFetch(
        ctx.__bbBgBaseURL + "data?dark=1&frameId=0&url=popup.html", "GET", "{}");
    const matched = JSON.parse(matchedJSON);
    assert.strictEqual(matched.matched, true, "worker should claim /data?…");
    assert.strictEqual(matched.status, 200);
    assert.strictEqual(matched.headers["content-type"], "text/javascript");
    const body = Buffer.from(matched.bodyBase64, "base64").toString("utf8");
    assert.strictEqual(body, "clientData={\"dark\":1}", "served body should be the worker's response");
});

test("a request the worker doesn't claim returns matched:false (fall through to 404)", async () => {
    const ctx = bootShim();
    ctx.onfetch = (e) => { if (e.request.url.indexOf("/data?") >= 0) { e.respondWith(new ctx.Response("x")); } };
    await delay(30);
    const res = JSON.parse(await ctx.__bbDispatchFetch(ctx.__bbBgBaseURL + "missing.png", "GET", "{}"));
    assert.strictEqual(res.matched, false, "unclaimed request must fall through, not be synthesized");
});

test("result is delivered to native via __bb_sw_fetch_response(requestId, json)", async () => {
    // The DEVICE path: native parks a continuation by requestId and the shim reports back through the
    // __bb_sw_fetch_response native (NOT a passed-in block — that silently dropped replies on device,
    // blanking the Stylus popup). This locks the request-id delivery contract in.
    const ctx = bootShim();
    const delivered = {};
    ctx.__bb_sw_fetch_response = (requestId, json) => { delivered[requestId] = json; };
    ctx.onfetch = (e) => {
        if (e.request.url.indexOf("/data?") >= 0) { e.respondWith(new ctx.Response("clientData={}")); }
    };
    await delay(30);
    await ctx.__bbDispatchFetch(ctx.__bbBgBaseURL + "data?x=1", "GET", "{}", "swf-7");
    await delay(10);
    assert.ok(delivered["swf-7"], "native must receive the result keyed by the requestId it passed");
    const parsed = JSON.parse(delivered["swf-7"]);
    assert.strictEqual(parsed.matched, true);
    assert.strictEqual(Buffer.from(parsed.bodyBase64, "base64").toString("utf8"), "clientData={}");
});

test("no fetch handler at all → matched:false", async () => {
    const ctx = bootShim();
    await delay(30);
    const res = JSON.parse(await ctx.__bbDispatchFetch(ctx.__bbBgBaseURL + "data?x=1", "GET", "{}"));
    assert.strictEqual(res.matched, false, "a worker with no fetch listener claims nothing");
});

// Settle the async tests, then report.
setTimeout(() => {
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
}, 400);
