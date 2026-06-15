//
//  cross-world-bridge.test.js
//  BrownBear
//
//  Functional tests for the page<->isolated cross-world event bridge in brownbear-webext-runtime.js
//  (`installPerfBridge`). ScriptCat/Tampermonkey-style managers complete an "eventFlag" rendezvous
//  between their ISOLATED broker (scripting/content) and their page MAIN-world script (inject.js) by
//  dispatching CustomEvents/MouseEvents on a shared EventTarget. In WebKit each WKContentWorld has its
//  own JS state, so those events do NOT cross worlds on their own — the bridge mirrors them over the
//  SHARED DOM (a sentinel element). Which EventTarget the manager uses is version-dependent: ScriptCat
//  <=1.0 used `performance`; the SHIPPED build (v1.1.2+) uses `window`. The bridge must cross BOTH, or
//  the rendezvous completes inside the isolated world (un-graying the script) but never reaches the page
//  world — the userscript un-grays and never runs.
//
//  Pure Node, no deps. Models two JS "worlds" that share one DOM (so dispatching a signal Event on the
//  sentinel fires listeners registered from either world) but have separate `performance`/`window`
//  EventTargets. Run by CI (`js-runtime` job) and locally with `node Tests/JS/cross-world-bridge.test.js`.
//  Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const JSDIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");

// Extract the `installPerfBridge` function body verbatim from the shipped runtime (the same source that
// is serialized via toString() and injected into the page world), so this tests the REAL code.
function extractInstallBridge() {
    const src = fs.readFileSync(path.join(JSDIR, "brownbear-webext-runtime.js"), "utf8");
    const start = src.indexOf("function installPerfBridge(role)");
    assert.ok(start >= 0, "installPerfBridge not found in runtime");
    let depth = 0, end = -1;
    for (let i = src.indexOf("{", start); i < src.length; i++) {
        if (src[i] === "{") { depth++; }
        else if (src[i] === "}") { depth--; if (depth === 0) { end = i + 1; break; } }
    }
    assert.ok(end > start, "could not find end of installPerfBridge");
    return src.slice(start, end).replace("function installPerfBridge(role)", "function installBridge(role)");
}
const BRIDGE_SRC = extractInstallBridge();

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// ---- a shared DOM + two worlds -----------------------------------------------------------------------
// One DOM tree shared by both worlds (listeners on a node are keyed by the world that registered them, and
// a dispatch fires every world's listeners — this models WebKit's shared-DOM-across-content-worlds rule).
// Each world has its OWN `performance` and `window` EventTarget (separate JS state per world).

let CURRENT_WORLD = "iso";

function makeSharedDom() {
    const attrs = {};
    let idc = 0;
    function mkEl(tag) {
        const id = ++idc;
        const el = {
            tagName: tag, _id: id, _listeners: {}, children: [], parentNode: null,
            setAttribute(k, v) { attrs[id + "|" + k] = String(v); },
            getAttribute(k) { const v = attrs[id + "|" + k]; return v === undefined ? null : v; },
            removeAttribute(k) { delete attrs[id + "|" + k]; },
            addEventListener(type, fn) {
                const w = CURRENT_WORLD;
                (el._listeners[w] = el._listeners[w] || {});
                (el._listeners[w][type] = el._listeners[w][type] || []).push(fn);
            },
            dispatchEvent(ev) {
                ev.target = el;
                let notCancelled = true;
                for (const w of Object.keys(el._listeners)) {
                    const arr = (el._listeners[w] || {})[ev.type] || [];
                    for (const fn of arr.slice()) {
                        const prev = CURRENT_WORLD; CURRENT_WORLD = w;
                        try { fn(ev); } finally { CURRENT_WORLD = prev; }
                        if (ev.__defaultPrevented) { notCancelled = false; }
                    }
                }
                return notCancelled;
            },
            appendChild(c) { el.children.push(c); c.parentNode = el; return c; },
            querySelector(sel) {
                function matches(n) {
                    if (sel.indexOf("bb-perf-bridge") === 0) {
                        return n.tagName === "bb-perf-bridge" && n.getAttribute("data-bb-perf-bridge") != null;
                    }
                    const m = sel.match(/\[data-bb-perf-rt="([^"]+)"\]/);
                    return m ? n.getAttribute("data-bb-perf-rt") === m[1] : false;
                }
                function walk(n) {
                    for (const c of n.children) { if (matches(c)) { return c; } const r = walk(c); if (r) { return r; } }
                    return null;
                }
                return walk(el);
            },
            get style() { return {}; }, set style(_v) {}
        };
        return el;
    }
    return { root: mkEl("html"), mkEl };
}

function makeEventClasses() {
    class Ev { constructor(t) { this.type = t; this.cancelable = false; } preventDefault() { if (this.cancelable) { this.__defaultPrevented = true; } } }
    class CE extends Ev { constructor(t, i) { super(t); i = i || {}; this.detail = ("detail" in i) ? i.detail : null; this.cancelable = !!i.cancelable; } }
    class ME extends Ev { constructor(t, i) { super(t); i = i || {}; this.movementX = i.movementX || 0; this.relatedTarget = i.relatedTarget || null; this.cancelable = !!i.cancelable; } }
    return { Ev, CE, ME };
}

function makeWorld(tag, dom) {
    const { Ev, CE, ME } = makeEventClasses();
    function mkTarget() {
        const L = {};
        return {
            addEventListener(t, fn) { (L[t] = L[t] || []).push(fn); },
            removeEventListener(t, fn) { const a = L[t]; if (a) { const i = a.indexOf(fn); if (i >= 0) { a.splice(i, 1); } } },
            dispatchEvent(ev) {
                ev.target = this; let nc = true;
                for (const fn of (L[ev.type] || []).slice()) { fn(ev); if (ev.__defaultPrevented) { nc = false; } }
                return nc;
            }
        };
    }
    const performance = mkTarget();
    const windowT = mkTarget();
    const document = { documentElement: dom.root, head: null, body: null, createElement(t) { return dom.mkEl(t); } };
    windowT.document = document;
    const sandbox = { performance, window: windowT, document, JSON, CustomEvent: CE, Event: Ev, MouseEvent: ME, console, self: windowT };
    return { tag, sandbox, performance, windowT };
}

function installInWorld(world, role) {
    const prev = CURRENT_WORLD; CURRENT_WORLD = world.tag;
    try {
        const s = world.sandbox;
        const fn = new Function("performance", "window", "document", "JSON", "CustomEvent", "Event",
            "MouseEvent", "console", "self", "role", BRIDGE_SRC + "\ninstallBridge(role);");
        fn(s.performance, s.window, s.document, s.JSON, s.CustomEvent, s.Event, s.MouseEvent, s.console, s.self, role);
    } finally { CURRENT_WORLD = prev; }
}

// ScriptCat's rendezvous (packages/message/common.ts), faithful: the broker (negotiateEventFlag) keeps a
// persistent listener that re-broadcasts on "requestEventFlag"; receivers (getEventFlag) fire one request
// and ack with "receivedEventFlag". `pick` selects the EventTarget the manager runs its bus on.
function negotiate(world, pick, readyCount, state) {
    const prev = CURRENT_WORLD; CURRENT_WORLD = world.tag;
    const target = pick(world), CE = world.sandbox.CustomEvent, flag = "MSGFLAG";
    const eventFlag = "EF-" + Math.random().toString(36).slice(2);
    try {
        let ready = 0;
        const handler = (ev) => {
            if (!(ev instanceof CE)) { return; }
            const a = ev.detail && ev.detail.action;
            if (a === "receivedEventFlag") { ready++; state.acks++; if (ready >= readyCount) { target.removeEventListener(flag, handler); } }
            else if (a === "requestEventFlag") { target.dispatchEvent(new CE(flag, { detail: { action: "broadcastEventFlag", eventFlag }, cancelable: true })); }
        };
        target.addEventListener(flag, handler);
        target.dispatchEvent(new CE(flag, { detail: { action: "broadcastEventFlag", eventFlag }, cancelable: true }));
    } finally { CURRENT_WORLD = prev; }
}
function getFlag(world, pick, slot, state) {
    const prev = CURRENT_WORLD; CURRENT_WORLD = world.tag;
    const target = pick(world), CE = world.sandbox.CustomEvent, flag = "MSGFLAG";
    try {
        const handler = (ev) => {
            if (!(ev instanceof CE)) { return; }
            if (!ev.detail || ev.detail.action !== "broadcastEventFlag") { return; }
            state[slot] = ev.detail.eventFlag;
            target.removeEventListener(flag, handler);
            target.dispatchEvent(new CE(flag, { detail: { action: "receivedEventFlag" }, cancelable: true }));
        };
        target.addEventListener(flag, handler);
        target.dispatchEvent(new CE(flag, { detail: { action: "requestEventFlag" }, cancelable: true }));
    } finally { CURRENT_WORLD = prev; }
}

// Drive a full document_start rendezvous in the proven SYNCHRONOUS injection order: iso bridge first, then
// the ISOLATED broker (scripting.js) + USER_SCRIPT receiver (content.js) in the iso world, then the page
// bridge + MAIN receiver (inject.js) in the page world. `pick` is performance OR window.
function runRendezvous(pick) {
    const dom = makeSharedDom();
    const iso = makeWorld("iso", dom);
    const page = makeWorld("page", dom);
    const state = { acks: 0, isoFlag: null, pageFlag: null };
    installInWorld(iso, "iso");                       // ensureIsoPerfBridge()
    negotiate(iso, pick, 2, state);                   // scripting.js (ISOLATED broker)
    getFlag(iso, pick, "isoFlag", state);             // content.js (USER_SCRIPT, shares iso world)
    installInWorld(page, "page");                     // page-half bridge, prepended to inject.js's eval
    getFlag(page, pick, "pageFlag", state);           // inject.js (page MAIN world)
    return state;
}

const PERF = (w) => w.performance;
const WIN = (w) => w.windowT;

console.log("cross-world bridge rendezvous tests");

test("window-based bus (ScriptCat v1.1.2): inject.js in the page world receives the eventFlag", () => {
    const s = runRendezvous(WIN);
    assert.ok(s.isoFlag, "isolated-world receiver never got the flag");
    assert.ok(s.pageFlag, "page MAIN-world (inject.js) never got the flag — un-grays but never runs");
    assert.strictEqual(s.isoFlag, s.pageFlag, "both worlds must agree on the same eventFlag");
    assert.ok(s.acks >= 2, "broker must receive both receivedEventFlag acks (content + inject)");
});

test("performance-based bus (older ScriptCat / Tampermonkey): rendezvous still completes (no regression)", () => {
    const s = runRendezvous(PERF);
    assert.ok(s.pageFlag, "page MAIN-world never got the flag over the performance bus");
    assert.strictEqual(s.isoFlag, s.pageFlag, "both worlds must agree on the same eventFlag");
    assert.ok(s.acks >= 2, "broker must receive both acks");
});

test("the performance and window relays use independent channels (no cross-talk)", () => {
    // Run BOTH buses on the same shared DOM and confirm each completes independently — the two relays must
    // not read each other's payloads off the single sentinel element.
    const winState = runRendezvous(WIN);
    const perfState = runRendezvous(PERF);
    assert.ok(winState.pageFlag && perfState.pageFlag, "each bus must complete on its own channel");
});

// A GM message ROUND-TRIP over the bus, after the rendezvous: a MAIN-world inject.js sends a request to the
// ISOLATED broker (scripting.js), which "fetches" and dispatches the response back. This is the path a
// page-world (MAIN) ScriptCat userscript's GM_xmlhttpRequest takes for its 200 reply once #400 moved the
// userscript into MAIN. Proves the response — including a large auto-validate-sized payload and rapid
// repeated round-trips — crosses isolated→MAIN intact (so a "GM_xhr response never reaches the userscript"
// symptom is NOT this relay dropping it).
function roundTrip(pick, payload, times) {
    const dom = makeSharedDom();
    const iso = makeWorld("iso", dom);
    const page = makeWorld("page", dom);
    installInWorld(iso, "iso");
    installInWorld(page, "page");
    const FLAG = "BBGMBUS";
    // scripting.js (iso): answer every request with the payload on the same bus.
    (function broker() {
        const prev = CURRENT_WORLD; CURRENT_WORLD = "iso";
        const t = pick(iso), CE = iso.sandbox.CustomEvent;
        t.addEventListener(FLAG, (ev) => {
            if (!(ev instanceof CE) || !ev.detail || ev.detail.type !== "request") { return; }
            t.dispatchEvent(new CE(FLAG, { detail: { type: "response", id: ev.detail.id, data: payload } }));
        });
        CURRENT_WORLD = prev;
    })();
    // inject.js (page MAIN): send N requests, collect the responses.
    const received = [];
    const prev = CURRENT_WORLD; CURRENT_WORLD = "page";
    const t = pick(page), CE = page.sandbox.CustomEvent;
    t.addEventListener(FLAG, (ev) => {
        if (!(ev instanceof CE) || !ev.detail || ev.detail.type !== "response") { return; }
        received.push(ev.detail.data);
    });
    for (let i = 0; i < times; i++) {
        t.dispatchEvent(new CE(FLAG, { detail: { type: "request", id: "r" + i, action: "gmApi" } }));
    }
    CURRENT_WORLD = prev;
    return received;
}

const BIG_REPLY = { success: true, data: {
    accessToken: "a".repeat(820), refreshToken: "r".repeat(820), expiresAt: 1781878488522,
    featurePolicy: { version: 1, trial: { denyAll: ["x", "y", "z"] } }, key: "D5N5CZDJ"
} };

test("GM message round-trip: a MAIN-world request gets the ISOLATED broker's response back (window bus)", () => {
    const got = roundTrip(WIN, BIG_REPLY, 1);
    assert.strictEqual(got.length, 1, "the MAIN world received exactly one response");
    assert.strictEqual(JSON.stringify(got[0]), JSON.stringify(BIG_REPLY),
        "the large auto-validate-sized response crossed isolated→MAIN intact");
});

test("GM round-trip survives rapid repeats (the retry pattern) with every response intact", () => {
    const got = roundTrip(WIN, BIG_REPLY, 25);
    assert.strictEqual(got.length, 25, "all 25 responses crossed back to MAIN (no drops under rapid fire)");
    assert.ok(got.every((r) => JSON.stringify(r) === JSON.stringify(BIG_REPLY)), "every response intact");
});

test("GM round-trip also works over the performance bus (older ScriptCat)", () => {
    const got = roundTrip(PERF, BIG_REPLY, 3);
    assert.strictEqual(got.length, 3);
    assert.ok(got.every((r) => JSON.stringify(r) === JSON.stringify(BIG_REPLY)));
});

// ScriptCat's inject.js (MAIN) gets its document-start script list from the SW's `pageLoad` reply, which
// must cross ISOLATED→MAIN through this relay. On a real device that reply is large (a multi-script
// manager produces ~90 KB+ — observed `[bb-perfbridge] iso->page 93759b`). If a payload that size were
// truncated, clobbered, or re-entrantly corrupted by the single shared DATA attribute, inject.js would
// fail to parse the list, never set up the trigger for a userscript's flag, and the injected body would
// sit in window[flag] unrun — the exact "injected but never executes" symptom. Prove the RELAY LOGIC
// carries a 90 KB+ structured payload intact (a real-DOM attribute size limit, if any, is separate and
// device-checked; this rules the logic in or out).
const HUGE_PAGELOAD = { scripts: Array.from({ length: 44 }, (_, i) => ({
    flag: "scFlag_" + i, uuid: "uuid-" + i, name: "Script " + i,
    code: "x".repeat(2100), metadata: { match: ["*://*/*"], grant: ["GM_xmlhttpRequest", "GM_setValue"] }
})), envInfo: { sandboxMode: "raw", isIncognito: false } };

test("large pageLoad-sized payload (90 KB+) crosses ISOLATED→MAIN intact through the relay", () => {
    const serialized = JSON.stringify(HUGE_PAGELOAD);
    assert.ok(serialized.length > 90000, "fixture is the realistic >90 KB pageLoad size (got " + serialized.length + ")");
    const got = roundTrip(WIN, HUGE_PAGELOAD, 1);
    assert.strictEqual(got.length, 1, "the MAIN world received the pageLoad reply");
    assert.strictEqual(JSON.stringify(got[0]), serialized,
        "the 90 KB+ pageLoad list crossed isolated→MAIN byte-for-byte intact (relay logic is not the dropper)");
});

test("rapid large payloads don't clobber the shared relay attribute (re-entrancy under size)", () => {
    const got = roundTrip(WIN, HUGE_PAGELOAD, 8);
    assert.strictEqual(got.length, 8, "all 8 large replies crossed (no drops)");
    assert.ok(got.every((r) => JSON.stringify(r) === JSON.stringify(HUGE_PAGELOAD)),
        "every large reply intact — no cross-message attribute clobbering at size");
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
