//
//  pageworld-static-equivalence.test.js
//  BrownBear
//
//  INJ-A safety net: the static document-start fast-path (brownbear-pageworld-static.js) carries a COPY of
//  brownbear-runtime.js's `PAGE_URLCHANGE_SRC` + `buildPageWorldSource`, because it runs at the page's
//  document-start before the runtime is loaded. If the two ever diverge, a grant-none page-world script
//  would behave differently depending on which path injected it — a silent, nasty bug. This test extracts
//  both copies and asserts they produce BYTE-IDENTICAL output for representative scripts (incl. the run-once
//  guard and the `@grant none` info handling). If you edit one wrapper, edit the other or this fails.
//
//  Pure Node, no deps. Run by CI (Tests/JS/*.test.js) and locally with `node Tests/JS/...`. Exits non-zero on
//  any failure.
//

"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const RUNTIME = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-runtime.js"), "utf8");
const STATIC = fs.readFileSync(path.resolve(__dirname, "../../BrownBear/Resources/JS/brownbear-pageworld-static.js"), "utf8");

let passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log("  ok   " + name); passed++; }
    catch (e) { console.log("  FAIL " + name + "\n       " + (e && e.message ? e.message : e)); failed++; }
}

// Extract `var PAGE_URLCHANGE_SRC = "..." + ... ;` (a multi-line string concatenation ending in `;`).
function extractUrlChange(src) {
    const start = src.indexOf("PAGE_URLCHANGE_SRC =");
    assert.ok(start >= 0, "PAGE_URLCHANGE_SRC not found");
    const end = src.indexOf('"})();\\n";', start);
    assert.ok(end >= 0, "PAGE_URLCHANGE_SRC terminator not found");
    return src.slice(src.indexOf("=", start) + 1, end + '"})();\\n"'.length).trim();
}

// Extract the body of `function buildPageWorldSource(data, body) { ... }` by brace matching.
function extractBuildFn(src) {
    const sig = "function buildPageWorldSource(data, body) {";
    const start = src.indexOf(sig);
    assert.ok(start >= 0, "buildPageWorldSource not found");
    let depth = 0, end = -1;
    for (let i = src.indexOf("{", start); i < src.length; i++) {
        if (src[i] === "{") depth++;
        else if (src[i] === "}") { depth--; if (depth === 0) { end = i + 1; break; } }
    }
    assert.ok(end > 0, "buildPageWorldSource end not found");
    return src.slice(start, end);
}

// Build a callable buildPageWorldSource from a file's extracted source (PAGE_URLCHANGE_SRC + the fn),
// with `_JSON` bound to JSON (the static file aliases JSON as _JSON; the runtime uses _JSON too).
function makeBuilder(src) {
    const urlChange = extractUrlChange(src);
    const fnSrc = extractBuildFn(src);
    const factory = new Function("_JSON",
        "var PAGE_URLCHANGE_SRC = " + urlChange + ";\n" + fnSrc + "\nreturn buildPageWorldSource;");
    return factory(JSON);
}

const runtimeBuild = makeBuilder(RUNTIME);
const staticBuild = makeBuilder(STATIC);

const cases = [
    { data: { uuid: "11111111-1111-1111-1111-111111111111", info: { scriptHandler: "BrownBear", uuid: "x", scriptMetaStr: "// ==UserScript==" } }, body: "console.log('hi'); document.title='x';" },
    { data: { uuid: "abc-uuid", info: {} }, body: "var a = unsafeWindow; GM_info.foo;" },
    { data: { uuid: "", info: { name: "no-uuid" } }, body: "1+1;" },                    // no uuid → no guard
    { data: { info: { weird: "chars \" ' \\ \n </script>" } }, body: "/* body */" },     // escaping + missing uuid
];

cases.forEach(function (c, i) {
    test("buildPageWorldSource output is identical (case " + i + ")", function () {
        const a = runtimeBuild(c.data, c.body);
        const b = staticBuild(c.data, c.body);
        assert.strictEqual(b, a, "static copy diverged from runtime for case " + i);
    });
});

test("the run-once guard is present when a uuid is given, absent otherwise", function () {
    const withU = runtimeBuild({ uuid: "u1", info: {} }, "x;");
    const without = runtimeBuild({ uuid: "", info: {} }, "x;");
    assert.ok(withU.indexOf("__bbRanUS") >= 0, "guard missing with uuid");
    assert.ok(without.indexOf("__bbRanUS") < 0, "guard present without uuid");
    // The static copy agrees on both.
    assert.strictEqual(staticBuild({ uuid: "u1", info: {} }, "x;"), withU);
    assert.strictEqual(staticBuild({ uuid: "", info: {} }, "x;"), without);
});

console.log("\n" + passed + " passed, " + failed + " failed");
if (failed) { process.exitCode = 1; }
