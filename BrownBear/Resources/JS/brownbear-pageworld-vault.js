//
// brownbear-pageworld-vault.js
//
// Runs in the PAGE (main) world at document-start — registered as a WKUserScript(.atDocumentStart,
// in: .page) so it executes BEFORE any of the page's own scripts. Its single job: capture a PRISTINE
// reference to the restricted page-world native handler (`webkit.messageHandlers.brownbearPage`) and
// expose it as a non-configurable `window.__bbPageGM(token, api, payload)`, so that a GRANTED page-world
// userscript (injected later, via injectPageWorld) can persist its OWN-DATA GM writes (GM_setValue,
// GM_setClipboard, GM_log, …) to native WITHOUT the page being able to forge or MITM the call:
//
//   • Pristine capture, pre-page: because this runs before page scripts, the handler we bind is the real
//     native one — a hostile page cannot have replaced `window.webkit` / `messageHandlers.postMessage`
//     yet, so it cannot intercept the token or the payload.
//   • Non-configurable, non-writable: a page script that runs LATER cannot redefine `__bbPageGM` to wrap
//     and snoop it.
//   • Token-gated at native: a page that calls `__bbPageGM(...)` itself is useless — native requires a
//     valid per-injection token it does not have. The legit userscript holds its token only in its own
//     (page-unreadable) closure.
//
// The native `brownbearPage` handler is a STRICT allowlist of token-bound, own-data write APIs; it can
// never reach getScripts/injectPageWorld or any cross-origin API. Reads never come here — a page-world
// script serves value/resource reads synchronously from a cache pre-seeded into its own source.
//
// This file is deliberately tiny and self-contained: no dependency on the isolated runtime.

(function () {
  "use strict";
  var W = window;
  if (W.__bbPageGM) { return; }   // single install (the document-start script may run per frame)

  var mh = W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.brownbearPage;
  if (!mh || typeof mh.postMessage !== "function") {
    return;   // handler not registered (older build / disabled) — writes simply stay unavailable
  }
  var post = mh.postMessage.bind(mh);   // bound to the PRISTINE native handler, captured pre-page

  // The bridge a page-world userscript calls for an own-data write. `token` authenticates the script to
  // native (native re-checks the token's grants); `api` MUST be one the native brownbearPage allowlist
  // honors. Returns the native reply promise (writes are fire-and-forget; the caller may ignore it).
  function call(token, api, payload) {
    try {
      return post({ api: String(api), payload: (payload && typeof payload === "object") ? payload : {}, token: token || null });
    } catch (e) {
      return undefined;
    }
  }

  try {
    Object.defineProperty(W, "__bbPageGM", { value: call, writable: false, configurable: false, enumerable: false });
  } catch (e) {
    // Already defined non-configurably by an earlier run, or the page froze window — either way the
    // existing (pristine) binding stands; do not overwrite.
  }
})();
