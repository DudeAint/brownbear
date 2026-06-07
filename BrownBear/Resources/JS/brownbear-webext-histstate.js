//
// brownbear-webext-histstate.js
//
// A PAGE-world hook that reports same-document history changes to native so
// chrome.webNavigation.onHistoryStateUpdated can fire on iOS. WKWebView's navigation delegate never
// reports pushState/replaceState/popstate (an SPA route change doesn't hit didCommit/didFinish), so
// we wrap the two History methods and listen for popstate, posting the resulting location to the
// brownbearWebextHistory message handler (PAGE world). Native validates it (main frame, http(s)) and
// emits the webNavigation event, gated on the extension's "webNavigation" permission.
//
// This lives in the PAGE world deliberately: history.pushState is a page-scope API, and the page must
// see the same (wrapped) function it would otherwise call. The wrappers are transparent — they invoke
// the original method first, then report — so they never change page behavior. We capture the original
// references at document-start, before page scripts run, so a page that later clobbers History can't
// stop the reporting (and can't trick us into reporting a stale function).
//

(function () {
  "use strict";
  if (window.__brownbearWebextHist) { return; }
  window.__brownbearWebextHist = true;

  // Only the top document is a webNavigation main-frame target; subframes are ignored natively too,
  // but skip the work (and the handler lookup) entirely in a subframe.
  try { if (window.top !== window.self) { return; } } catch (e) { return; }

  var W = window;
  var handler = (W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.brownbearWebextHistory) || null;
  if (!handler) { return; }

  var _history = W.history;
  if (!_history || typeof _history.pushState !== "function" || typeof _history.replaceState !== "function") { return; }

  var _push = _history.pushState;
  var _replace = _history.replaceState;
  var _location = W.location;

  function report() {
    // Read the CURRENT location after the History method ran, so the reported URL is the new one.
    try { handler.postMessage({ url: String(_location.href) }); } catch (e) { /* fail closed */ }
  }

  // Wrap transparently: call through to the native method (preserving its return value), then report.
  // Bound to the real history object so `this` is correct regardless of how the page invokes it.
  try {
    _history.pushState = function () {
      var result = _push.apply(_history, arguments);
      report();
      return result;
    };
    _history.replaceState = function () {
      var result = _replace.apply(_history, arguments);
      report();
      return result;
    };
  } catch (e) { /* a frozen History object — leave it; popstate below still covers back/forward */ }

  // Back/forward (and hashchange-style fragment) same-document navigations arrive as popstate.
  W.addEventListener("popstate", function () { report(); }, true);
})();
