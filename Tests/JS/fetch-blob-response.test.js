"use strict";
//
//  fetch-blob-response.test.js
//  BrownBear
//
//  Pins the two body-reconstruction paths Tampermonkey's save pipeline uses to read a script's source
//  back out of a Blob (its $c install step: tfd → fetch(objUrl).blob() → new Response(blob).text() →
//  the registered textContent):
//    1. fetch("blob:…") must resolve an object URL minted by THIS context's URL.createObjectURL from
//       the in-context registry (the bytes exist only in this JSContext — the native HTTP path can
//       never serve them). It used to reject → toBlob() swallowed → undefined.
//    2. new Response(blob).text() — the SPEC BodyInit constructor form — must return the blob's text.
//       It used to hit the internal native-result branch and return "" → the script registered EMPTY
//       and never appeared in the installed list ("No script is installed") while the editor showed
//       "saved successfully".
//

const fs = require("fs");
const vm = require("vm");
const path = require("path");
const assert = require("assert");

const BG = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webext-background.js"), "utf8");

let passed = 0;
function test(name, fn) {
    return Promise.resolve()
        .then(fn)
        .then(function () { console.log("  ok   " + name); passed++; },
              function (e) { console.log("  FAIL " + name + "\n       " + (e && e.message)); process.exitCode = 1; });
}

function bootShim() {
    const ctx = {}; ctx.globalThis = ctx; ctx.self = ctx;
    const noop = function () { var a = arguments, cb = a[a.length - 1]; if (typeof cb === "function") { cb("null"); } };
    for (const f of ["__bb_set_timeout", "__bb_clear_timer", "__bb_log", "__bb_storage_get",
        "__bb_storage_set", "__bb_send_message", "__bb_message_response", "__bb_idle", "__bb_subtle",
        "__bb_fetch"]) { ctx[f] = noop; }
    ctx.__bb_set_timeout = (fn, ms) => setTimeout(fn, ms || 0);
    ctx.__bb_clear_timer = (id) => clearTimeout(id);
    ctx.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "T", version: "1.0" });
    ctx.__bbBgExtId = "abcdefghijklmnopabcdefghijklmnop";
    ctx.__bbBgBaseURL = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/";
    ctx.__bbBgMessages = "{}"; ctx.__bbBgPlaceholders = "{}";
    ctx.__bbUserAgent = "Mozilla/5.0"; ctx.__bbLanguage = "en-US";
    ctx.__bbModuleSource = function () { return null; };
    ctx.TextEncoder = TextEncoder; ctx.TextDecoder = TextDecoder;
    vm.createContext(ctx);
    vm.runInContext(BG, ctx, { filename: "brownbear-webext-background.js" });
    return ctx;
}

function run(ctx, code) {
    // Evaluate an async expression in-context and await its completion via a polled global.
    vm.runInContext("globalThis.__r = undefined; (" + code + ")().then(function(v){ globalThis.__r = {v: v}; }, function(e){ globalThis.__r = {e: (e && e.message) || String(e)}; });", ctx);
    return new Promise(function (resolve, reject) {
        const t0 = Date.now();
        (function poll() {
            if (ctx.__r !== undefined) {
                if (ctx.__r.e !== undefined) { reject(new Error(ctx.__r.e)); } else { resolve(ctx.__r.v); }
                return;
            }
            if (Date.now() - t0 > 3000) { reject(new Error("timed out")); return; }
            setTimeout(poll, 20);
        })();
    });
}

(async function () {
    const ctx = bootShim();

    await test("fetch(blob:) resolves an in-context object URL to its bytes (TM toBlob path)", async function () {
        const text = await run(ctx, `async function(){
            var blob = new Blob(["// userscript source"], {type: "text/javascript"});
            var url = URL.createObjectURL(blob);
            var r = await fetch(url);
            if (!r.ok || r.status !== 200) { throw new Error("bad status " + r.status); }
            return await r.text();
        }`);
        assert.strictEqual(text, "// userscript source");
    });

    await test("fetch(blob:).blob() round-trips the Blob with its content type", async function () {
        const out = await run(ctx, `async function(){
            var blob = new Blob(["abc"], {type: "text/plain"});
            var b2 = await (await fetch(URL.createObjectURL(blob))).blob();
            return { type: b2.type, text: await new Response(b2).text() };
        }`);
        assert.strictEqual(out.text, "abc");
        assert.ok(String(out.type).indexOf("text/plain") === 0, "type preserved, got " + out.type);
    });

    await test("fetch of a revoked/unknown blob: URL rejects with TypeError (Chrome behavior)", async function () {
        const msg = await run(ctx, `async function(){
            var url = URL.createObjectURL(new Blob(["x"]));
            URL.revokeObjectURL(url);
            try { await fetch(url); return "RESOLVED"; } catch (e) { return e.message; }
        }`);
        assert.ok(/Failed to fetch/.test(msg), "expected TypeError Failed to fetch, got: " + msg);
    });

    await test("new Response(blob).text() returns the blob's text (spec BodyInit form)", async function () {
        const text = await run(ctx, `async function(){
            return await new Response(new Blob(["hello body"], {type: "text/plain"})).text();
        }`);
        assert.strictEqual(text, "hello body");
    });

    await test("new Response(string) / (ArrayBuffer) / default status follow the spec", async function () {
        const out = await run(ctx, `async function(){
            var rs = new Response("plain");
            var ab = new TextEncoder().encode("bytes").buffer;
            var rb = new Response(ab);
            var empty = new Response();
            return { s: await rs.text(), b: await rb.text(), st: rs.status, ok: rs.ok, e: await empty.text() };
        }`);
        assert.strictEqual(out.s, "plain");
        assert.strictEqual(out.b, "bytes");
        assert.strictEqual(out.st, 200);
        assert.strictEqual(out.ok, true);
        assert.strictEqual(out.e, "");
    });

    await test("Response init {status, headers} is honored in the spec form", async function () {
        const out = await run(ctx, `async function(){
            var r = new Response("nope", { status: 404, statusText: "NF", headers: { "X-A": "1" } });
            return { status: r.status, ok: r.ok, st: r.statusText, h: r.headers.get("x-a") };
        }`);
        assert.strictEqual(out.status, 404);
        assert.strictEqual(out.ok, false);
        assert.strictEqual(out.st, "NF");
        assert.strictEqual(out.h, "1");
    });

    await test("the internal native-result Response form still works (fetch/clone path unchanged)", async function () {
        const out = await run(ctx, `async function(){
            var r = new Response({ ok: true, status: 200, headers: {"content-type": "text/plain"},
                                   bodyBase64: btoa("native") });
            var c = r.clone();
            return { t: await r.text(), ct: c.status, cb: await c.text() };
        }`);
        assert.strictEqual(out.t, "native");
        assert.strictEqual(out.ct, 200);
        assert.strictEqual(out.cb, "native");
    });

    console.log("\n" + passed + " passed" + (process.exitCode ? "" : ", 0 failed"));
    process.exit(process.exitCode || 0);
})();
