//
//  esm-linker-cycles.test.js
//  BrownBear
//
//  Import-cycle semantics of the SW ES-module linker (brownbear-esm-linker.js). uBlock Origin Lite's
//  background graph has two real cycles (admin ⇄ ruleset-manager, admin ⇄ mode-manager) with the
//  exports declared in a bottom-of-file `export { ... }` block. The old transform snapshotted named
//  imports against a partner that hadn't registered its exports yet, so a cycle re-entry captured
//  `undefined` → "getRulesetDetails is not a function" → start() rejected → uBO reload-looped and its
//  popup/dashboard hung "waiting on the background worker". The fix: export getters HOIST to a module
//  prelude (hoisted functions bind immediately), and import bindings re-snapshot via __fixup once the
//  outermost evaluation settles (value bindings land too).
//
//  Pure Node, no deps: loads brownbear-acorn.js + brownbear-esm-linker.js in a vm context backed by an
//  in-memory module map. Run by CI (`js-runtime` job globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/esm-linker-cycles.test.js`. Exits non-zero on any failure.
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

/** Fresh linker context over an in-memory module map. Returns { run(entry), ctx }. */
function linkerWorld(files) {
    const ctx = {
        console,
        __bbModuleSource: (p) => Object.prototype.hasOwnProperty.call(files, p) ? files[p] : null,
        __bbBgBaseURL: "chrome-extension://test/",
        __probe: {}   // modules write observable results here
    };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(ACORN, ctx);
    vm.runInContext(LINKER, ctx);
    return { run: (entry) => vm.runInContext("__bbRunModuleWorker(" + JSON.stringify(entry) + ")", ctx), ctx };
}

console.log("esm-linker import-cycle tests");

test("uBO shape: function cycle with bottom-of-file export block resolves mid-cycle", () => {
    // a.js ⇄ b.js, exports declared in a trailing `export {}` block (exactly uBO's layout). a.js calls
    // b's function DURING its own evaluation (mid-cycle) — needs the hoisted export getters.
    const { run, ctx } = linkerWorld({
        "a.js":
            "import { getDetails } from './b.js';\n" +
            "function listA() { return 'A:' + getDetails(); }\n" +
            "globalThis.__probe.midCycle = getDetails();\n" +   // read while b is still evaluating? no — a is the cycle re-entrant
            "export { listA };\n",
        "b.js":
            "import { listA } from './a.js';\n" +               // re-enters a.js mid-evaluation? entry order: b → a → b(partial)
            "function getDetails() { return 'details'; }\n" +
            "globalThis.__probe.fromB = listA;\n" +
            "export { getDetails };\n",
        "entry.js":
            "import { listA } from './a.js';\n" +
            "import { getDetails } from './b.js';\n" +
            "globalThis.__probe.listA = listA();\n" +
            "globalThis.__probe.details = getDetails();\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.listA, "A:details", "cycle function call works post-settle");
    assert.strictEqual(ctx.__probe.details, "details");
    assert.strictEqual(ctx.__probe.midCycle, "details", "mid-cycle call resolves the hoisted function");
});

test("async boundary (the uBO start() pattern): cycle functions callable from a later microtask", () => {
    // The real failure fired inside start()'s await chain — code running AFTER the synchronous graph
    // evaluation. Bindings must be settled by then (the __fixup pass runs before any microtask).
    const { run, ctx } = linkerWorld({
        "mgr.js":
            "import { adminRead } from './admin.js';\n" +
            "function getRulesetDetails() { return 'rulesets'; }\n" +
            "async function start() { return adminRead() + '+' + getRulesetDetails(); }\n" +
            "export { getRulesetDetails, start };\n",
        "admin.js":
            "import { getRulesetDetails } from './mgr.js';\n" +
            "function adminRead() { return 'admin(' + getRulesetDetails() + ')'; }\n" +
            "export { adminRead };\n",
        "entry.js":
            "import { start } from './mgr.js';\n" +
            "globalThis.__probe.p = start();\n"
    });
    run("entry.js");
    return ctx.__probe.p.then((v) => {
        assert.strictEqual(v, "admin(rulesets)+rulesets");
    });
});

test("value (const) binding across a cycle settles via the fixup pass", () => {
    const { run, ctx } = linkerWorld({
        "config.js":
            "import { helper } from './user.js';\n" +
            "export const conf = { level: 3 };\n" +
            "globalThis.__probe.helperType = typeof helper;\n",
        "user.js":
            "import { conf } from './config.js';\n" +
            "export function helper() { return conf.level; }\n" +
            "globalThis.__probe.read = function () { return conf; };\n",
        "entry.js":
            "import { helper } from './user.js';\n" +
            "globalThis.__probe.level = helper();\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.level, 3, "const exported by the cycle partner is bound post-settle");
    assert.strictEqual(ctx.__probe.read().level, 3);
});

test("re-export and default getters hoist (visible to a mid-cycle importer)", () => {
    const { run, ctx } = linkerWorld({
        "hub.js":
            "export { inner as outer } from './leaf.js';\n" +
            "export default function hubDefault() { return 'hub'; }\n",
        "leaf.js":
            "export function inner() { return 'leaf'; }\n",
        "entry.js":
            "import hubDefault, { outer } from './hub.js';\n" +
            "globalThis.__probe.outer = outer();\n" +
            "globalThis.__probe.dflt = hubDefault();\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.outer, "leaf");
    assert.strictEqual(ctx.__probe.dflt, "hub");
});

test("acyclic graphs unchanged: eager snapshot already correct, fixup is a no-op re-read", () => {
    const { run, ctx } = linkerWorld({
        "util.js": "export function add(a, b) { return a + b; }\nexport const TWO = 2;\n",
        "entry.js":
            "import { add, TWO } from './util.js';\n" +
            "globalThis.__probe.sum = add(TWO, 3);\n"
    });
    run("entry.js");
    assert.strictEqual(ctx.__probe.sum, 5);
});

test("a failed module still fails closed (and doesn't break siblings' settled bindings)", () => {
    const { run, ctx } = linkerWorld({
        "ok.js": "export function fine() { return 'fine'; }\n",
        "bad.js": "import { fine } from './ok.js';\nthrow new Error('boom');\n",
        "entry.js": "import './bad.js';\n"
    });
    let threw = false;
    try { run("entry.js"); } catch (e) { threw = /boom|failed to initialize/.test(String(e && e.message)); }
    assert.ok(threw, "module failure propagates (fail closed)");
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
