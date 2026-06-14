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
      // The capture-phase 'error' event fires for TWO different things: an uncaught JS error (target ===
      // window) and a RESOURCE that failed to load (target === the <script>/<img>/<link>/<iframe> element).
      // Report a resource failure as exactly that, with its URL, instead of a mysterious "script error".
      var tgt = e && e.target;
      if (tgt && tgt !== window && tgt.tagName) {
        var res = tgt.src || tgt.href || tgt.currentSrc || (tgt.data) || "";
        forward("error", ["[page] failed to load <" + String(tgt.tagName).toLowerCase() + ">"
          + (res ? " " + res : "") + " — blocked by content blocking, offline, or 404"]);
        return;
      }
      // An uncaught JS error. Prefer, in order: a genuine message; the Error object's own name+message
      // (present even when e.message is the cross-origin placeholder for some injected scripts); else an
      // explicit, actionable note that the engine withheld the detail — NOT a bare "script error". A truly
      // cross-origin/opaque-origin throw gives no message, file, or stack; say what it is and what to do.
      var rawMsg = e && e.message;
      var placeholder = !rawMsg || rawMsg === "Script error." || rawMsg === "Script error";
      var err = e && e.error;
      var msg;
      if (!placeholder) {
        msg = rawMsg;
      } else if (err && (err.message || err.name)) {
        msg = err.name ? (err.name + ": " + (err.message || "")) : err.message;
      } else if (err) {
        msg = "uncaught " + String(err);
      } else {
        msg = "uncaught error in a cross-origin or injected script — the engine withheld its message and "
          + "stack (same-origin scripts report full detail). If this is a userscript, running it in the "
          + "isolated world (e.g. ScriptCat @inject-into content) surfaces the real error.";
      }
      if (e && e.filename) { msg += " (" + e.filename + ":" + (e.lineno || 0) + ":" + (e.colno || 0) + ")"; }
      if (err && err.stack) { msg += "\n" + err.stack; }
      forward("error", ["[page] " + msg]);
    }, true);
    window.addEventListener("unhandledrejection", function (e) {
      var r = e && e.reason;
      var msg = (r && r.message) ? r.message : String(r);
      if (r && r.stack) { msg += "\n" + r.stack; }
      forward("error", ["[page] Unhandled promise rejection: " + msg]);
    }, true);
  } catch (e) { /* ignore */ }

  // Media diagnostics — when a <video>/<audio> FAILS or STALLS, report EXACTLY why, so a "video won't
  // play / stuck at 0s" report tells a content-block apart from a decode/source/buffering problem instead
  // of guessing. This is a PURE READ: capture-phase listeners plus reads of the standard media properties
  // (error.code, networkState, readyState, currentSrc). It never touches `.src` or any accessor and never
  // writes to the element — redefining a media accessor is what stalls WebKit video, so this cannot affect
  // playback. De-duped per (element, event) via a WeakMap so a stuck player can't flood the log.
  try {
    var MEDIA_ERR = { 1: "ABORTED", 2: "NETWORK", 3: "DECODE", 4: "SRC_NOT_SUPPORTED" };
    var NET_STATE = ["EMPTY", "IDLE", "LOADING", "NO_SOURCE"];
    var seen = (typeof WeakMap === "function") ? new WeakMap() : null;

    function mediaElementFor(target) {
      if (!target || !target.tagName) { return null; }
      var tag = String(target.tagName).toUpperCase();
      if (tag === "VIDEO" || tag === "AUDIO") { return target; }
      if (tag === "SOURCE" && target.parentElement) {
        var parent = String(target.parentElement.tagName || "").toUpperCase();
        if (parent === "VIDEO" || parent === "AUDIO") { return target.parentElement; }
      }
      return null;
    }

    function alreadyLogged(media, evt) {
      if (!seen) { return false; }
      var set = seen.get(media);
      if (!set) { set = {}; seen.set(media, set); }
      if (set[evt]) { return true; }
      set[evt] = 1;
      return false;
    }

    function describeMedia(media, evt) {
      var bits = ["[media] " + String(media.tagName).toLowerCase() + " " + evt];
      try { var src = media.currentSrc || media.src || ""; if (src) { bits.push("src=" + src); } } catch (e) {}
      try {
        if (media.error) {
          bits.push("error=" + (MEDIA_ERR[media.error.code] || media.error.code)
            + (media.error.message ? " (" + media.error.message + ")" : ""));
        }
      } catch (e) {}
      try { bits.push("networkState=" + (NET_STATE[media.networkState] || media.networkState)); } catch (e) {}
      try { bits.push("readyState=" + media.readyState); } catch (e) {}
      try {
        var dur = isFinite(media.duration) ? media.duration.toFixed(2) : "?";
        bits.push("t=" + (media.currentTime || 0).toFixed(2) + "/" + dur);
      } catch (e) {}
      return bits.join(" ");
    }

    function onMediaEvent(evt) {
      return function (e) {
        var media = mediaElementFor(e && e.target);
        if (!media || alreadyLogged(media, evt)) { return; }
        forward("error", [describeMedia(media, evt)]);
      };
    }

    // 'error' = a hard failure (its MediaError code is the key signal); 'stalled'/'waiting' = the player
    // ran out of data and can't advance (the textbook "stuck at 0s / stutter"); 'abort'/'emptied' = the
    // load was cancelled. Capture phase so non-bubbling media events still reach this top-level listener.
    ["error", "stalled", "waiting", "abort", "emptied"].forEach(function (evt) {
      window.addEventListener(evt, onMediaEvent(evt), true);
    });
  } catch (e) { /* never break a page over diagnostics */ }
})();
