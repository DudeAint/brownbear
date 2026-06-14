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

  // Pristine refs captured pre-page, used to mint UNGUESSABLE GM_xmlhttpRequest request ids. Because we
  // run before any page script, a hostile page cannot have replaced crypto.getRandomValues / Uint8Array
  // yet — so it cannot predict a request id and pre-register a handler to steal another script's XHR
  // response. (The handler registry lives in this closure; the page can't read it.)
  var _cryptoRand = (W.crypto && typeof W.crypto.getRandomValues === "function") ? W.crypto.getRandomValues.bind(W.crypto) : null;
  var _U8 = W.Uint8Array;
  // Pristine Promise#then, captured pre-page — used to settle a request/REPLY (GM_cookie/getTab/listTabs)
  // result WITHOUT going through the live Promise.prototype.then a hostile page may have replaced. The
  // reply value (e.g. cookies) reaches only the caller's closure callback; it is never on the DOM and never
  // passes through a page-tamperable `.then`.
  var _then = (W.Promise && W.Promise.prototype && typeof W.Promise.prototype.then === "function") ? W.Promise.prototype.then : null;
  var _idSeq = 0;
  function mintId() {
    _idSeq += 1;
    if (_cryptoRand && typeof _U8 === "function") {
      try {
        var a = new _U8(16);
        _cryptoRand(a);
        var s = "";
        for (var i = 0; i < a.length; i += 1) { s += (a[i] < 16 ? "0" : "") + a[i].toString(16); }
        return "pwx_" + _idSeq + "_" + s;
      } catch (e) { /* fall through */ }
    }
    return "pwx_" + _idSeq + "_" + Math.floor(Math.random() * 1e9).toString(36);
  }

  // requestId -> handler(type, payload), set by a page-world script's GM_xmlhttpRequest and called when
  // native streams an event back via __bbPageXHR. Closure-private: the page cannot read or enumerate it.
  var xhrHandlers = Object.create(null);

  // The bridge a page-world userscript calls for an own-data write or a GM_xmlhttpRequest. `token`
  // authenticates the script to native (native re-checks the token's grants); `api` MUST be one the native
  // brownbearPage allowlist honors. Returns the native reply promise (the caller may ignore it).
  function call(token, api, payload) {
    try {
      return post({ api: String(api), payload: (payload && typeof payload === "object") ? payload : {}, token: token || null });
    } catch (e) {
      return undefined;
    }
  }
  // Register a streaming handler for a NEW request and return its (unguessable) id; the script passes that
  // id to native via call(...,"GM_xmlhttpRequest",{requestId,...}). The page can't predict the id, so it
  // can't register a handler for, or otherwise intercept, another script's request.
  call.xhr = function (handler) {
    var id = mintId();
    if (typeof handler === "function") { xhrHandlers[id] = handler; }
    return id;
  };
  call.xhrDone = function (id) { delete xhrHandlers[id]; };
  // Request/REPLY (GM_cookie/getTab/saveTab/listTabs): post and settle the native reply to the caller's
  // closure callback via the PRISTINE `.then`. The reply value materializes only in the caller's closure —
  // not on any DOM/global, and not through a page-tamperable `.then` — so even sensitive cookie data is
  // confidential. (More private than the streaming channel, whose dispatcher is a reachable global.)
  call.reply = function (token, api, payload, cb, errcb) {
    var p;
    try { p = call(token, api, payload); } catch (e) { if (errcb) { errcb(String(e)); } return; }
    if (!p || !_then) { if (errcb) { errcb("page-world reply channel unavailable"); } return; }
    try {
      _then.call(p, function (v) { if (cb) { cb(v); } }, function (e) { if (errcb) { errcb(String(e)); } });
    } catch (e) { if (errcb) { errcb(String(e)); } }
  };
  Object.freeze(call);   // lock call.xhr/xhrDone/reply so a later page script can't wrap or replace them

  // Native streams XHR lifecycle events into the page world by evaluating window.__bbPageXHR(id, type,
  // payload) — a native→page eval, NOT a DOM channel, so a cross-origin response body never transits a
  // page-readable surface. Routed only to the registered (closure-private) handler for that id.
  function dispatchXHR(id, type, payload) {
    var h = xhrHandlers[id];
    if (typeof h === "function") { try { h(type, payload); } catch (e) { /* handler must not break delivery */ } }
  }

  try {
    Object.defineProperty(W, "__bbPageGM", { value: call, writable: false, configurable: false, enumerable: false });
    Object.defineProperty(W, "__bbPageXHR", { value: dispatchXHR, writable: false, configurable: false, enumerable: false });
  } catch (e) {
    // Already defined non-configurably by an earlier run, or the page froze window — either way the
    // existing (pristine) binding stands; do not overwrite.
  }
})();
