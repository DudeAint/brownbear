//
// brownbear-network-logger.js
//
// Transparently wraps `fetch` and `XMLHttpRequest` in whatever world it runs in and reports each request
// (method, URL, status, duration) to native for the Logs → Network inspector. Injected at document-start,
// all frames, in BOTH the page world (page scripts + MAIN-world userscripts) AND the isolated content world
// (isolated userscripts + extension content scripts), so a request is logged no matter who made it. The
// native side (GMNetworkService / the extension fetch proxies) records the requests that already cross into
// Swift; this covers the page network that never does.
//
// Hostile-page-safe: it captures clean references at install time, never trusts page prototypes afterward,
// wraps in try/catch so a throw can never break a request, and preserves a native-looking toString so a
// site can't fingerprint the wrapper. Kill-switchable via the `bbNetworkLog` default (absent == on).
//

(function () {
  "use strict";
  try {
    var W = window;
    if (W.__bbNetLog) { return; }
    W.__bbNetLog = 1;

    var handler = (W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.brownbearNetLog) || null;
    if (!handler) { return; }

    var _String = String;
    var _now = (W.performance && typeof W.performance.now === "function")
      ? W.performance.now.bind(W.performance)
      : function () { return Date.now(); };

    var MAX_BODY = 16384;            // cap on the response text we keep (bytes-ish); enough to read
    var MAX_READ = 1048576;          // don't even read a body bigger than this (avoid buffering a download)

    function post(record) {
      try { handler.postMessage(record); } catch (e) { /* native gone — ignore */ }
    }

    function clip(text) {
      if (!text) { return undefined; }
      return (text.length > MAX_BODY) ? (text.slice(0, MAX_BODY) + "…") : text;
    }

    // Whether a response body is SAFE to clone+read for the inspector. It must be finite, textual, and
    // non-streaming. We must NEVER clone a media/binary/streaming response: `Response.clone()` tees the
    // body stream, and reading the clone of a <video>/<audio>/MSE segment — or of any never-ending stream
    // (Server-Sent Events) — holds that tee open, which back-pressures the page's OWN read and STALLS
    // playback (the "every video stuck at 0s / stutters" bug). A request with no Content-Type could be
    // media, so it is treated as not-capturable. This gate keeps the Network inspector's response bodies
    // for the things developers actually inspect (HTML/JS/JSON/XML/text) while never touching media.
    function isCapturableContentType(ct) {
      if (!ct) { return false; }                         // unknown type — could be media; never clone
      var t = _String(ct).split(";")[0].trim().toLowerCase();
      if (t === "text/event-stream") { return false; }   // SSE — the stream never ends
      if (t.indexOf("multipart/") === 0) { return false; } // x-mixed-replace etc. — streaming
      if (t.indexOf("text/") === 0) { return true; }
      if (t.indexOf("+json") !== -1 || t.indexOf("+xml") !== -1) { return true; }
      switch (t) {
        case "application/json":
        case "application/ld+json":
        case "application/manifest+json":
        case "application/javascript":
        case "application/ecmascript":
        case "application/xml":
        case "application/xhtml+xml":
        case "application/graphql":
        case "application/x-www-form-urlencoded":
          return true;
        default:
          return false;                                  // video/* audio/* image/* font/* octet-stream …
      }
    }

    // Read a bounded copy of a fetch Response body WITHOUT consuming the page's own read (clone first) —
    // but ONLY for small, finite, textual responses (see isCapturableContentType). Media, binary,
    // streaming, and unknown-type responses are NEVER cloned, so wrapping fetch can't stall <video>/MSE.
    // Bodies over MAX_READ are noted, not read. Any failure (opaque response, used body) is swallowed.
    function readFetchBody(response) {
      try {
        var ct = "";
        try { ct = response.headers.get("content-type") || ""; } catch (e) { ct = ""; }
        if (!isCapturableContentType(ct)) { return Promise.resolve(undefined); }
        var len = 0;
        try { len = parseInt(response.headers.get("content-length") || "0", 10) || 0; } catch (e) { len = 0; }
        if (len > MAX_READ) { return Promise.resolve("[" + len + " bytes — body not captured]"); }
        return response.clone().text().then(clip, function () { return undefined; });
      } catch (e) { return Promise.resolve(undefined); }
    }

    // Resolve a fetch input (string, URL, or Request) to an absolute-ish URL string without throwing.
    function urlOf(input) {
      try {
        if (input && typeof input === "object" && input.url != null) { return _String(input.url); }
        return _String(input);
      } catch (e) { return ""; }
    }

    // --- fetch ----------------------------------------------------------------------------------
    var _fetch = (typeof W.fetch === "function") ? W.fetch : null;
    if (_fetch) {
      var wrappedFetch = function (input, init) {
        var start = _now();
        var url = urlOf(input);
        var method = "GET";
        try {
          method = _String((init && init.method) || (input && typeof input === "object" && input.method) || "GET")
            .toUpperCase();
        } catch (e) { /* keep GET */ }
        var promise;
        try { promise = _fetch.apply(W, arguments); }
        catch (e) { post({ kind: "fetch", method: method, url: url, status: 0, duration: 0, error: _String(e && e.message || e) }); throw e; }
        return promise.then(function (response) {
          var status = 0;
          try { status = response.status; } catch (e) { /* opaque response */ }
          var duration = Math.round(_now() - start);
          // Read the body (async, bounded) then report — so the Response block has content.
          readFetchBody(response).then(function (body) {
            post({ kind: "fetch", method: method, url: url, status: status, duration: duration, responseBody: body });
          }, function () {
            post({ kind: "fetch", method: method, url: url, status: status, duration: duration });
          });
          return response;
        }, function (error) {
          post({ kind: "fetch", method: method, url: url, status: 0, duration: Math.round(_now() - start),
                 error: _String(error && error.message || error) });
          throw error;
        });
      };
      maskToString(wrappedFetch, "fetch");
      try { W.fetch = wrappedFetch; } catch (e) { /* non-configurable — give up on fetch */ }
    }

    // --- XMLHttpRequest -------------------------------------------------------------------------
    var XHR = W.XMLHttpRequest;
    if (XHR && XHR.prototype && typeof XHR.prototype.open === "function" && typeof XHR.prototype.send === "function") {
      var origOpen = XHR.prototype.open;
      var origSend = XHR.prototype.send;
      var openWrap = function (method, url) {
        try { this.__bbMethod = _String(method || "GET").toUpperCase(); this.__bbUrl = _String(url || ""); }
        catch (e) { /* ignore */ }
        return origOpen.apply(this, arguments);
      };
      var sendWrap = function () {
        var xhr = this;
        var start = _now();
        try {
          xhr.addEventListener("loadend", function () {
            var status = 0;
            try { status = xhr.status; } catch (e) { /* ignore */ }
            var body;
            try {
              var rt = xhr.responseType;
              if (rt === "" || rt === "text") {
                body = clip(xhr.responseText);
              } else if (rt === "json" && xhr.response != null) {
                body = clip(JSON.stringify(xhr.response));
              }
            } catch (e) { /* responseText throws for some types — leave body undefined */ }
            post({ kind: "xhr", method: xhr.__bbMethod || "GET", url: xhr.__bbUrl || "",
                   status: status, duration: Math.round(_now() - start), responseBody: body });
          });
        } catch (e) { /* listener attach failed — still send */ }
        return origSend.apply(this, arguments);
      };
      maskToString(openWrap, "open");
      maskToString(sendWrap, "send");
      try { XHR.prototype.open = openWrap; XHR.prototype.send = sendWrap; } catch (e) { /* frozen proto */ }
    }

    function maskToString(fn, name) {
      try {
        fn.toString = function () { return "function " + name + "() { [native code] }"; };
      } catch (e) { /* ignore */ }
    }
  } catch (e) { /* never break a page over network logging */ }
})();
