//
//  pageworld-notification.test.js
//  BrownBear
//
//  Tests GM_notification in the PAGE world (brownbear-runtime.js pageWorldGMClient + the vault).
//  GM_notification is BOTH a reply and a stream: the client registers a vault handler (minted streamId)
//  for the click/close events, then posts GM_notification via the vault's request→REPLY channel
//  (call.reply) to get the native notification id back (for .remove()). When the banner is tapped or
//  dismissed, native streams window.__bbPageXHR(streamId, "click"|"close") to fire the script's
//  onclick / ondone+onclose. Same minted-id machinery as the other page-world streaming APIs.
//
//  Pure Node, no deps. Run by CI (js-runtime job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/pageworld-notification.test.js`. Exits non-zero on any failure.
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

function bootForNotifCode(source) {
    const calls = [];
    function postMessage(msg) {
        calls.push(msg);
        if (msg.api === "getScripts") {
            return Promise.resolve([{
                token: "tok-notif", name: "notif", uuid: "12121212-1212-1212-1212-121212121212",
                runAt: "document-start", grants: ["GM_notification"], grantNone: false, noFrames: false,
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

// Mock vault: records writes, the reply request (and lets the test settle it), and the streaming handler.
function runPageWithVault(code, replyValue) {
    const relayed = [];
    const replies = [];
    const handlers = {};
    let mintCount = 0;
    const vault = function (token, api, payload) { relayed.push({ token, api, payload }); return Promise.resolve(null); };
    vault.xhr = function (handler) { mintCount += 1; const id = "pwx_" + mintCount + "_beadface"; handlers[id] = handler; return id; };
    vault.xhrDone = function (id) { delete handlers[id]; };
    vault.reply = function (token, api, payload, cb, errcb) {
        replies.push({ token, api, payload, cb, errcb });
        // Settle synchronously with the native reply (e.g. { id, shown }).
        if (replyValue && cb) { cb(replyValue); }
        else if (!replyValue && errcb) { errcb("no reply"); }
    };
    const pageWin = {
        document: { head: { appendChild() {} }, documentElement: { appendChild() {} },
            createElement() { return { setAttribute() {}, appendChild() {} }; } },
        JSON, Object, Array, Promise, console, __obs: {}, __bbPageGM: vault
    };
    pageWin.window = pageWin; pageWin.self = pageWin; pageWin.top = pageWin;
    const ctx = { window: pageWin, document: pageWin.document, console, globalThis: undefined };
    ctx.globalThis = ctx;
    vm.createContext(ctx); vm.runInContext(code, ctx);
    return { pageWin, relayed, replies,
             fire: (id, type) => handlers[id] && handlers[id](type, {}),
             isRegistered: (id) => !!handlers[id] };
}

function injectCode(calls) { return calls.filter((c) => c.api === "injectPageWorld")[0].payload.code; }

(async function main() {
    console.log("GM_notification in the page world (vault reply id + native→page click/close)");

    const body = [
        "window.__obs.clicked = 0; window.__obs.done = 0; window.__obs.closed = 0; window.__obs.created = null;",
        "window.__obs.ctl = GM_notification({",
        "  title: 'Hi', text: 'there',",
        "  onclick: function () { window.__obs.clicked += 1; },",
        "  ondone: function () { window.__obs.done += 1; },",
        "  onclose: function () { window.__obs.closed += 1; },",
        "  oncreate: function (id) { window.__obs.created = id; }",
        "});"
    ].join("\n");
    const calls = bootForNotifCode(body);
    await new Promise((r) => setTimeout(r, 10));

    test("a granted GM_notification script routes to the page world", () => {
        assert.strictEqual(calls.filter((c) => c.api === "injectPageWorld").length, 1);
    });

    const { pageWin, replies, fire, isRegistered } = runPageWithVault(injectCode(calls), { id: "gm-notif-xyz", shown: true });
    const obs = pageWin.__obs;
    const req = replies.filter((r) => r.api === "GM_notification")[0];

    test("the notification request goes through the vault reply channel (token + details + streamId)", () => {
        assert.ok(req, "one GM_notification reply request");
        assert.strictEqual(req.token, "tok-notif", "authenticated with the script's token");
        assert.strictEqual(req.payload.details.title, "Hi");
        assert.strictEqual(req.payload.details.text, "there");
        assert.strictEqual(req.payload.wantClick, true, "wantClick true (the script set callbacks)");
        assert.ok(/^pwx_/.test(req.payload.streamId), "carries the vault-minted streamId");
    });
    test("oncreate fires with the native id from the reply", () => {
        assert.strictEqual(obs.created, "gm-notif-xyz");
    });
    test("a streaming handler is registered for native to deliver click/close to", () => {
        assert.ok(isRegistered(req.payload.streamId), "vault.xhr registered a handler keyed by the streamId");
    });

    // Native streams a click → onclick fires; the handler persists (click doesn't reap).
    fire(req.payload.streamId, "click");
    test("a native click fires onclick (and the handler persists)", () => {
        assert.strictEqual(obs.clicked, 1);
        assert.ok(isRegistered(req.payload.streamId), "still registered after a click");
    });

    // Native streams a close → ondone + onclose fire and the handler is reaped.
    fire(req.payload.streamId, "close");
    test("a native close fires ondone + onclose and reaps the handler", () => {
        assert.strictEqual(obs.done, 1);
        assert.strictEqual(obs.closed, 1);
        assert.ok(!isRegistered(req.payload.streamId), "handler reaped after close");
    });

    // control.remove() relays GM_notificationClear with the native id + reaps the handler.
    {
        const body2 = [
            "var c = GM_notification({ text: 'x', onclick: function(){} });",
            "window.__obs.remove = function () { c.remove(); };"
        ].join("\n");
        const calls2 = bootForNotifCode(body2);
        await new Promise((r) => setTimeout(r, 10));
        const r2 = runPageWithVault(injectCode(calls2), { id: "gm-notif-rm", shown: true });
        r2.pageWin.__obs.remove();
        test("control.remove() relays GM_notificationClear with the native id", () => {
            assert.ok(r2.relayed.some((r) => r.api === "GM_notificationClear" && r.payload.id === "gm-notif-rm"),
                "GM_notificationClear relayed with the native id");
        });
    }

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed) { process.exitCode = 1; }
})();
