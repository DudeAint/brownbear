"use strict";
//
//  brownbear-resilient-events.js
//  BrownBear
//
//  Runs in the PAGE world at document-start, in every frame, BEFORE any page script. Some pages replace
//  `window.addEventListener` / `removeEventListener` with an instrumentation wrapper — analytics agents
//  (New Relic's `nrWrapper` is the canonical case) do this in an inline loader, then finish initializing
//  from an external script. When that external script is BLOCKED or fails to load, the wrapper is left
//  half-initialized and THROWS on every call ("addEventListener is not a function"), poisoning the page's
//  own global — which breaks the page's code AND any userscript that registers a listener.
//
//  We can't make the blocked agent load, but we keep addEventListener WORKING: capture the native methods
//  now (before any page script runs) and intercept the page's later override. When the patched method is
//  called, we TRY the page's wrapper first (so working instrumentation is preserved) and, only if it
//  throws, fall back to the native. For a page that never overrides window.addEventListener (the vast
//  majority) this is a transparent pass-through to the native. Stable function identity + a native-looking
//  `toString` so it doesn't trip identity/fingerprint checks. Scoped to the WINDOW's own methods (the ones
//  analytics agents clobber); element/document listeners go through EventTarget.prototype, left untouched.
//
(function () {
  try {
    var W = window;
    if (W.__bbResilientEvents) { return; }
    var ET = W.EventTarget;
    if (!ET || !ET.prototype) { return; }
    var nativeAdd = ET.prototype.addEventListener;
    var nativeRemove = ET.prototype.removeEventListener;
    if (typeof nativeAdd !== "function") { return; }
    W.__bbResilientEvents = 1;

    // Use `this` for the native call only when it's a real EventTarget — a broken wrapper commonly forwards
    // a bogus `this` (its uninitialized internal), and the native then throws "Can only call addEventListener
    // on instances of EventTarget". Default to the window (the owner of the methods we guard).
    function realTarget(self, guard) {
      try { if (self && self !== guard && self instanceof ET) { return self; } } catch (e) {}
      return W;
    }

    // A stable guard for one window method. `state.value` is the page's override, if it set one. A call
    // tries the override first (so WORKING instrumentation is preserved) and falls back to the native when
    // the override throws OR when we'd re-enter it. The re-entrancy guard is essential: an instrumentation
    // wrapper captures the "original" (which is THIS guard) and calls back into it — without the guard that
    // recurses forever. On re-entry we go straight to the native, with a real-EventTarget `this`.
    function makeGuard(displayName, state, nativeFn) {
      var guard = function () {
        var page = state.value;
        if (typeof page === "function" && page !== guard && !state.inCall) {
          state.inCall = true;
          try { return page.apply(this, arguments); }
          catch (e) { /* the override threw (e.g. a blocked analytics agent) — use the native */ }
          finally { state.inCall = false; }
        }
        return nativeFn.apply(realTarget(this, guard), arguments);
      };
      try {
        var native = "function " + displayName + "() { [native code] }";
        guard.toString = function () { return native; };
      } catch (eIgnored) {}
      return guard;
    }

    function install(name, nativeFn) {
      var state = { value: null, inCall: false };
      var guard = makeGuard(name, state, nativeFn);
      try {
        Object.defineProperty(W, name, {
          configurable: true,
          get: function () { return guard; },
          set: function (v) { state.value = (typeof v === "function" && v !== guard) ? v : null; }
        });
      } catch (eIgnored) { /* a locked-down window; leave the native in place */ }
    }

    install("addEventListener", nativeAdd);
    install("removeEventListener", nativeRemove);
  } catch (e) { /* never break a page over diagnostics/resilience */ }
})();
