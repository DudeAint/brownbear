"use strict";
//
//  filereader-event-target.test.js
//  BrownBear
//
//  Pins the background FileReader shim's progress events. The canonical read pattern is
//  `reader.onload = e => e.target.result`; the spec ProgressEvent exposes `target`/`currentTarget`
//  (the FileReader), `loaded`, and `total`. Tampermonkey's blob→text decoder (`Ke`) does exactly:
//
//      o.onload = ev => ev.target ? resolve(ev.target.result) : reject("Could not convert array to string!")
//
//  When the dispatched event lacked `target`, that decode REJECTED. The reject was swallowed, so an
//  imported .user.js parsed to an EMPTY source and the manager surfaced "Unable to parse this!" for
//  every "import from URL" in the Utilities tab. These tests run against the REAL background shim.
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
    // Build the source's bytes in-realm so `new Blob([arraybuffer])` keeps them (cross-realm buffers
    // fail the shim's `instanceof ArrayBuffer` flatten check — a harness artifact, not device behavior).
    const SRC = "// ==UserScript==\n// @name X\n// ==/UserScript==\nbody();\n";
    ctx.__BYTES = Array.from(Buffer.from(SRC, "utf8"));

    await test("readAsBinaryString fires `load` with e.target.result (Tampermonkey's Ke decode)", async function () {
        const out = await run(ctx, `async function(){
            var u = new Uint8Array(globalThis.__BYTES);
            var blob = new Blob([u.buffer], {type: "binary/octet-stream"});
            return await new Promise(function(res, rej){
                var o = new FileReader();
                o.onload = function(ev){ ev.target ? res(ev.target.result) : rej(new Error("Could not convert array to string!")); };
                o.onerror = function(){ rej(new Error("reader onerror")); };
                o.readAsBinaryString(blob);
            });
        }`);
        assert.ok(out.indexOf("==UserScript==") >= 0, "expected the source back, got: " + JSON.stringify(out).slice(0, 60));
    });

    await test("readAsText fires `load` with e.target.result (UTF-8)", async function () {
        const out = await run(ctx, `async function(){
            var u = new Uint8Array(globalThis.__BYTES);
            return await new Promise(function(res, rej){
                var o = new FileReader();
                o.addEventListener("load", function(ev){ res(ev.target.result); });
                o.readAsText(new Blob([u.buffer], {type: "text/plain"}), "UTF-8");
            });
        }`);
        assert.strictEqual(out, "// ==UserScript==\n// @name X\n// ==/UserScript==\nbody();\n");
    });

    await test("readAsArrayBuffer exposes the bytes via e.target.result", async function () {
        const len = await run(ctx, `async function(){
            var u = new Uint8Array(globalThis.__BYTES);
            return await new Promise(function(res){
                var o = new FileReader();
                o.onload = function(ev){ res(ev.target.result.byteLength); };
                o.readAsArrayBuffer(new Blob([u.buffer]));
            });
        }`);
        assert.strictEqual(len, ctx.__BYTES.length);
    });

    await test("readAsDataURL exposes a data: URI via e.target.result", async function () {
        const uri = await run(ctx, `async function(){
            return await new Promise(function(res){
                var o = new FileReader();
                o.onload = function(ev){ res(ev.target.result); };
                o.readAsDataURL(new Blob(["hi"], {type: "text/plain"}));
            });
        }`);
        assert.ok(/^data:text\/plain;base64,/.test(uri), "expected data: URI, got: " + uri);
        assert.strictEqual(Buffer.from(uri.split(",")[1], "base64").toString("utf8"), "hi");
    });

    await test("progress events fire in order, each carrying target/loaded/total", async function () {
        // Reduce to primitives in-realm — assert across the vm boundary on strings/numbers, not arrays
        // (a vm-realm array fails deepStrictEqual's prototype check against a Node-realm one).
        const out = await run(ctx, `async function(){
            var u = new Uint8Array(globalThis.__BYTES);
            var order = [], allHaveTarget = true, loadTotal = -1;
            return await new Promise(function(res){
                var o = new FileReader();
                ["loadstart","progress","load","loadend"].forEach(function(t){
                    o.addEventListener(t, function(ev){
                        order.push(ev.type);
                        if (ev.target !== o) { allHaveTarget = false; }
                        if (ev.type === "load") { loadTotal = ev.total; }
                    });
                });
                o.addEventListener("loadend", function(){ res({ order: order.join(","), allHaveTarget: allHaveTarget, loadTotal: loadTotal }); });
                o.readAsText(new Blob([u.buffer]));
            });
        }`);
        assert.strictEqual(out.order, "loadstart,progress,load,loadend", "event order was: " + out.order);
        assert.ok(out.allHaveTarget, "every event's target must be the reader");
        assert.strictEqual(out.loadTotal, ctx.__BYTES.length, "load.total must be the byte length");
    });

    await test("a non-Blob argument fires `error` (with target) and rejects, not crash", async function () {
        const msg = await run(ctx, `async function(){
            return await new Promise(function(res){
                var o = new FileReader();
                o.onerror = function(ev){ res({ hasTarget: ev.target === o, err: o.error && o.error.message }); };
                o.onload = function(){ res({ hasTarget: false, err: "UNEXPECTED LOAD" }); };
                o.readAsText({ not: "a blob" });
            });
        }`);
        assert.ok(msg.hasTarget, "error event must carry target");
        assert.ok(/not a Blob/.test(msg.err || ""), "expected a 'not a Blob' error, got: " + msg.err);
    });

    console.log("\n" + passed + " passed" + (process.exitCode ? "" : ", 0 failed"));
    process.exit(process.exitCode || 0);
})();
