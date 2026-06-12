"use strict";
//
//  webstore-button.test.js
//  BrownBear
//
//  Exercises brownbear-webstore.js (the in-page "Add to BrownBear" rewriter) against a mock DOM for the
//  Chrome Web Store, Edge Add-ons, and Firefox (AMO), driving the cases that used to break:
//    • it finds and relabels each store's install button to "Add to BrownBear" and enables it,
//    • a click sends the right native message ({action, url}),
//    • an SPA route change to another listing (button replaced, no reload) re-applies + re-queries,
//    • the store re-disabling the SAME button (attribute flip, no childList change) is re-corrected,
//    • applyState doesn't write when already correct (so the attribute observer can't loop).
//
//  The mock implements just the selectors the script uses. requestAnimationFrame runs synchronously;
//  the MutationObserver callback is captured so a test can simulate a mutation by calling it.
//

const fs = require("fs");
const vm = require("vm");
const path = require("path");
const assert = require("assert");

const SRC = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-webstore.js"), "utf8");

// --- Minimal DOM ---------------------------------------------------------------------------------

function El(tag, opts) {
    opts = opts || {};
    this.tagName = tag.toUpperCase();
    this._attrs = {};
    if (opts.role) { this._attrs.role = opts.role; }
    if (opts.className) { this._attrs.class = opts.className; }
    this._text = opts.text || "";
    this.disabled = false;
    this.style = {};
    this.parentElement = opts.parent || null;
    this._listeners = {};
    this._removed = false;
}
Object.defineProperty(El.prototype, "textContent", {
    get: function () { return this._text; },
    set: function (v) { this._text = String(v); }
});
El.prototype.getAttribute = function (n) { return (n in this._attrs) ? this._attrs[n] : null; };
El.prototype.setAttribute = function (n, v) { this._attrs[n] = String(v); };
El.prototype.removeAttribute = function (n) { delete this._attrs[n]; };
El.prototype.hasAttribute = function (n) { return n in this._attrs; };
El.prototype.addEventListener = function (t, fn) { (this._listeners[t] = this._listeners[t] || []).push(fn); };
El.prototype.removeEventListener = function () {};
El.prototype.dispatchEvent = function (ev) {
    ev.currentTarget = this;
    (this._listeners[ev.type] || []).forEach(function (fn) { fn(ev); });
};
El.prototype.querySelector = function () { return null; };   // test buttons hold their label directly

function classes(el) { return (el.getAttribute("class") || "").split(/\s+/).filter(Boolean); }

// Match one simple selector clause against an element.
function matchesClause(el, sel) {
    sel = sel.trim();
    var attr = sel.match(/^\[([^\]=]+)="([^"]*)"\]$/);
    if (attr) { return el.getAttribute(attr[1]) === attr[2]; }
    if (sel.charAt(0) === ".") { return classes(el).indexOf(sel.slice(1)) >= 0; }
    var tagAttr = sel.match(/^([a-z]+)\[([^\]=]+)='([^']*)'\]$/i);
    if (tagAttr) { return el.tagName === tagAttr[1].toUpperCase() && el.getAttribute(tagAttr[2]) === tagAttr[3]; }
    var tagClass = sel.match(/^([a-z]+)\.([\w-]+)$/i);
    if (tagClass) { return el.tagName === tagClass[1].toUpperCase() && classes(el).indexOf(tagClass[2]) >= 0; }
    return el.tagName === sel.toUpperCase();
}
function matches(el, selector) {
    return selector.split(",").some(function (clause) { return matchesClause(el, clause); });
}

function makeDocument(store) {
    var els = [];   // DOM order
    var doc = {
        readyState: "complete",
        body: null,
        documentElement: null,
        _store: store,
        addEventListener: function () {},
        contains: function (el) { return els.indexOf(el) >= 0 && !el._removed; },
        createTreeWalker: function () { return { nextNode: function () { return null; } }; },
        querySelector: function (sel) {
            for (var i = 0; i < els.length; i++) { if (!els[i]._removed && matches(els[i], sel)) { return els[i]; } }
            return null;
        },
        querySelectorAll: function (sel) {
            return els.filter(function (e) { return !e._removed && matches(e, sel); });
        },
        _add: function (el) { els.push(el); return el; },
        _remove: function (el) { el._removed = true; }
    };
    doc.documentElement = new El("html");
    doc.body = new El("body");
    return doc;
}

function makeContext(store, location) {
    var messages = [];
    var winListeners = {};
    var sandbox = {
        console: console,
        Promise: Promise,
        Object: Object,
        location: location,
        navigator: {},
        history: { pushState: function () {}, replaceState: function () {} },
        document: makeDocument(store),
        requestAnimationFrame: function (fn) { fn(); return 0; },
        setInterval: function () { return 0; },
        NodeFilter: { SHOW_TEXT: 4 },
        MutationObserver: function (cb) { sandbox.__mo = cb; },
        addEventListener: function (t, fn) { (winListeners[t] = winListeners[t] || []).push(fn); },
        __messages: messages,
        __reply: { query: { installed: false, name: "" } }
    };
    sandbox.MutationObserver.prototype = { observe: function () {}, disconnect: function () {} };
    sandbox.window = sandbox;
    sandbox.webkit = {
        messageHandlers: {
            brownbearWebStore: {
                postMessage: function (msg) {
                    messages.push(msg);
                    if (msg.action === "query") { return Promise.resolve(sandbox.__reply.query); }
                    if (msg.action === "install") { return Promise.resolve({ installed: true, name: "Demo" }); }
                    if (msg.action === "remove") { return Promise.resolve({ installed: false, name: "Demo" }); }
                    return Promise.resolve({});
                }
            }
        }
    };
    return sandbox;
}

function tick() { return new Promise(function (r) { setImmediate(r); }); }
function fireMutation(ctx) { if (ctx.__mo) { ctx.__mo(); } }
function clickEvent() {
    return { type: "click", preventDefault: function () {}, stopImmediatePropagation: function () {} };
}

// --- Test driver ---------------------------------------------------------------------------------

let passed = 0;
function test(name, fn) {
    return Promise.resolve().then(fn).then(
        function () { console.log("  ok   " + name); passed++; },
        function (e) { console.log("  FAIL " + name + "\n       " + (e && e.stack || e)); process.exitCode = 1; }
    );
}

const STORES = {
    chrome: {
        location: { hostname: "chromewebstore.google.com", pathname: "/detail/demo/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    href: "https://chromewebstore.google.com/detail/demo/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        button: function () { return new El("button", { text: "Add to Chrome" }); },
        nav: { pathname: "/detail/other/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
               href: "https://chromewebstore.google.com/detail/other/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
    },
    edge: {
        location: { hostname: "microsoftedge.microsoft.com", pathname: "/addons/detail/demo/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    href: "https://microsoftedge.microsoft.com/addons/detail/demo/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        button: function () { return new El("button", { text: "Get" }); },
        nav: { pathname: "/addons/detail/other/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
               href: "https://microsoftedge.microsoft.com/addons/detail/other/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
    },
    firefox: {
        location: { hostname: "addons.mozilla.org", pathname: "/en-US/firefox/addon/demo/",
                    href: "https://addons.mozilla.org/en-US/firefox/addon/demo/" },
        button: function () { return new El("button", { text: "Download Firefox", className: "Button GetFirefoxButton-button" }); },
        nav: { pathname: "/en-US/firefox/addon/other/", href: "https://addons.mozilla.org/en-US/firefox/addon/other/" }
    }
};

function loadInto(ctx) {
    var btn = ctx.document.querySelectorAll("button")[0];
    return { ctx: ctx, button: btn };
}

async function runStore(key) {
    const def = STORES[key];

    await test(key + ": relabels the install button to Add to BrownBear + queries", async () => {
        const ctx = makeContext(key, Object.assign({}, def.location));
        const btn = def.button();
        ctx.document._add(btn);
        vm.runInNewContext(SRC, ctx);
        await tick();
        assert.strictEqual(btn.textContent, "Add to BrownBear", "label rewritten");
        assert.strictEqual(btn.disabled, false, "enabled");
        assert.ok(ctx.__messages.some(m => m.action === "query" && m.url === def.location.href), "query sent with url");
        ctx.__last = btn;
        ctx.__def = def;
        STORES[key].__ctx = ctx;
    });

    await test(key + ": click installs (sends {install, url}) + flips to Remove", async () => {
        const ctx = STORES[key].__ctx;
        const btn = ctx.__last;
        btn.dispatchEvent(clickEvent());
        await tick();
        assert.ok(ctx.__messages.some(m => m.action === "install" && m.url === def.location.href), "install sent");
        assert.strictEqual(btn.textContent, "Remove from BrownBear", "flipped to Remove");
    });

    await test(key + ": SPA route change (button replaced) re-applies + re-queries", async () => {
        const ctx = STORES[key].__ctx;
        // navigate: change the url and swap in a fresh store-default button (untagged)
        ctx.location.pathname = def.nav.pathname;
        ctx.location.href = def.nav.href;
        ctx.document._remove(ctx.__last);
        const fresh = def.button();
        ctx.document._add(fresh);
        const before = ctx.__messages.filter(m => m.action === "query").length;
        fireMutation(ctx);
        await tick();
        assert.strictEqual(fresh.textContent, "Add to BrownBear", "new button rewritten");
        const after = ctx.__messages.filter(m => m.action === "query").length;
        assert.ok(after === before + 1, "re-queried for the new listing");
        ctx.__last = fresh;
    });

    await test(key + ": store re-disabling the same button is re-corrected", async () => {
        const ctx = STORES[key].__ctx;
        const btn = ctx.__last;
        btn.disabled = true;
        btn.setAttribute("disabled", "");
        btn.textContent = "Add to " + (key === "edge" ? "Edge" : key === "firefox" ? "Firefox" : "Chrome");
        fireMutation(ctx);
        await tick();
        assert.strictEqual(btn.disabled, false, "re-enabled");
        assert.strictEqual(btn.textContent, "Add to BrownBear", "re-labelled");
    });

    await test(key + ": applyState is a no-op when already correct (no loop)", async () => {
        const ctx = STORES[key].__ctx;
        const btn = ctx.__last;
        // Already in the desired state; a mutation tick must not toggle attributes back and forth.
        const beforeDisabledAttr = btn.hasAttribute("disabled");
        fireMutation(ctx);
        await tick();
        assert.strictEqual(btn.textContent, "Add to BrownBear");
        assert.strictEqual(btn.hasAttribute("disabled"), beforeDisabledAttr);
    });
}

async function main() {
    for (const key of Object.keys(STORES)) {
        console.log(key + " store:");
        await runStore(key);
    }
    console.log("\n" + passed + " passed");
}

main();
