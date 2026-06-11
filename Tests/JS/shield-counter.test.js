"use strict";
//
//  shield-counter.test.js
//  BrownBear
//
//  Pins brownbear-shield-counter.js — the page-world observer that recovers a real "N blocked" count
//  by reporting the hosts a page tries to load. Two things must hold:
//    1. It TRANSPARENTLY wraps the request APIs — the original is called with the original this/args,
//       its exact result is returned, and `fn.toString()` still reads "[native code]". A bug here would
//       break real page requests, so transparency is the safety contract.
//    2. It reports the destination HOST (deduped host→count, flushed on a timer), skipping non-network
//       schemes (data:/blob:/about:), so native can match against the blocklist.
//

const fs = require("fs");
const vm = require("vm");
const path = require("path");
const assert = require("assert");

const SRC = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-shield-counter.js"), "utf8");

let passed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message)); process.exitCode = 1; }
}

// Build a minimal page-world environment, run the shim in it, and return the live window + a flush()
// that drains the debounced reporter synchronously (the shim captured our setTimeout).
function bootEnv(opts) {
    opts = opts || {};
    const posted = [];
    const pendingTimers = [];
    const realFetch = function fetch(input, init) { return { __from: "realFetch", input: input, init: init }; };
    let lastXHROpen = null;
    function FakeXHR() {}
    FakeXHR.prototype.open = function open(method, url) { lastXHROpen = { method: method, url: url, this: this }; return "realOpen:" + url; };

    const win = {};
    win.window = win;
    win.self = win;
    win.URL = URL;
    win.location = { href: "https://news.example.com/article", host: "news.example.com" };
    win.setTimeout = function (fn) { pendingTimers.push(fn); return pendingTimers.length; };
    win.fetch = realFetch;
    win.XMLHttpRequest = FakeXHR;
    win.navigator = { sendBeacon: function sendBeacon(url, data) { return "realBeacon:" + url; } };
    win.Object = Object; win.Function = Function; win.Array = Array;
    win.webkit = { messageHandlers: opts.noHandler ? {} : {
        brownbearShieldCounter: { postMessage: function (m) { posted.push(m); } }
    } };

    vm.createContext(win);
    vm.runInContext(SRC, win, { filename: "brownbear-shield-counter.js" });

    return {
        win: win,
        posted: posted,
        flush: function () { const t = pendingTimers.splice(0); t.forEach(function (fn) { try { fn(); } catch (e) {} }); },
        lastXHROpen: function () { return lastXHROpen; },
        realFetch: realFetch
    };
}

// Merge every flushed {hosts} map into one host→count object.
function mergedHosts(posted) {
    const out = {};
    posted.forEach(function (m) {
        if (m && m.hosts) { for (const h in m.hosts) { out[h] = (out[h] || 0) + m.hosts[h]; } }
    });
    return out;
}

test("fetch wrapper is transparent (calls original, returns its result, native toString)", function () {
    const env = bootEnv();
    const r = env.win.fetch("https://ads.tracker.com/pixel.gif");
    assert.strictEqual(r.__from, "realFetch", "must return the real fetch's result");
    assert.strictEqual(r.input, "https://ads.tracker.com/pixel.gif", "must pass the original argument through");
    assert.ok(/\[native code\]/.test(env.win.fetch.toString()), "toString must read native, got: " + env.win.fetch.toString());
    assert.strictEqual(env.win.fetch.name, "fetch", "name preserved");
});

test("fetch records the destination host", function () {
    const env = bootEnv();
    env.win.fetch("https://ads.tracker.com/pixel.gif");
    env.win.fetch("https://ads.tracker.com/again");
    env.flush();
    const hosts = mergedHosts(env.posted);
    assert.strictEqual(hosts["ads.tracker.com"], 2, "two requests to the host → count 2, got " + JSON.stringify(hosts));
});

test("XMLHttpRequest.open is transparent and records", function () {
    const env = bootEnv();
    const xhr = new env.win.XMLHttpRequest();
    const ret = env.win.XMLHttpRequest.prototype.open.call(xhr, "GET", "https://metrics.evil.net/collect");
    assert.strictEqual(ret, "realOpen:https://metrics.evil.net/collect", "must return the real open's result");
    assert.strictEqual(env.lastXHROpen().this, xhr, "must preserve the XHR `this`");
    env.flush();
    assert.strictEqual(mergedHosts(env.posted)["metrics.evil.net"], 1);
});

test("sendBeacon is transparent and records", function () {
    const env = bootEnv();
    const r = env.win.navigator.sendBeacon("https://beacon.ads.com/b", "payload");
    assert.strictEqual(r, "realBeacon:https://beacon.ads.com/b");
    env.flush();
    assert.strictEqual(mergedHosts(env.posted)["beacon.ads.com"], 1);
});

test("non-network schemes (data:/blob:/about:) and fragments are ignored", function () {
    const env = bootEnv();
    env.win.fetch("data:text/plain,hi");
    env.win.fetch("blob:https://news.example.com/abc");
    env.win.fetch("about:blank");
    env.win.fetch("#section");
    env.flush();
    assert.deepStrictEqual(mergedHosts(env.posted), {}, "no network requests → nothing reported");
});

test("relative URLs resolve against the document host", function () {
    const env = bootEnv();
    env.win.fetch("/api/data");            // same-origin → news.example.com
    env.flush();
    assert.strictEqual(mergedHosts(env.posted)["news.example.com"], 1);
});

test("no message handler → shim is inert (does not throw, does not patch destructively)", function () {
    const env = bootEnv({ noHandler: true });
    const r = env.win.fetch("https://ads.tracker.com/x");
    // With no handler the shim returns early before wrapping; fetch is still the real one.
    assert.strictEqual(r.__from, "realFetch");
    env.flush();
    assert.deepStrictEqual(env.posted, []);
});

console.log("\n" + passed + " passed" + (process.exitCode ? "" : ", 0 failed"));
process.exit(process.exitCode || 0);
