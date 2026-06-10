"use strict";
//
//  brownbear-idle-callback.js
//  BrownBear
//
//  Runs at document-start, in every frame, in BOTH the page world and our isolated content world.
//
//  WebKit ships neither requestIdleCallback nor cancelIdleCallback in ANY JavaScript world — Safari has
//  never implemented them (a long-standing gap). Chrome exposes both in every window context, so an
//  extension content script or userscript that calls requestIdleCallback (ScriptCat's content runtime
//  does) throws a bare "Can't find variable: requestIdleCallback" and dies — taking the rest of that
//  context's setup down with it. We provide the standard setTimeout-based shim (the one MDN documents) so
//  those callers behave as they do in Chrome.
//
//  NOT injected into the headless background JSContext: a service worker doesn't have requestIdleCallback
//  in Chrome either (it's a Window API), so emulating one there would be the wrong shape.
//
(function () {
  try {
    var W = (typeof window !== "undefined") ? window : this;
    if (!W || typeof W.requestIdleCallback === "function") { return; }

    // Capture the native timers now so a page that later clobbers setTimeout can't break scheduling.
    var setT = W.setTimeout;
    if (typeof setT !== "function") { return; }
    setT = setT.bind(W);
    var clearT = (typeof W.clearTimeout === "function") ? W.clearTimeout.bind(W) : function () {};
    var now = (W.Date && typeof W.Date.now === "function")
      ? function () { return W.Date.now(); }
      : function () { return +new Date(); };

    var nextHandle = 1;
    var handles = {};   // rIC id → timer id, so cancelIdleCallback can clear the pending callback

    function requestIdleCallback(callback, options) {
      if (typeof callback !== "function") { return 0; }
      var id = nextHandle++;
      var timeout = (options && typeof options.timeout === "number" && options.timeout > 0) ? options.timeout : 0;
      var start = now();
      handles[id] = setT(function () {
        delete handles[id];
        try {
          callback({
            didTimeout: timeout > 0 && (now() - start) >= timeout,
            // A small, decreasing budget — enough that callers which loop "while timeRemaining() > 0"
            // do a chunk of work and yield, rather than spinning or never running.
            timeRemaining: function () { return Math.max(0, 50 - (now() - start)); }
          });
        } catch (e) { /* a throwing idle callback must not take down the shim */ }
      }, 1);
      return id;
    }

    function cancelIdleCallback(id) {
      var t = handles[id];
      if (t !== undefined) { clearT(t); delete handles[id]; }
    }

    try {
      Object.defineProperty(W, "requestIdleCallback", { configurable: true, writable: true, value: requestIdleCallback });
      Object.defineProperty(W, "cancelIdleCallback", { configurable: true, writable: true, value: cancelIdleCallback });
    } catch (eDefine) {
      W.requestIdleCallback = requestIdleCallback;
      W.cancelIdleCallback = cancelIdleCallback;
    }
  } catch (e) { /* never break a context over a polyfill */ }
})();
