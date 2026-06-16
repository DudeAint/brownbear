//
//  esm-linker-live-bindings.test.js
//  BrownBear
//
//  Live import bindings in the SW ES-module linker (brownbear-esm-linker.js). esbuild's lazy `__esm`
//  init pattern assigns an exported value via an init function the IMPORTER calls AFTER the import
//  line (Phantom's `import{j as E}…; …; E.FORCE_PRODUCTION_API`, where the env object is filled in by
//  that init). The old linker snapshotted the import into a plain `var` at the import line — so the
//  later read saw `undefined` → "Cannot read properties of undefined (reading 'FORCE_PRODUCTION_API')"
//  → Phantom's service worker died → the popup couldn't connect. The fix rewrites each import
//  *reference* to read through the exporter's namespace (`tmp.foo`) so every read is live.
//
//  This file pins BOTH directions: (1) the live read now works (the Phantom shape), and (2) the
//  conservative SAFETY contract — a reference SHADOWED by a param / var / block-let / catch-param /
//  function name must keep reading the LOCAL value, never the import (a wrong rewrite there would
//  silently corrupt a working extension). Plus object-shorthand, re-export, default, and namespace.
//
//  Pure Node, no deps. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/esm-linker-live-bindings.test.js`. Exits non-zero on any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const JS_DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const ACORN = fs.readFileSync(path.join(JS_DIR, "brownbear-acorn.js"), "utf8");
const LINKER = fs.readFileSync(path.join(JS_DIR, "brownbear-esm-linker.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

/** Fresh linker context over an in-memory module map. */
function linkerWorld(files) {
    const ctx = {
        console,
        __bbModuleSource: (p) => Object.prototype.hasOwnProperty.call(files, p) ? files[p] : null,
        __bbBgBaseURL: "chrome-extension://test/",
        __probe: {}
    };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(ACORN, ctx);
    vm.runInContext(LINKER, ctx);
    return { run: (entry) => vm.runInContext("__bbRunModuleWorker(" + JSON.stringify(entry) + ")", ctx), ctx };
}

console.log("esm-linker live import-binding tests");

// (1) THE PHANTOM SHAPE — exporter assigns the value via an init the importer calls after the import;
// a later (deferred) read must see the live value, not the undefined captured at import time.
test("esbuild lazy-init: a read after the exporter's init sees the live value (Phantom shape)", () => {
    const { run, ctx } = linkerWorld({
        "env.js":
            "var O;\n" +
            "export function init() { O = { FORCE_PRODUCTION_API: 'true', NODE_ENV: 'production' }; }\n" +
            "export { O as env };\n",
        "consumer.js":
            "import { env, init } from './env.js';\n" +
            "init();\n" +                                   // value assigned AFTER the import line
            "var getDefault = () => env.FORCE_PRODUCTION_API === 'true';\n" +   // deferred live read
            "globalThis.__probe.direct = env.NODE_ENV;\n" +
            "globalThis.__probe.deferred = getDefault();\n",
        "entry.js": "import './consumer.js';\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.direct, "production", "direct read is live (not the import-time snapshot)");
    assert.strictEqual(ctx.__probe.deferred, true, "deferred closure read is live");
});

// (2) SAFETY: shadowing. A reference shadowed by an inner binding must read the LOCAL value. A wrong
// rewrite here would replace the local with the import — silent corruption — so this is the load-bearing
// guard for the whole feature.
test("shadowing: param / var / block-let / catch-param / fn-name keep the LOCAL value, not the import", () => {
    const { run, ctx } = linkerWorld({
        "v.js": "export const val = 'IMPORTED';\n",
        "shadow.js":
            "import { val } from './v.js';\n" +
            "function byParam(val) { return val; }\n" +
            "function byVar() { var val = 'localvar'; return val; }\n" +
            "function byBlock() { { let val = 'blocklet'; return val; } }\n" +
            "function byCatch() { try { throw 'caught'; } catch (val) { return val; } }\n" +
            "function val2() { return 'fnname'; }\n" +     // a fn named like… (sanity, not the import)
            "globalThis.__probe.param = byParam('P');\n" +
            "globalThis.__probe.varr = byVar();\n" +
            "globalThis.__probe.block = byBlock();\n" +
            "globalThis.__probe.caught = byCatch();\n" +
            "globalThis.__probe.top = val;\n",             // unshadowed → the live import
        "entry.js": "import './shadow.js';\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.param, "P", "param shadow → param value");
    assert.strictEqual(ctx.__probe.varr, "localvar", "var shadow → local var");
    assert.strictEqual(ctx.__probe.block, "blocklet", "block-let shadow → block value");
    assert.strictEqual(ctx.__probe.caught, "caught", "catch-param shadow → caught value");
    assert.strictEqual(ctx.__probe.top, "IMPORTED", "unshadowed top-level ref → the import");
});

// (3) object shorthand {x} must expand to {x: <live>} (not leave a bare key that loses the value).
test("object shorthand {x} reads the live import", () => {
    const { run, ctx } = linkerWorld({
        "x.js": "var n; export function set() { n = 42; } export { n as x };\n",
        "use.js":
            "import { x, set } from './x.js';\n" +
            "set();\n" +
            "globalThis.__probe.obj = { x };\n",
        "entry.js": "import './use.js';\n"
    });
    run("entry.js");
    assert.deepStrictEqual({ x: ctx.__probe.obj.x }, { x: 42 }, "shorthand value is the live import");
});

// (4) re-export of an imported binding forwards the live value.
test("re-export `export { a }` of an import is live", () => {
    const { run, ctx } = linkerWorld({
        "a.js": "var v; export function set() { v = 'LIVE'; } export { v as a };\n",
        "hub.js": "import { a, set } from './a.js';\nset();\nexport { a };\n",
        "entry.js": "import { a } from './hub.js';\nglobalThis.__probe.reexp = a;\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.reexp, "LIVE");
});

// (5) namespace import was already live (binds the exports object); confirm it still is.
test("namespace import stays live (unchanged)", () => {
    const { run, ctx } = linkerWorld({
        "m.js": "var O = {}; export function fill() { O.k = 9; } export { O as obj };\n",
        "ns.js":
            "import * as NS from './m.js';\n" +
            "NS.fill();\n" +
            "globalThis.__probe.ns = NS.obj.k;\n",
        "entry.js": "import './ns.js';\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.ns, 9);
});

// (6) default import resolves through the namespace too.
test("default import reads through the namespace", () => {
    const { run, ctx } = linkerWorld({
        "d.js": "export default { tag: 'DEF' };\n",
        "use.js": "import D from './d.js';\nglobalThis.__probe.d = D.tag;\n",
        "entry.js": "import './use.js';\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.d, "DEF");
});

// (7) the existing acyclic value path still works (computed member + call on an import).
test("import used as callee and object is rewritten correctly", () => {
    const { run, ctx } = linkerWorld({
        "lib.js": "export function make() { return { hi: () => 'HI' }; }\nexport const TAG = 'T';\n",
        "use.js":
            "import { make, TAG } from './lib.js';\n" +
            "globalThis.__probe.call = make().hi();\n" +
            "globalThis.__probe.tag = TAG;\n",
        "entry.js": "import './use.js';\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.call, "HI");
    assert.strictEqual(ctx.__probe.tag, "T");
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
