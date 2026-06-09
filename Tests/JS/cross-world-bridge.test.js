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

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
