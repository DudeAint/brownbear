//
//  esm-linker-multi-entry.test.js
//  BrownBear
//
//  An MV2 background PAGE can carry MORE THAN ONE `<script type="module">` (Sidebery's background.html
//  has a locale-dictionary module BEFORE the real background.js). A browser runs each in document order,
//  each its own module graph but SHARING the global object + the module cache. BrownBear's background
//  boot used to link only the FIRST module entry, so Sidebery ran the dict and left the actual background
//  dead — the sidebar could never connect to it. The fix calls __bbRunModuleWorker once per entry in the
//  SAME context. This test pins that contract on the linker: two sequential entries share globals and the
//  registry, and one entry throwing does not stop the next.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with `node Tests/JS/esm-linker-multi-entry.test.js`.
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

/** Fresh linker context over an in-memory module map. `runEntries` runs each entry in order in the SAME
 *  context (what the background boot does for a page's multiple `<script type="module">` tags). */
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
    return {
        runEntries: (entries) => {
            for (const e of entries) { vm.runInContext("__bbRunModuleWorker(" + JSON.stringify(e) + ")", ctx); }
        },
        ctx
    };
}

console.log("esm-linker multi-entry (MV2 background page) tests");

test("two module entries run in order and share the global object (dict before background)", () => {
    const { runEntries, ctx } = linkerWorld({
        // entry 1: a locale dictionary that publishes a global (Sidebery's dict.common.js shape)
        "dict.js": "globalThis.__probe.dict = { hello: 'bonjour' };\nglobalThis.__probe.order = (globalThis.__probe.order || '') + 'dict;';\n",
        // entry 2: the real background — reads the global the first entry set
        "background.js": "globalThis.__probe.order = (globalThis.__probe.order || '') + 'bg;';\n" +
            "globalThis.__probe.greeting = (globalThis.__probe.dict && globalThis.__probe.dict.hello) || 'MISSING';\n"
    });
    runEntries(["dict.js", "background.js"]);   // document order
    assert.strictEqual(ctx.__probe.order, "dict;bg;", "entries ran in document order");
    assert.strictEqual(ctx.__probe.greeting, "bonjour", "the background sees the dict module's global (shared scope)");
});

test("entries share the module registry (a module imported by both evaluates once)", () => {
    const { runEntries, ctx } = linkerWorld({
        "shared.js": "globalThis.__probe.evalCount = (globalThis.__probe.evalCount || 0) + 1;\nexport const tag = {};",
        "a.js": "import { tag } from './shared.js'; globalThis.__probe.a = tag;",
        "b.js": "import { tag } from './shared.js'; globalThis.__probe.b = tag;"
    });
    runEntries(["a.js", "b.js"]);
    assert.strictEqual(ctx.__probe.evalCount, 1, "the shared module evaluated exactly once across both entries");
    assert.strictEqual(ctx.__probe.a, ctx.__probe.b, "both entries got the SAME exported object (one registry)");
});

test("a throwing first entry does not prevent the next from running (independent module scripts)", () => {
    const { runEntries, ctx } = linkerWorld({
        "bad.js": "globalThis.__probe.badRan = true;\nthrow new Error('bad-entry');",
        "good.js": "globalThis.__probe.goodRan = true;"
    });
    // The Swift boot loop logs + clears a thrown entry and continues; here we mirror that (run each in a
    // try) and assert the good entry still ran.
    for (const e of ["bad.js", "good.js"]) {
        try { runEntries([e]); } catch (eIgnored) { /* boot loop clears the exception and continues */ }
    }
    assert.strictEqual(ctx.__probe.badRan, true, "the throwing entry started");
    assert.strictEqual(ctx.__probe.goodRan, true, "the next entry still ran after the throw");
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
