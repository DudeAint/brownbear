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

    function post(record) {
      try { handler.postMessage(record); } catch (e) { /* native gone — ignore */ }
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
          post({ kind: "fetch", method: method, url: url, status: status, duration: Math.round(_now() - start) });
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
            post({ kind: "xhr", method: xhr.__bbMethod || "GET", url: xhr.__bbUrl || "",
                   status: status, duration: Math.round(_now() - start) });
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
