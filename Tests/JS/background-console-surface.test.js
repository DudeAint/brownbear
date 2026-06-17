//
//  background-console-surface.test.js
//  BrownBear
//
//  Chrome's headless service-worker `console` exposes the full standard surface, not just
//  log/info/warn/error/debug/trace. Store loggers capture e.g. `console.group.bind(console)` at module
//  load with no existence guard, so a missing method throws "Cannot read properties of undefined
//  (reading 'bind')" and aborts boot (seen on extension "Snap&Read"). Our background shim
//  (brownbear-webext-background.js) rebuilds console from scratch in a JSContext, so it must carry the
//  whole surface. This boots the REAL background shim and asserts every standard method is a callable
//  function, that the textual ones route through __bb_log with the right level, that .bind(console)
//  works on the grouping family (the exact operation the crashing logger performs), and that assert
//  only logs on a falsy condition.
//
//  Pure Node. Run by CI (globs Tests/JS/*.test.js) and locally with
//  `node Tests/JS/background-console-surface.test.js`.
//

"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const DIR = path.resolve(__dirname, "../../BrownBear/Resources/JS");
const EXT_ID = "consoletestidaaaaaaaaaaaaaaaaaaaa";

// Boot the real shim with a capturing __bb_log so we can see exactly what each console method routes.
function bootBackground() {
    const logs = [];   // { level, text }
    const sb = {};
    sb.globalThis = sb; sb.self = sb;
    // NOTE: do NOT pre-seed sb.console — the shim overwrites globalThis.console, and we want to be sure
    // the watchdog/other init code runs against the shim's console, not Node's, exactly as on device.
    Object.assign(sb, { JSON, Math, Date, Object, Array, Symbol, Promise, String, Number, Boolean, RegExp,
        Map, Set, Error, TextEncoder, TextDecoder, URL, URLSearchParams });
    sb.setTimeout = setTimeout; sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    const nullCb = (...a) => { const c = a[a.length - 1]; if (typeof c === "function") { c(JSON.stringify(null)); } };
    for (const n of ["__bb_send_message", "__bb_storage_get", "__bb_storage_set",
        "__bb_storage_remove", "__bb_storage_clear", "__bb_tabs", "__bb_management", "__bb_dnr",
        "__bb_action", "__bb_scripting", "__bb_permissions", "__bb_fetch", "__bb_alarm_create",
        "__bb_alarm_clear", "__bb_alarm_clear_all", "__bb_alarm_get", "__bb_alarm_get_all"]) { sb[n] = nullCb; }
    sb.__bb_log = (level, text) => { logs.push({ level: String(level), text: String(text) }); };
    sb.__bb_set_timeout = (fn, ms, r) => (r ? setInterval(fn, ms || 0) : setTimeout(fn, ms || 0));
    sb.__bb_clear_timer = (id) => { clearTimeout(id); clearInterval(id); };
    sb.__bbBgExtId = EXT_ID; sb.__bbBgBaseURL = `chrome-extension://${EXT_ID}/`;
    sb.__bbBgManifest = JSON.stringify({ manifest_version: 3, name: "t", version: "1",
        background: { service_worker: "sw.js" }, permissions: [] });
    sb.__bbBgMessages = "{}"; sb.__bbUserAgent = "UA"; sb.__bbLanguage = "en-US";
    vm.createContext(sb);
    vm.runInContext(fs.readFileSync(path.join(DIR, "brownbear-webext-background.js"), "utf8"), sb,
        { filename: "brownbear-webext-background.js" });
    return { sb, logs };
}

let passed = 0, failed = 0;
const test = (n, fn) => { try { fn(); console.log("  ok   " + n); passed++; } catch (e) { console.log("  FAIL " + n + "\n       " + (e && e.message ? e.message : e)); failed++; } };

(function main() {
    const { sb, logs } = bootBackground();
    const con = sb.console;

    // Table of every method Chrome's console exposes that we shim, and the level the textual ones map to
    // (null = a no-op that must not log). This is the contract a store logger relies on.
    const SURFACE = [
        { name: "log", level: "info" },
        { name: "info", level: "info" },
        { name: "warn", level: "warn" },
        { name: "error", level: "error" },
        { name: "debug", level: "debug" },
        { name: "trace", level: "debug" },
        { name: "group", level: "info" },
        { name: "groupCollapsed", level: "info" },
        { name: "groupEnd", level: null },
        { name: "dir", level: "info" },
        { name: "dirxml", level: "info" },
        { name: "table", level: "info" },
        { name: "count", level: null },
        { name: "countReset", level: null },
        { name: "clear", level: null },
        { name: "time", level: null },
        { name: "timeEnd", level: null },
        { name: "timeLog", level: null }
    ];

    test("every standard console method is a callable function (none read undefined)", () => {
        for (const { name } of SURFACE) {
            assert.strictEqual(typeof con[name], "function", `console.${name} must be a function`);
        }
        assert.strictEqual(typeof con.assert, "function", "console.assert must be a function");
    });

    test("the grouping family survives .bind(console) — the exact op the crashing logger performs", () => {
        // de-minified background-service.js: n.group = console.group.bind(console), etc. This is the line
        // that threw on device when console.group was undefined.
        const bound = {
            group: con.group.bind(con),
            groupCollapsed: con.groupCollapsed.bind(con),
            groupEnd: con.groupEnd.bind(con),
            dir: con.dir.bind(con),
            table: con.table.bind(con),
            trace: con.trace.bind(con)
        };
        for (const k of Object.keys(bound)) {
            assert.strictEqual(typeof bound[k], "function", `${k}.bind(console) returns a function`);
            bound[k]("x");   // must not throw
        }
    });

    test("textual methods route through __bb_log at the documented level", () => {
        for (const { name, level } of SURFACE) {
            const before = logs.length;
            con[name]("hello", "world");
            const added = logs.slice(before);
            if (level === null) {
                assert.strictEqual(added.length, 0, `console.${name} is a no-op and must not log`);
            } else {
                assert.strictEqual(added.length, 1, `console.${name} logs exactly once`);
                assert.strictEqual(added[0].level, level, `console.${name} logs at ${level}`);
                assert.strictEqual(added[0].text, "hello world", `console.${name} joins args with a space`);
            }
        }
    });

    test("console.assert logs an error only when the condition is falsy (Chrome semantics)", () => {
        const before = logs.length;
        con.assert(true, "should not appear");
        con.assert(1 === 1, "also not");
        assert.strictEqual(logs.length, before, "truthy assert is silent");
        con.assert(false, "boom", 42);
        const added = logs.slice(before);
        assert.strictEqual(added.length, 1, "falsy assert logs once");
        assert.strictEqual(added[0].level, "error", "assert failures log at error level");
        assert.strictEqual(added[0].text, "Assertion failed: boom 42", "assert message includes joined trailing args");
    });

    test("console.assert with no message still logs the prefix on a falsy condition", () => {
        const before = logs.length;
        con.assert(0);
        const added = logs.slice(before);
        assert.strictEqual(added.length, 1, "bare falsy assert logs");
        assert.strictEqual(added[0].text, "Assertion failed: ", "prefix present with empty joined tail");
    });

    test("malformed / hostile arguments never throw (fail closed at the JS boundary)", () => {
        // A logger may hand us a circular object, a thrown-on-stringify object, undefined, symbols, etc.
        const circular = {}; circular.self = circular;
        const evil = { toJSON() { throw new Error("nope"); } };
        const cases = [
            () => con.log(circular),
            () => con.group(evil),
            () => con.dir(undefined, null, Symbol("s")),
            () => con.table(),                       // zero args
            () => con.info(123, true, { a: 1 }),
            () => con.assert(circular),              // truthy object → no log, no throw
            () => con.groupCollapsed(evil, circular)
        ];
        for (let i = 0; i < cases.length; i++) {
            assert.doesNotThrow(cases[i], `case ${i} must not throw on malformed input`);
        }
    });

    test("the full standard surface is present (no method silently missing)", () => {
        const required = ["log", "info", "warn", "error", "debug", "trace", "group", "groupCollapsed",
            "groupEnd", "dir", "dirxml", "table", "assert", "count", "countReset", "clear",
            "time", "timeEnd", "timeLog"];
        for (const name of required) {
            assert.ok(name in con && typeof con[name] === "function", `console.${name} is missing`);
        }
    });

    console.log("\n" + passed + " passed, " + failed + " failed");
    process.exit(failed === 0 ? 0 : 1);   // the booted bg shim keeps timers alive; force exit
})();
