"use strict";
//
//  brownbear-pageconsole.js
//  BrownBear
//
//  Runs in the PAGE content world (NOT the isolated BrownBear world) at document-start, in every
//  frame, to forward the page's own console.* output to native for the dashboard Logs "Page" filter.
//  It deliberately has NO access to the BrownBear isolated world or the GM bridge — it only posts log
//  lines to its own dedicated handler. Best-effort: it captures the original console functions at
//  injection time so a page reassigning console later doesn't lose the originals; if the page tampers
//  with our wrappers afterward, we simply stop capturing (we never trust the page for anything).
//
(function () {
  var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.brownbearPageConsole;
  if (!mh) { return; }

  var MAX = 4000;
  var original = {
    log: console.log, info: console.info, warn: console.warn,
    error: console.error, debug: console.debug
  };

  function render(args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      try {
        if (a === null) { parts.push("null"); }
        else if (a === undefined) { parts.push("undefined"); }
        else if (typeof a === "string") { parts.push(a); }
        else if (typeof a === "object") { parts.push(JSON.stringify(a)); }
        else { parts.push(String(a)); }
      } catch (e) {
        parts.push(String(a));
      }
    }
    var s = parts.join(" ");
    return s.length > MAX ? s.slice(0, MAX) + "…" : s;
  }

  function forward(level, args) {
    try { mh.postMessage({ level: level, message: render(args) }); } catch (e) { /* ignore */ }
  }

  function wrap(name, level) {
    var orig = original[name];
    console[name] = function () {
      forward(level, arguments);
      if (typeof orig === "function") {
        try { return orig.apply(console, arguments); } catch (e) { /* ignore */ }
      }
      return undefined;
    };
  }

  wrap("log", "info");
  wrap("info", "info");
  wrap("warn", "warn");
  wrap("error", "error");
  wrap("debug", "debug");

  // Uncaught PAGE-WORLD (MAIN) errors + promise rejections. The isolated-world runtime's error listener
  // lives in a different content world and never sees these, so a world:"MAIN" userscript — or a manager's
  // page-world bundle like ScriptCat's inject.js — throwing at top level was completely silent (the exact
  // "injects but no error, no script runs" symptom). Forward to the Page Logs. Refs captured at
  // document-start; a page tampering afterward only loses its own diagnostics.
  try {
    window.addEventListener("error", function (e) {
      var msg = (e && e.message) ? e.message : "script error";
      if (e && e.filename) { msg += " (" + e.filename + ":" + (e.lineno || 0) + ":" + (e.colno || 0) + ")"; }
      if (e && e.error && e.error.stack) { msg += "\n" + e.error.stack; }
      forward("error", ["[page] " + msg]);
    }, true);
    window.addEventListener("unhandledrejection", function (e) {
      var r = e && e.reason;
      var msg = (r && r.message) ? r.message : String(r);
      if (r && r.stack) { msg += "\n" + r.stack; }
      forward("error", ["[page] Unhandled promise rejection: " + msg]);
    }, true);
  } catch (e) { /* ignore */ }
})();
