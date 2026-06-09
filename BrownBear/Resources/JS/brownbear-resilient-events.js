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

    // A stable guard for one window method. `state.value` holds the page's replacement (if it sets one).
    // A call tries it; if it THROWS we fall back to the native. If it SUCCEEDS we mark it trusted so the
    // getter then returns the page's function DIRECTLY — restoring its identity for working instrumentation
    // that self-checks `window.addEventListener === theirWrapper`. So we only keep intercepting a wrapper
    // that is actually broken (always throws — the blocked-analytics-agent case).
    function makeGuard(displayName, state, nativeFn) {
      var guard = function () {
        var page = state.value;
        if (typeof page === "function" && page !== guard) {
          try {
            var result = page.apply(this, arguments);
            state.trusted = true;   // the page's wrapper works — stop shadowing it
            return result;
          } catch (e) { /* the page's wrapper threw (e.g. a blocked analytics agent) — use the native */ }
        }
        return nativeFn.apply(this, arguments);
      };
      try {
        var native = "function " + displayName + "() { [native code] }";
        guard.toString = function () { return native; };
      } catch (eIgnored) {}
      return guard;
    }

    function install(name, nativeFn) {
      var state = { value: null, trusted: false };
      var guard = makeGuard(name, state, nativeFn);
      try {
        Object.defineProperty(W, name, {
          configurable: true,
          get: function () {
            return (state.trusted && typeof state.value === "function") ? state.value : guard;
          },
          set: function (v) {
            state.value = (typeof v === "function" && v !== guard) ? v : null;
            state.trusted = false;   // a fresh override must prove itself before we trust it
          }
        });
      } catch (eIgnored) { /* a locked-down window; leave the native in place */ }
    }

    install("addEventListener", nativeAdd);
    install("removeEventListener", nativeRemove);
  } catch (e) { /* never break a page over diagnostics/resilience */ }
})();
