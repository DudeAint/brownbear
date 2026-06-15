//
//  scriptcat-exec-probe.test.js
//
//  Guards `maybeAppendExecProbe` in brownbear-webext-runtime.js — the diagnostic that reports whether
//  ScriptCat's runner actually invokes an injected userscript body (the "injects but never runs" symptom).
//  ScriptCat compiles a body to `window['<flag>'] = function(){…}` and runs it only when its runner later
//  invokes window[flag]; the probe appends a one-shot self-check that logs `fired` vs `NOT-FIRED`.
//
//  Verifies: (1) a non-ScriptCat MAIN body is returned UNCHANGED (no behavior change for anyone else),
//  (2) a ScriptCat-signature body gets the probe appended with the correct flag, (3) the appended code is
//  valid JS that, when run, reports NOT-FIRED while window[flag] is still the function and `fired` once the
//  runner has consumed it. The whole probe is additive + guarded, so it can never break the body.
//

const assert = require("node:assert");
const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SRC = fs.readFileSync(
    path.join(__dirname, "..", "..", "BrownBear", "Resources", "JS", "brownbear-webext-runtime.js"), "utf8");

// Extract the function body verbatim from the shipped runtime, brace-matched (same technique the
// cross-world-bridge test uses for installPerfBridge), and bind `_JSON` it closes over.
function extractProbe() {
    const start = SRC.indexOf("function maybeAppendExecProbe(code)");
    assert.ok(start >= 0, "maybeAppendExecProbe not found in runtime");
    let depth = 0, end = -1;
    for (let i = SRC.indexOf("{", start); i < SRC.length; i++) {
        if (SRC[i] === "{") { depth++; } else if (SRC[i] === "}") { depth--; if (depth === 0) { end = i + 1; break; } }
    }
    assert.ok(end > start, "could not find end of maybeAppendExecProbe");
    const fnSrc = SRC.slice(start, end);
    const sandbox = { _JSON: JSON };
    vm.runInNewContext(fnSrc + "\nthis.__probe = maybeAppendExecProbe;", sandbox);
    return sandbox.__probe;
}

const maybeAppendExecProbe = extractProbe();

test("a non-ScriptCat MAIN body is returned unchanged", () => {
    const body = "(function(){ window.myThing = 1; })();";
    assert.strictEqual(maybeAppendExecProbe(body), body, "no window['flag']=function signature → untouched");
});

test("a ScriptCat-signature body gets the probe appended with the correct flag", () => {
    const body = "window['scFlag_42'] = function(){ /* obfuscated 584KB */ };";
    const out = maybeAppendExecProbe(body);
    assert.ok(out.startsWith(body), "the original body is preserved verbatim at the front");
    assert.ok(out.length > body.length, "a probe was appended");
    assert.ok(out.includes("[bb-scexec]"), "the probe logs under the [bb-scexec] tag");
    assert.ok(out.includes('"scFlag_42"'), "the probe targets the exact flag from the body");
});

test("the appended probe reports NOT-FIRED while window[flag] is still the function, fired once consumed", () => {
    const body = "window['scFlag_7'] = function(){};";
    const out = maybeAppendExecProbe(body);

    function runWith(consume) {
        const logs = [];
        let timer = null;
        const win = {};
        const sandbox = {
            window: win,
            console: { info: (m) => logs.push(m) },
            setTimeout: (fn) => { timer = fn; }   // capture the deferred check instead of waiting
        };
        vm.runInNewContext(out, sandbox);            // runs the body (sets window['scFlag_7']) + arms the probe
        assert.strictEqual(typeof win["scFlag_7"], "function", "body assigned window[flag]");
        if (consume) { delete win["scFlag_7"]; }     // simulate ScriptCat's runner invoking + deleting it
        assert.ok(timer, "the probe armed a deferred check");
        timer();
        return logs;
    }

    const stuck = runWith(false);
    assert.ok(stuck.some((l) => l.includes("scFlag_7") && l.includes("NOT-FIRED")),
        "runner never consumed window[flag] → NOT-FIRED");

    const ran = runWith(true);
    assert.ok(ran.some((l) => l.includes("scFlag_7") && l.includes("fired") && !l.includes("NOT-FIRED")),
        "runner consumed window[flag] → fired");
});
