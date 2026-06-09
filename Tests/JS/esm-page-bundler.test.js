//
//  esm-page-bundler.test.js
//  BrownBear
//
//  Functional tests for the extension-page ES-module pre-linker (brownbear-esm-page-bundler.js +
//  brownbear-esm-linker.js). WKWebView won't load `<script type="module">` over our custom
//  chrome-extension:// scheme, so we pre-link a page's module graph into ONE classic script and serve
//  that instead. These tests exercise the EMITTED runtime — not just that it parses, but that it has
//  real ES-module semantics: named/default/namespace imports, live bindings, re-exports, `export *`,
//  dynamic import(), top-level await (legal in page module scripts), and import cycles (no deadlock).
//
//  Pure Node, no deps beyond the vendored acorn + linker + bundler. Run by CI (`js-runtime` job) and
//  locally with `node Tests/JS/esm-page-bundler.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const vm = require("vm");
const path = require("path");
const assert = require("assert");

const JSDIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");

// Load acorn → linker → page bundler into THIS process's global (acorn sets globalThis.__bbAcorn, the
// linker reads it at load and sets globalThis.__bbEsm, the bundler sets globalThis.__bbBundlePage).
for (const f of ["brownbear-acorn.js", "brownbear-esm-linker.js", "brownbear-esm-page-bundler.js"]) {
    // eslint-disable-next-line no-eval
    vm.runInThisContext(fs.readFileSync(path.join(JSDIR, f), "utf8"), { filename: f });
}
assert.strictEqual(typeof global.__bbBundlePage, "function", "page bundler did not install __bbBundlePage");
assert.ok(global.__bbEsm && typeof global.__bbEsm.load === "function", "esm linker did not install __bbEsm");

const BASE = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/";

let passed = 0;
let failed = 0;

/**
 * Bundle a synthetic module graph and run it in a fresh sandbox.
 * @param files   map of package-path -> source. The HTML lives at `<dir>/index.html`; entries are
 *                page-relative srcs. Paths are namespaced per case so the linker's module cache (shared
 *                across __bbBundlePage calls in one process) never collides between tests.
 * @param entries page-relative `<script src>` values, in document order.
 * @param htmlPath the page path the entries resolve against.
 * @returns the sandbox global after the bundle runs (with whatever the modules recorded on `out`).
 */
function runGraph(files, entries, htmlPath, opts) {
    global.__bbModuleSource = function (p) {
        return Object.prototype.hasOwnProperty.call(files, p) ? files[p] : null;
    };
    global.__bbBgBaseURL = BASE;
    const code = global.__bbBundlePage(JSON.stringify(entries), htmlPath, BASE);
    new vm.Script(code, { filename: htmlPath + ".bundle.js" }); // must parse as a classic script
    // The bundle console.error's a per-entry failure (the diagnostic); a case that deliberately makes an
    // entry throw passes `quietConsole` so that expected noise doesn't clutter green CI output.
    const con = (opts && opts.quietConsole) ? { error() {}, log() {}, warn() {} } : console;
    const sandbox = { out: [], console: con, Promise, Object, Array, JSON, Math, String, Number };
    sandbox.globalThis = sandbox;
    sandbox.self = sandbox;
    const ctx = vm.createContext(sandbox);
    vm.runInContext(code, ctx, { filename: htmlPath + ".bundle.js" });
    return sandbox;
}

function test(name, fn) {
    try {
        const r = fn();
        if (r && typeof r.then === "function") {
            return r.then(
                () => { passed++; console.log("  ok   " + name); },
                (e) => { failed++; console.log("  FAIL " + name + ": " + (e && e.message || e)); }
            );
        }
        passed++;
        console.log("  ok   " + name);
    } catch (e) {
        failed++;
        console.log("  FAIL " + name + ": " + (e && e.message || e));
    }
    return Promise.resolve();
}

// Microtask drain so async-runtime (TLA) assertions observe completed entries.
function tick() { return new Promise((r) => setTimeout(r, 0)); }

(async function () {
    console.log("esm-page-bundler functional tests");

    await test("named + default + namespace imports, sync graph", () => {
        const s = runGraph({
            "t1/b.js": "export const b = 41; export default 'D'; export function fn(){ return 'F'; }",
            "t1/a.js": "import dflt, { b, fn } from './b.js'; import * as ns from './b.js';" +
                       "out.push('b='+b); out.push('default='+dflt); out.push('fn='+fn());" +
                       "out.push('ns.b='+ns.b); out.push('ns.default='+ns.default);"
        }, ["a.js"], "t1/index.html");
        assert.deepStrictEqual(s.out, ["b=41", "default=D", "fn=F", "ns.b=41", "ns.default=D"]);
    });

    await test("exported object mutation is visible via shared reference (uBO's dnr.* pattern)", () => {
        // The real-world liveness extensions rely on: an exported object/array is shared by reference,
        // so a consumer (or the exporter) mutating its PROPERTIES is seen everywhere. uBO Lite's
        // ext-compat.js does exactly this (`dnr.setAllowAllRules = ...` on the exported `dnr`).
        const s = runGraph({
            "t2/store.js": "export const state = { hits: 0 }; export function bump(){ state.hits++; }",
            "t2/main.js": "import { state, bump } from './store.js';" +
                          "out.push('before='+state.hits); bump(); bump(); out.push('after='+state.hits);"
        }, ["main.js"], "t2/index.html");
        assert.deepStrictEqual(s.out, ["before=0", "after=2"]);
    });

    await test("characterization: a reassigned exported PRIMITIVE is a one-time snapshot (named-import)", () => {
        // KNOWN LIMITATION (tracked in PROGRESS.md as the next linker slice): the linker rewrites a named
        // import to `var n = tmp.n` — a value captured once — so a later reassignment of the exporter's
        // primitive `let` is NOT reflected in the importer. Namespace imports/re-exports stay live (see
        // other tests). Acyclic const/object/function imports are unaffected. Full live primitive bindings
        // need scope-aware identifier rewriting; this test pins the current boundary so a future fix is a
        // deliberate, visible change rather than an accident.
        const s = runGraph({
            "t2b/counter.js": "export let n = 0; export function inc(){ n++; }",
            "t2b/main.js": "import { n, inc } from './counter.js';" +
                           "out.push('before='+n); inc(); inc(); out.push('after='+n);"
        }, ["main.js"], "t2b/index.html");
        assert.deepStrictEqual(s.out, ["before=0", "after=0"]); // snapshot, not live (documented gap)
    });

    await test("re-export (export { x as y } from) and export *", () => {
        const s = runGraph({
            "t3/leaf.js": "export const x = 1; export const y = 2;",
            "t3/mid.js": "export { x as renamed } from './leaf.js'; export * from './leaf.js';",
            "t3/main.js": "import { renamed, x, y } from './mid.js';" +
                          "out.push('renamed='+renamed); out.push('x='+x); out.push('y='+y);"
        }, ["main.js"], "t3/index.html");
        assert.deepStrictEqual(s.out, ["renamed=1", "x=1", "y=2"]);
    });

    await test("entries share one module map (singleton imported twice)", () => {
        const s = runGraph({
            "t4/shared.js": "const id = {}; export default id;",
            "t4/e1.js": "import s from './shared.js'; globalThis.__s1 = s;",
            "t4/e2.js": "import s from './shared.js'; out.push('same='+(globalThis.__s1 === s));"
        }, ["e1.js", "e2.js"], "t4/index.html");
        assert.deepStrictEqual(s.out, ["same=true"]);
    });

    await test("top-level await: exported awaited value propagates to importer (async runtime)", async () => {
        const s = runGraph({
            "t5/tla.js": "export const v = await Promise.resolve(123);",
            "t5/main.js": "import { v } from './tla.js'; out.push('v='+v);"
        }, ["main.js"], "t5/index.html");
        await tick(); await tick();
        assert.deepStrictEqual(s.out, ["v=123"]);
    });

    await test("dynamic import() resolves a packaged module at runtime", async () => {
        const s = runGraph({
            "t6/dyn.js": "export const x = 7;",
            "t6/main.js": "const m = await import('./dyn.js'); out.push('dyn.x='+m.x);"
        }, ["main.js"], "t6/index.html");
        await tick(); await tick();
        assert.deepStrictEqual(s.out, ["dyn.x=7"]);
    });

    await test("import cycle terminates (no deadlock) — async runtime cycle guard", async () => {
        // The guarantee the async runtime adds: a cyclic graph with top-level await must NOT deadlock.
        // The async __eval pre-evaluates deps but SKIPS a dep already in progress (the cycle back-edge),
        // so evaluation always completes. (The function-deferred VALUE read through the cycle is subject
        // to the same named-import snapshot limitation characterized above — tracked as the next slice.)
        const s = runGraph({
            "t7/c1.js": "import { c2tag } from './c2.js'; await Promise.resolve();" +
                        "export const c1tag = 'c1'; out.push('c1 done');",
            "t7/c2.js": "import { c1tag } from './c1.js'; await Promise.resolve();" +
                        "export const c2tag = 'c2'; out.push('c2 done');",
            "t7/main.js": "import './c1.js'; import './c2.js'; out.push('main done');"
        }, ["main.js"], "t7/index.html");
        await tick(); await tick(); await tick(); await tick();
        // Contract: it ran to completion — every module body executed exactly once, no hang.
        assert.ok(s.out.indexOf("main done") !== -1, "cycle did not terminate: " + JSON.stringify(s.out));
        assert.strictEqual(s.out.filter((x) => x === "c1 done").length, 1, "c1 ran != once");
        assert.strictEqual(s.out.filter((x) => x === "c2 done").length, 1, "c2 ran != once");
    });

    await test("entry src resolves URL-relative to a nested HTML path", () => {
        const s = runGraph({
            "pages/app.js": "import { v } from '../lib/v.js'; out.push('v='+v);",
            "lib/v.js": "export const v = 'ok';"
        }, ["app.js"], "pages/options.html"); // app.js is relative to pages/ ; ../lib/v.js climbs out
        assert.deepStrictEqual(s.out, ["v=ok"]);
    });

    await test("missing module fails closed (throws at bundle time → raw-HTML fallback)", () => {
        let threw = false;
        try {
            runGraph({ "t9/main.js": "import { x } from './gone.js'; out.push(x);" }, ["main.js"], "t9/index.html");
        } catch (e) { threw = /module not found/.test(e && e.message || ""); }
        assert.ok(threw, "expected a 'module not found' throw for an absent dependency");
    });

    await test("sync runtime: a throwing entry does NOT block a later independent entry (Chrome parity)", () => {
        // Each <script type="module"> is its own evaluation root that only shares the module map, so in a
        // browser one entry throwing never stops a sibling. This is the uBO Lite popup "still-loading"
        // fix: if theme/fa-icons/i18n throw, popup.js (which clears the page's `loading` class) must
        // still run. The run report names the failing entry for the host's load probe.
        const s = runGraph({
            "tiso/e1.js": "out.push('e1-start'); throw new Error('boom-sync');",
            "tiso/e2.js": "out.push('e2-ran');"
        }, ["e1.js", "e2.js"], "tiso/index.html", { quietConsole: true });
        assert.deepStrictEqual(s.out, ["e1-start", "e2-ran"], "e2 must run even though e1 threw");
        const rep = s.__bbPageBundle;
        assert.ok(rep, "__bbPageBundle run report missing");
        assert.strictEqual(rep.total, 2, "report.total");
        assert.strictEqual(rep.ran, 1, "exactly one entry (e2) fully ran");
        assert.strictEqual(rep.errors.length, 1, "one entry error recorded");
        assert.ok(/tiso\/e1\.js/.test(rep.errors[0].entry), "error names the failing entry: " + rep.errors[0].entry);
        assert.ok(/boom-sync/.test(rep.errors[0].message), "error carries the thrown message");
    });

    await test("async runtime: a throwing entry does NOT block a later entry (TLA bundle)", async () => {
        // One module using top-level await flips the whole bundle to the async runtime; entry isolation
        // must hold there too (it already did — this pins it + the run report).
        const s = runGraph({
            "tisoa/e1.js": "out.push('e1a-start'); await Promise.resolve(); throw new Error('boom-async');",
            "tisoa/e2.js": "out.push('e2a-ran');"
        }, ["e1.js", "e2.js"], "tisoa/index.html", { quietConsole: true });
        await tick(); await tick(); await tick(); await tick();
        assert.ok(s.out.indexOf("e2a-ran") !== -1, "e2 must run even though e1 rejected: " + JSON.stringify(s.out));
        const rep = s.__bbPageBundle;
        assert.strictEqual(rep.total, 2, "report.total (async)");
        assert.strictEqual(rep.errors.length, 1, "one entry error recorded (async)");
        assert.ok(/boom-async/.test(rep.errors[0].message), "async error carries the message");
    });

    await test("run report marks every entry ran with no errors on a clean page", () => {
        const s = runGraph({
            "tok/e1.js": "out.push('1');",
            "tok/e2.js": "out.push('2');"
        }, ["e1.js", "e2.js"], "tok/index.html");
        const rep = s.__bbPageBundle;
        assert.strictEqual(rep.total, 2, "report.total");
        assert.strictEqual(rep.ran, 2, "both entries ran");
        assert.strictEqual(rep.errors.length, 0, "no errors on a clean run");
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    if (failed > 0) { process.exit(1); }
})();
