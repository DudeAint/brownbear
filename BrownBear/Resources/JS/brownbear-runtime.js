//
// brownbear-runtime.js
//
// The complete injected userscript runtime, in ONE closure. Injected at document-start into an
// isolated WKContentWorld ("BrownBear"), so the page cannot see or tamper with it.
//
// Security design (hardened per adversarial review):
//   • Everything privileged — the native `bridge`, `getScripts`, and the loaded script data —
//     lives inside this IIFE's closure and is NEVER exposed on `window`. Only `dispatchXHR`
//     (which native must reach to stream XHR events back) is published.
//   • Each script's GM functions are handed to it as `new Function` arguments and close over a
//     server-minted per-injection TOKEN. A script cannot name another script's token, cannot
//     reach `bridge`, and cannot call `getScripts`. Identity is therefore native-bound, not
//     self-reported, so value namespaces and grants are un-spoofable.
//   • Native re-checks grants and @connect for every call; the JS gating is defense-in-depth.

(function () {
  "use strict";
  if (window.__brownbear) { return; }

  // --- Captured clean references --------------------------------------------------------------
  var W = window;
  var _JSON = JSON;
  var _Object = Object;
  var _Array = Array;
  var _Promise = Promise;
  var _Function = Function;
  var _Error = Error;
  var _CSSStyleSheet = W.CSSStyleSheet;   // constructable-stylesheet ctor (CSP-resilient GM_addStyle)
  var _atob = W.atob ? W.atob.bind(W) : null;
  var _btoa = W.btoa ? W.btoa.bind(W) : null;
  var _fetch = W.fetch ? W.fetch.bind(W) : null;
  var _MessageChannel = W.MessageChannel || null;
  var _setTimeout = W.setTimeout ? W.setTimeout.bind(W) : null;
  var _console = W.console || { log: function () {}, error: function () {} };
  var handler = (W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.brownbear) || null;

  var idCounter = 0;
  function genId(prefix) {
    idCounter += 1;
    return (prefix || "bb") + "_" + idCounter + "_" + Math.floor(Math.random() * 1e9).toString(36);
  }

  // --- The native bridge (PRIVATE — never published on window) --------------------------------
  function bridge(api, payload, token) {
    if (!handler) { return _Promise.reject(new _Error("BrownBear bridge unavailable")); }
    try {
      return handler.postMessage({ api: api, payload: payload || {}, token: token || null });
    } catch (e) {
      return _Promise.reject(e);
    }
  }

  // token → { cache, fire } for each running script, so native can push a value change made in
  // ANOTHER frame or tab running the SAME script into this one's cache + listeners in real time
  // (GM value propagation — ScriptCat/Tampermonkey parity). Keyed by the per-injection token.
  var valueEnvByToken = _Object.create(null);

  // --- GM_xmlhttpRequest streaming ------------------------------------------------------------
  var xhrCallbacks = _Object.create(null);

  // token -> { commandId -> callbackFn } for GM_registerMenuCommand. Native (which minted the tokens)
  // calls window.__brownbear.fireMenuCommand(token, commandId) to invoke a tapped command's callback
  // in this exact frame/world. A page cannot reach this (isolated world) nor name another's token.
  var menuCommandsByToken = _Object.create(null);

  // --- GM_notification onclick/onclose routing -----------------------------------------------
  // token -> { byId: { notifId -> { onclick, ondone, onclose } } } so a tap native pushes back can
  // find the right script's callbacks. Keyed by token so one script can't see another's callbacks.
  var notifEnvByToken = _Object.create(null);

  // Published so native can route a notification tap/dismiss back in. Payload is a JSON string
  // { id, kind } where kind is "click" | "close". Native already delivered into the right isolated
  // world + frame, so we search every env's byId for the id (ids are script-unique in practice and
  // the env map is this world's own — isolation holds).
  function dispatchNotification(payloadJSON) {
    var p = safeParse(payloadJSON);
    if (!p || typeof p.id !== "string") { return; }
    var tokens = _Object.keys(notifEnvByToken);
    for (var i = 0; i < tokens.length; i += 1) {
      var env = notifEnvByToken[tokens[i]];
      var entry = env && env.byId[p.id];
      if (!entry) { continue; }
      if (p.kind === "click") { safeCall(entry.onclick, undefined); }
      else if (p.kind === "close") { safeCall(entry.ondone, undefined); safeCall(entry.onclose, undefined); }
      return;
    }
  }

  // --- GM_download streaming -----------------------------------------------------------------
  var downloadCallbacks = _Object.create(null);

  // Published so native can stream GM_download lifecycle events back in.
  function dispatchDownload(requestId, type, payload) {
    var entry = downloadCallbacks[requestId];
    if (!entry) { return; }
    var d = entry.details;
    switch (type) {
      case "progress": safeCall(d.onprogress, payload); break;
      case "timeout": safeCall(d.ontimeout, payload); settleDownload(entry, "reject", payload); delete downloadCallbacks[requestId]; break;
      case "error": safeCall(d.onerror, payload); settleDownload(entry, "reject", payload); delete downloadCallbacks[requestId]; break;
      case "abort": safeCall(d.onabort || d.onerror, payload); settleDownload(entry, "reject", payload); delete downloadCallbacks[requestId]; break;
      case "load": safeCall(d.onload, payload); settleDownload(entry, "resolve", payload); delete downloadCallbacks[requestId]; break;
      default: break;
    }
  }
  function settleDownload(entry, kind, payload) {
    if (kind === "resolve" && entry.resolve) { entry.resolve(payload); }
    if (kind === "reject" && entry.reject) { entry.reject(payload); }
    entry.resolve = null; entry.reject = null;
  }

  // --- GM_openInTab handle (closed / onclose) ------------------------------------------------
  // openId -> the handle returned to the opening script, so native can flip `closed` and fire
  // `onclose` when the opened tab is closed (by the user or via handle.close()). Keyed by a per-call
  // openId so one script can't observe another's tab. Published below for native to reach.
  var openTabsById = _Object.create(null);
  function dispatchTabClosed(openId) {
    var h = openTabsById[openId];
    if (!h) { return; }
    h.closed = true;
    delete openTabsById[openId];
    safeCall(h.onclose, undefined);
  }

  // --- window.onurlchange (SPA URL tracking) --------------------------------------------------
  // Installed ONCE per page (the IIFE's __brownbear guard ensures single install). Userscripts run
  // with `window` bound to the real page window, so we patch the page's own history + listen for
  // popstate/hashchange, then fire a CustomEvent('urlchange', {detail:{url}}) AND call any
  // window.onurlchange handler a script assigned. Tampermonkey parity: a script must @grant
  // window.onurlchange (advisory in our model) before relying on the page-window surface.
  var _history = W.history;
  var _location = W.location;
  var _lastHref = (_location && _location.href) || "";
  var _CustomEvent = W.CustomEvent;
  function emitUrlChange() {
    var href = "";
    try { href = (_location && _location.href) || ""; } catch (e) { href = ""; }
    if (href === _lastHref) { return; }
    _lastHref = href;
    // The standard Tampermonkey surface: a 'urlchange' event on window with {url} in detail. A
    // script may also have set window.onurlchange; the event path covers addEventListener users.
    try {
      if (typeof _CustomEvent === "function") {
        W.dispatchEvent(new _CustomEvent("urlchange", { detail: { url: href } }));
      }
    } catch (e) { /* dispatch failed (rare) — the onurlchange handler below still runs */ }
    try {
      var h = W.onurlchange;
      if (typeof h === "function") { h.call(W, { url: href }); }
    } catch (e) { safeCall(_console.error, e); }
  }
  function installUrlChangeTracking() {
    if (!_history) { return; }
    function wrap(name) {
      var orig = _history[name];
      if (typeof orig !== "function" || orig.__brownbearWrapped) { return; }
      var wrapped = function () {
        var r = orig.apply(this, arguments);
        // Defer one microtask so location.href reflects the new URL before we read it.
        _Promise.resolve().then(emitUrlChange);
        return r;
      };
      wrapped.__brownbearWrapped = true;
      try { _history[name] = wrapped; } catch (e) { /* non-configurable — fall back to events */ }
    }
    wrap("pushState");
    wrap("replaceState");
    try { W.addEventListener("popstate", function () { _Promise.resolve().then(emitUrlChange); }, true); } catch (e) {}
    try { W.addEventListener("hashchange", function () { _Promise.resolve().then(emitUrlChange); }, true); } catch (e) {}
  }
  installUrlChangeTracking();

  function safeCall(fn, arg) {
    if (typeof fn !== "function") { return; }
    try { fn(arg); } catch (e) { _console.error("[BrownBear] callback error:", e); }
  }

  function b64ToBytes(b64) {
    if (!_atob) { return new Uint8Array(0); }
    var binary = _atob(b64);
    var len = binary.length;
    var bytes = new Uint8Array(len);
    for (var i = 0; i < len; i += 1) { bytes[i] = binary.charCodeAt(i); }
    return bytes;
  }

  // Base64-encode raw bytes for binary GM_xmlhttpRequest request bodies. Chunked so a large body
  // never blows the argument limit of String.fromCharCode(...). Returns null if btoa is unavailable.
  function bytesToB64(bytes, btoaFn) {
    var enc = btoaFn || _btoa;
    if (!enc) { return null; }
    var CHUNK = 0x8000, parts = [];
    for (var i = 0; i < bytes.length; i += CHUNK) {
      parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK)));
    }
    return enc(parts.join(""));
  }

  // Encode a binary request body (ArrayBuffer / typed array / DataView) to a base64 string so it
  // crosses the bridge byte-exact. Returns { data, dataIsBase64 } or null when `data` isn't binary.
  function encodeBinaryBody(data, ABCtor, btoaFn) {
    if (data == null) { return null; }
    var bytes = null;
    if (ABCtor && data instanceof ABCtor) { bytes = new Uint8Array(data); }
    else if (data.buffer instanceof (ABCtor || ArrayBuffer) && typeof data.byteLength === "number") {
      // Typed array or DataView — view its own byte range, not the whole backing buffer.
      bytes = new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
    }
    if (!bytes) { return null; }
    var b64 = bytesToB64(bytes, btoaFn);
    return (b64 == null) ? null : { data: b64, dataIsBase64: true };
  }

  function buildXHRResponse(p, responseType) {
    var resp = {
      readyState: p.readyState != null ? p.readyState : 4,
      status: p.status || 0,
      statusText: p.statusText || "",
      responseHeaders: p.responseHeaders || "",
      finalUrl: p.finalUrl || "",
      responseText: p.responseText || "",
      response: null,
      responseXML: null,
      loaded: p.loaded || 0,
      total: p.total || 0,
      lengthComputable: !!p.lengthComputable,
      context: p.context,
      error: p.error
    };
    var rt = responseType || "";
    try {
      if (p.isBase64 && (rt === "arraybuffer" || rt === "blob")) {
        var bytes = b64ToBytes(p.response || "");
        resp.response = (rt === "blob")
          ? new Blob([bytes], p.contentType ? { type: p.contentType } : undefined)
          : bytes.buffer;
      } else if (rt === "json") {
        resp.response = p.responseText ? _JSON.parse(p.responseText) : null;
      } else if (rt === "document") {
        resp.response = new DOMParser().parseFromString(p.responseText || "", "text/html");
        resp.responseXML = resp.response;
      } else {
        resp.response = p.responseText || "";
      }
    } catch (e) {
      resp.response = p.responseText || "";
    }
    return resp;
  }

  function settle(entry, kind, resp) {
    if (kind === "resolve" && entry.resolve) { entry.resolve(resp); }
    if (kind === "reject" && entry.reject) { entry.reject(resp); }
    entry.resolve = null;
    entry.reject = null;
  }

  // Published so native can stream XHR events back in; routes only to registered callbacks.
  function dispatchXHR(requestId, type, payload) {
    var entry = xhrCallbacks[requestId];
    if (!entry) { return; }
    var details = entry.details;
    var resp = buildXHRResponse(payload, details.responseType);
    resp.context = details.context;

    switch (type) {
      case "loadstart": safeCall(details.onloadstart, resp); break;
      case "progress": safeCall(details.onprogress, resp); break;
      case "readystatechange": safeCall(details.onreadystatechange, resp); break;
      case "load": safeCall(details.onload, resp); settle(entry, "resolve", resp); break;
      case "error": safeCall(details.onerror, resp); settle(entry, "reject", resp); break;
      case "timeout": safeCall(details.ontimeout, resp); settle(entry, "reject", resp); break;
      case "abort": safeCall(details.onabort, resp); settle(entry, "reject", resp); break;
      case "loadend": safeCall(details.onloadend, resp); delete xhrCallbacks[requestId]; break;
      default: break;
    }
  }

  function serializeXHRDetails(details) {
    var req = {
      method: details.method || "GET",
      url: typeof details.url === "string" ? details.url : String(details.url),
      headers: details.headers || {},
      responseType: details.responseType || "",
      anonymous: !!details.anonymous
    };
    if (details.timeout) { req.timeout = details.timeout; }
    if (typeof details.overrideMimeType === "string" && details.overrideMimeType) {
      req.overrideMimeType = details.overrideMimeType;
    }
    req.headers = _Object.assign({}, details.headers || {});   // clone so we can default Content-Type
    function hasContentType() {
      for (var hk in req.headers) { if (hk.toLowerCase() === "content-type") { return true; } }
      return false;
    }
    var data = details.data;
    var bin = encodeBinaryBody(data, ArrayBuffer, _btoa);
    if (typeof data === "string") { req.data = data; }
    else if (bin) {
      // ArrayBuffer / typed array / DataView — send the bytes verbatim (base64), not "[object …]".
      req.data = bin.data; req.dataIsBase64 = true;
    } else if (data != null && typeof URLSearchParams === "function" && data instanceof URLSearchParams) {
      req.data = data.toString();   // x-www-form-urlencoded, NOT JSON
      if (!hasContentType()) { req.headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"; }
    } else if (data != null && typeof FormData === "function" && data instanceof FormData) {
      // Serialize text fields as urlencoded (file parts aren't supported over this sync path).
      var pairs = [];
      data.forEach(function (v, k) { if (typeof v === "string") { pairs.push(encodeURIComponent(k) + "=" + encodeURIComponent(v)); } });
      req.data = pairs.join("&");
      if (!hasContentType()) { req.headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"; }
    } else if (data != null) {
      // Objects serialize to JSON; a real string body is handled above.
      try { req.data = _JSON.stringify(data); } catch (e) { req.data = String(data); }
    }
    return req;
  }

  function startXHR(details, token) {
    var requestId = genId("xhr");
    var entry = { details: details, resolve: null, reject: null };
    xhrCallbacks[requestId] = entry;
    bridge("GM_xmlhttpRequest", { requestId: requestId, request: serializeXHRDetails(details) }, token)
      .catch(function (err) {
        var resp = { error: String(err), readyState: 4 };
        safeCall(details.onerror, resp);
        settle(entry, "reject", resp);
        delete xhrCallbacks[requestId];
      });
    return {
      _entry: entry,
      abort: function () { bridge("GM_abortRequest", { requestId: requestId }, token); }
    };
  }

  // --- Per-script execution -------------------------------------------------------------------
  // @require/@resource are fetched NATIVELY (via the bridge) so they bypass page CORS — this is
  // what lets lib-dependent and obfuscated scripts load their dependencies reliably.
  //
  // `inlined` is the warm-cache fast path: native has already put any DISK-CACHED @require/@resource
  // bodies into the getScripts reply, so the script can run WITHOUT a blocking fetchResource round-
  // trip per asset at document-start (the main reason a require-heavy script ran late vs Violentmonkey,
  // which caches @require at install). For an inlined asset we use the cached body immediately and
  // still fire a background, fire-and-forget revalidation so the next navigation picks up any upstream
  // change without delaying this one. Cold (uncached) assets fall back to the normal blocking fetch,
  // which also warms the cache for next time.
  function hasOwn(obj, key) { return obj && _Object.prototype.hasOwnProperty.call(obj, key); }

  function loadRequires(requires, token, inlined) {
    if (!requires || !requires.length) { return _Promise.resolve(""); }
    return _Promise.all(requires.map(function (url) {
      if (hasOwn(inlined, url)) {
        bridge("fetchResource", { url: url }, token).catch(function () {});   // revalidate in background
        return _Promise.resolve(inlined[url] || "");
      }
      return bridge("fetchResource", { url: url }, token)
        .then(function (r) { return (r && r.text) || ""; })
        .catch(function () { return ""; });
    })).then(function (codes) { return codes.join("\n;\n"); });
  }

  function loadResources(resources, token, inlined) {
    var names = resources ? _Object.keys(resources) : [];
    var out = _Object.create(null);
    if (!names.length) { return _Promise.resolve(out); }
    return _Promise.all(names.map(function (name) {
      var url = resources[name];
      if (hasOwn(inlined, name)) {
        bridge("fetchResource", { url: url }, token).catch(function () {});   // revalidate in background
        out[name] = inlined[name];   // { text, url } already shaped natively
        return _Promise.resolve();
      }
      return bridge("fetchResource", { url: url }, token).then(function (r) {
        var dataUrl = (r && r.base64)
          ? ("data:" + ((r && r.mimeType) || "application/octet-stream") + ";base64," + r.base64)
          : url;
        out[name] = { text: (r && r.text) || "", url: dataUrl };
      }).catch(function () { out[name] = { text: "", url: url }; });
    })).then(function () { return out; });
  }

  function safeParse(json) {
    try { return _JSON.parse(json); } catch (e) { return undefined; }
  }

  // A per-script `console` that BOTH writes to the page's real console (so Web Inspector still
  // works) AND forwards to BrownBear's persistent log store, so console.log shows up in the
  // dashboard Logs tab — the behavior users expect from a userscript manager. Token-bound so the
  // native side attributes the line to the right script; fire-and-forget so it never blocks the page.
  function makeConsole(token) {
    function stringify(a) {
      return typeof a === "string" ? a : (function () { try { return _JSON.stringify(a); } catch (e) { return String(a); } })();
    }
    function forward(method, level) {
      return function () {
        var args = arguments;
        try { if (typeof _console[method] === "function") { _console[method].apply(_console, args); } } catch (e) { /* ignore */ }
        var parts = [].slice.call(args).map(stringify);
        bridge("log", { level: level, message: parts.join(" ") }, token).catch(function () {});
      };
    }
    // Preserve the non-leveled console methods (bound to the real console for correct `this`).
    var passthrough = ["dir", "dirxml", "table", "group", "groupCollapsed", "groupEnd", "count",
                       "countReset", "time", "timeEnd", "timeLog", "assert", "clear"];
    var c = {};
    passthrough.forEach(function (m) {
      c[m] = (typeof _console[m] === "function") ? _console[m].bind(_console) : function () {};
    });
    c.log = forward("log", "info");
    c.info = forward("info", "info");
    c.warn = forward("warn", "warn");
    c.error = forward("error", "error");
    c.debug = forward("debug", "debug");
    c.trace = forward("trace", "debug");
    return c;
  }

  function buildGM(data) {
    var token = data.token;
    var cache = _Object.create(null);
    var values = data.values || {};
    _Object.keys(values).forEach(function (k) { cache[k] = values[k]; });

    function call(api, payload) { return bridge(api, payload, token); }

    // Value-change listeners (local, same-context) — Tampermonkey/ScriptCat parity.
    var valueListeners = _Object.create(null);
    var listenerCounter = 0;
    function fireValueChange(key, oldValue, newValue, remote) {
      _Object.keys(valueListeners).forEach(function (id) {
        var entry = valueListeners[id];
        if (entry.key === key) {
          try { entry.fn(key, oldValue, newValue, !!remote); }
          catch (e) { _console.error("[BrownBear] value listener error:", e); }
        }
      });
    }
    function GM_addValueChangeListener(key, fn) {
      listenerCounter += 1;
      valueListeners[listenerCounter] = { key: key, fn: fn };
      return listenerCounter;
    }
    function GM_removeValueChangeListener(id) { delete valueListeners[id]; }

    // Register this script's value environment so native can deliver remote changes (see
    // valueEnvByToken). The cache + fireValueChange are this script's own, so isolation holds.
    valueEnvByToken[token] = { cache: cache, fire: fireValueChange };

    function GM_getValue(key, dflt) {
      if (key in cache) { try { return _JSON.parse(cache[key]); } catch (e) { return dflt; } }
      return dflt;
    }
    function GM_setValue(key, value) {
      if (value === undefined) { GM_deleteValue(key); return; }
      var oldValue = (key in cache) ? safeParse(cache[key]) : undefined;
      var json = _JSON.stringify(value);
      cache[key] = json;
      fireValueChange(key, oldValue, value, false);
      call("GM_setValue", { key: key, value: json });
    }
    function GM_deleteValue(key) {
      var oldValue = (key in cache) ? safeParse(cache[key]) : undefined;
      delete cache[key];
      fireValueChange(key, oldValue, undefined, false);
      call("GM_deleteValue", { key: key });
    }
    function GM_listValues() { return _Object.keys(cache); }
    function GM_getValues(keysOrDefaults) {
      var out = {};
      if (_Array.isArray(keysOrDefaults)) {
        keysOrDefaults.forEach(function (k) { out[k] = GM_getValue(k); });
      } else if (keysOrDefaults && typeof keysOrDefaults === "object") {
        _Object.keys(keysOrDefaults).forEach(function (k) { out[k] = GM_getValue(k, keysOrDefaults[k]); });
      } else {
        _Object.keys(cache).forEach(function (k) { out[k] = GM_getValue(k); });
      }
      return out;
    }
    function GM_setValues(obj) {
      var enc = {};
      _Object.keys(obj).forEach(function (k) {
        var oldValue = (k in cache) ? safeParse(cache[k]) : undefined;
        enc[k] = _JSON.stringify(obj[k]);
        cache[k] = enc[k];
        fireValueChange(k, oldValue, obj[k], false);   // bulk path must fire listeners like the singular
      });
      call("GM_setValues", { values: enc });
    }
    function GM_deleteValues(keys) {
      keys.forEach(function (k) {
        var oldValue = (k in cache) ? safeParse(cache[k]) : undefined;
        delete cache[k];
        fireValueChange(k, oldValue, undefined, false);
      });
      call("GM_deleteValues", { keys: keys });
    }
    function GM_addStyle(css) {
      // Primary: a real <style> works on most sites and keeps the TM/VM return semantics (the element a
      // script can remove to toggle the style off).
      var style = document.createElement("style");
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
      // CSP-resilient fallback — ONLY when the <style> didn't take. A strict style-src can refuse the
      // <style> (its sheet then has no rules); only then apply the CSS via a CONSTRUCTED stylesheet (CSSOM,
      // not gated by style-src). Applying it ONLY as a fallback — never alongside a working <style> — means
      // the CSS isn't applied twice (the adopted sheet cascades AFTER the page's stylesheets and would
      // otherwise override the page harder than a plain <style>) and removing the returned element still
      // removes the style. iOS 16.4+.
      var styleApplied = false;
      try { styleApplied = !!(style.sheet && style.sheet.cssRules && style.sheet.cssRules.length > 0); }
      catch (e) { styleApplied = false; }
      if (!styleApplied) {
        try {
          if (typeof _CSSStyleSheet === "function" && "adoptedStyleSheets" in document) {
            var sheet = new _CSSStyleSheet();
            sheet.replaceSync(String(css));
            document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
          }
        } catch (e) { /* constructed-sheet fallback is best-effort */ }
      }
      return style;
    }
    function GM_addElement(parent, tag, attrs) {
      if (typeof parent === "string") { attrs = tag; tag = parent; parent = null; }
      var el = document.createElement(tag);
      if (attrs) {
        _Object.keys(attrs).forEach(function (k) {
          if (k === "textContent") { el.textContent = attrs[k]; }
          else { try { el.setAttribute(k, attrs[k]); } catch (e) { /* ignore bad attr */ } }
        });
      }
      (parent || document.head || document.documentElement).appendChild(el);
      return el;
    }
    function GM_setClipboard(data2, info) {
      var mimetype = typeof info === "string" ? info : (info && info.mimetype) || "text/plain";
      call("GM_setClipboard", { data: String(data2), mimetype: mimetype });
    }
    function GM_openInTab(url, options) {
      var active;
      if (typeof options === "boolean") { active = !options; }
      else if (options && typeof options === "object") { active = options.active !== false; }
      else { active = true; }
      var openId = genId("tab");
      // A REAL handle (TM/VM parity): close() closes the tab, and native flips closed + fires onclose
      // when it goes away. Stored by openId so dispatchTabClosed can find it.
      var handle = { closed: false, onclose: null,
        close: function () { call("GM_closeTab", { openId: openId }); } };
      openTabsById[openId] = handle;
      // If native refuses to open the tab (e.g. invalid URL), there is no tab and thus no
      // dispatchTabClosed for this openId — drop the handle so the registry doesn't leak.
      call("GM_openInTab", { url: url, active: active, openId: openId }).catch(function () {
        handle.closed = true;
        delete openTabsById[openId];
      });
      return handle;
    }
    function GM_log() {
      var parts = [].slice.call(arguments).map(function (a) {
        return typeof a === "string" ? a : (function () { try { return _JSON.stringify(a); } catch (e) { return String(a); } })();
      });
      call("GM_log", { message: parts.join(" "), level: "info" });
    }
    function GM_getResourceText(name) {
      return data.resources && data.resources[name] ? data.resources[name].text : undefined;
    }
    function GM_getResourceURL(name) {
      return data.resources && data.resources[name] ? data.resources[name].url : undefined;
    }
    function GM_xmlhttpRequest(details) { return startXHR(details, token); }

    // --- GM_registerMenuCommand (Tampermonkey/ScriptCat parity) -------------------------------
    // Commands are surfaced natively in the browser's "•••" menu; native fires the callback back via
    // fireMenuCommand(token, commandId). The id is stable so GM_unregisterMenuCommand can target it.
    var menuReg = menuCommandsByToken[token] || (menuCommandsByToken[token] = _Object.create(null));
    var menuCounter = 0;
    function GM_registerMenuCommand(title, callback, optionsOrAccessKey) {
      if (typeof callback !== "function") { return null; }
      var accessKey = null;
      var autoClose = true;
      if (typeof optionsOrAccessKey === "string") {
        accessKey = optionsOrAccessKey;
      } else if (optionsOrAccessKey && typeof optionsOrAccessKey === "object") {
        if (typeof optionsOrAccessKey.accessKey === "string") { accessKey = optionsOrAccessKey.accessKey; }
        if (optionsOrAccessKey.autoClose === false) { autoClose = false; }
      }
      var commandId = (optionsOrAccessKey && optionsOrAccessKey.id != null)
        ? String(optionsOrAccessKey.id)
        : (menuCounter += 1, "cmd_" + menuCounter);
      menuReg[commandId] = callback;
      call("GM_registerMenuCommand", {
        commandId: commandId,
        title: String(title == null ? "" : title),
        accessKey: accessKey,
        autoClose: autoClose
      });
      return commandId;
    }
    function GM_unregisterMenuCommand(commandId) {
      var id = String(commandId);
      delete menuReg[id];
      call("GM_unregisterMenuCommand", { commandId: id });
    }

    // --- GM_getTab / GM_saveTab / GM_listTabs (per-tab, per-script object) ---------------------
    // Native namespaces by this script's UUID and keys by the chrome-style tab id of the calling
    // web view, so the object is private to the script and scoped to the tab for its lifetime.
    function GM_getTab(callback) {
      call("GM_getTab", {}).then(function (json) {
        var obj = (typeof json === "string") ? (safeParse(json) || {}) : {};
        safeCall(callback, obj);
      }).catch(function () { safeCall(callback, {}); });
    }
    function GM_saveTab(obj, callback) {
      var json;
      try { json = _JSON.stringify(obj == null ? {} : obj); } catch (e) { json = "{}"; }
      call("GM_saveTab", { value: json })
        .then(function () { safeCall(callback, undefined); })
        .catch(function () { safeCall(callback, undefined); });
    }
    function GM_listTabs(callback) {
      call("GM_listTabs", {}).then(function (map) {
        var out = _Object.create(null);
        if (map && typeof map === "object") {
          _Object.keys(map).forEach(function (k) {
            var parsed = (typeof map[k] === "string") ? safeParse(map[k]) : map[k];
            out[k] = parsed || {};
          });
        }
        safeCall(callback, out);
      }).catch(function () { safeCall(callback, _Object.create(null)); });
    }

    // --- GM_notification (TM/VM: details OR (text, title, image, onclick)) ---------------------
    var notifEnv = { byId: _Object.create(null) };
    notifEnvByToken[token] = notifEnv;
    function normalizeNotification(arg1, arg2, arg3, arg4) {
      if (arg1 && typeof arg1 === "object") {
        var d = arg1;
        return {
          title: d.title, text: (d.text != null ? d.text : d.message), image: d.image,
          silent: !!d.silent, timeout: d.timeout, id: d.id,
          onclick: d.onclick, ondone: d.ondone, onclose: d.onclose, oncreate: d.oncreate
        };
      }
      return { text: arg1, title: arg2, image: arg3, onclick: arg4 };
    }
    function GM_notification(arg1, arg2, arg3, arg4) {
      var n = normalizeNotification(arg1, arg2, arg3, arg4);
      var details = { title: n.title, text: n.text, silent: n.silent };
      var wantClick = (typeof n.onclick === "function") || (typeof n.ondone === "function")
        || (typeof n.onclose === "function");
      var control = { remove: function () { return _Promise.resolve(); } };
      call("GM_notification", { details: details, id: n.id || null, wantClick: wantClick })
        .then(function (res) {
          var id = res && res.id;
          if (!id) { return; }
          notifEnv.byId[id] = { onclick: n.onclick, ondone: n.ondone, onclose: n.onclose };
          control.remove = function () {
            delete notifEnv.byId[id];
            return call("GM_notificationClear", { id: id });
          };
          safeCall(n.oncreate, id);
        })
        .catch(function () {});
      return control;
    }

    // --- GM_cookie / GM.cookie.list|set|delete (VM signature) ----------------------------------
    function cookieCall(action, details) {
      return call("GM_cookie", { action: action, details: details || {} });
    }
    var GM_cookie = {
      list: function (details, cb) {
        var p = cookieCall("list", details);
        if (typeof cb === "function") { p.then(function (r) { cb(r, undefined); }, function (e) { cb(undefined, String(e)); }); }
        return p;
      },
      set: function (details, cb) {
        var p = cookieCall("set", details);
        if (typeof cb === "function") { p.then(function () { cb(undefined); }, function (e) { cb(String(e)); }); }
        return p;
      },
      delete: function (details, cb) {
        var p = cookieCall("delete", details);
        if (typeof cb === "function") { p.then(function () { cb(undefined); }, function (e) { cb(String(e)); }); }
        return p;
      }
    };

    // --- GM_download (TM/VM: details OR (url, name)) -------------------------------------------
    function normalizeDownload(arg1, arg2) {
      if (arg1 && typeof arg1 === "object") { return arg1; }
      return { url: arg1, name: arg2 };
    }
    function GM_download(arg1, arg2) {
      var d = normalizeDownload(arg1, arg2);
      var requestId = genId("dl");
      var entry = { details: d, resolve: null, reject: null };
      downloadCallbacks[requestId] = entry;
      var payload = {
        requestId: requestId,
        url: typeof d.url === "string" ? d.url : String(d.url),
        name: d.name || "",
        headers: d.headers || {},
        saveAs: !!d.saveAs
      };
      if (d.timeout) { payload.timeout = d.timeout; }
      call("GM_download", payload).catch(function (err) {
        var p = { error: String(err) };
        safeCall(d.onerror, p);
        settleDownload(entry, "reject", p);
        delete downloadCallbacks[requestId];
      });
      // Real handle: abort() cancels the native fetch mid-transfer (parity with Tampermonkey/
      // Violentmonkey). The native side fires the "abort" lifecycle event, which rejects the promise
      // and calls onabort/onerror.
      return { abort: function () { call("GM_downloadAbort", { requestId: requestId }); } };
    }

    // GM_info: native supplies the full object (uuid, version, scriptHandler, scriptMetaStr,
    // scriptWillUpdate, downloadMode, isIncognito, platform, container, sandboxMode, and a complete
    // `script` sub-object). We deep-freeze it so a hostile page (or the script itself) can't mutate
    // the identity/metadata other code may trust. `scriptHandler` is asserted defensively in case an
    // old native payload omits it. Tampermonkey/Violentmonkey/ScriptCat parity.
    var GM_info = data.info || {};
    if (!GM_info.scriptHandler) { GM_info.scriptHandler = "BrownBear"; }
    function deepFreeze(o) {
      if (o && (typeof o === "object")) {
        _Object.keys(o).forEach(function (k) {
          var v = o[k];
          if (v && typeof v === "object") { deepFreeze(v); }
        });
        try { _Object.freeze(o); } catch (e) { /* frozen-already / non-extensible host obj */ }
      }
      return o;
    }
    deepFreeze(GM_info);

    var GM = {
      info: GM_info,
      getValue: function (k, d) { return _Promise.resolve(GM_getValue(k, d)); },
      setValue: function (k, v) { GM_setValue(k, v); return _Promise.resolve(); },
      deleteValue: function (k) { GM_deleteValue(k); return _Promise.resolve(); },
      listValues: function () { return _Promise.resolve(GM_listValues()); },
      getValues: function (k) { return _Promise.resolve(GM_getValues(k)); },
      setValues: function (o) { GM_setValues(o); return _Promise.resolve(); },
      deleteValues: function (k) { GM_deleteValues(k); return _Promise.resolve(); },
      addValueChangeListener: function (k, fn) { return GM_addValueChangeListener(k, fn); },
      removeValueChangeListener: function (id) { GM_removeValueChangeListener(id); },
      addStyle: function (c) { return _Promise.resolve(GM_addStyle(c)); },
      addElement: function () { return _Promise.resolve(GM_addElement.apply(null, arguments)); },
      setClipboard: function (d, i) { GM_setClipboard(d, i); return _Promise.resolve(); },
      openInTab: function (u, o) { return _Promise.resolve(GM_openInTab(u, o)); },
      getResourceText: function (n) { return _Promise.resolve(GM_getResourceText(n)); },
      getResourceUrl: function (n) { return _Promise.resolve(GM_getResourceURL(n)); },
      getResourceURL: function (n) { return _Promise.resolve(GM_getResourceURL(n)); },
      log: function () { GM_log.apply(null, arguments); return _Promise.resolve(); },
      xmlHttpRequest: function (details) {
        var handle = startXHR(details, token);
        var promise = new _Promise(function (resolve, reject) {
          handle._entry.resolve = resolve;
          handle._entry.reject = reject;
        });
        promise.abort = handle.abort;
        return promise;
      },
      notification: function () { return GM_notification.apply(null, arguments); },
      cookie: GM_cookie,
      download: function (details) {
        var d = (details && typeof details === "object") ? details : { url: details };
        var promise = new _Promise(function (resolve, reject) {
          var userLoad = d.onload, userErr = d.onerror;
          d.onload = function (p) { safeCall(userLoad, p); resolve(p); };
          d.onerror = function (p) { safeCall(userErr, p); reject(p); };
        });
        // Expose the real abort() on the promise (TM/VM parity), mirroring GM.xmlHttpRequest above —
        // otherwise GM.download(...).abort() is undefined and a script can't cancel the transfer.
        var handle = GM_download(d);
        if (handle && handle.abort) { promise.abort = handle.abort; }
        return promise;
      },
      registerMenuCommand: function (t, cb, o) { return GM_registerMenuCommand(t, cb, o); },
      unregisterMenuCommand: function (id) { GM_unregisterMenuCommand(id); },
      getTab: function () { return new _Promise(function (resolve) { GM_getTab(resolve); }); },
      saveTab: function (obj) { return new _Promise(function (resolve) { GM_saveTab(obj, function () { resolve(); }); }); },
      listTabs: function () { return new _Promise(function (resolve) { GM_listTabs(resolve); }); }
    };

    return {
      registry: {
        GM_getValue: GM_getValue, GM_setValue: GM_setValue, GM_deleteValue: GM_deleteValue,
        GM_listValues: GM_listValues, GM_getValues: GM_getValues, GM_setValues: GM_setValues,
        GM_deleteValues: GM_deleteValues, GM_addStyle: GM_addStyle, GM_addElement: GM_addElement,
        GM_setClipboard: GM_setClipboard, GM_openInTab: GM_openInTab, GM_log: GM_log,
        GM_getResourceText: GM_getResourceText, GM_getResourceURL: GM_getResourceURL,
        GM_addValueChangeListener: GM_addValueChangeListener,
        GM_removeValueChangeListener: GM_removeValueChangeListener,
        GM_xmlhttpRequest: GM_xmlhttpRequest,
        GM_notification: GM_notification, GM_cookie: GM_cookie, GM_download: GM_download,
        GM_registerMenuCommand: GM_registerMenuCommand,
        GM_unregisterMenuCommand: GM_unregisterMenuCommand,
        GM_getTab: GM_getTab, GM_saveTab: GM_saveTab, GM_listTabs: GM_listTabs
      },
      GM: GM,
      GM_info: GM_info
    };
  }

  // Which world a script runs in. `W` is THIS isolated world's window — a distinct global object from
  // the page's, so page-defined globals (window.jQuery, a site's own functions) are invisible here and
  // `unsafeWindow`/`window` don't see them. Running in the page's REAL main world fixes that.
  // Tampermonkey/Violentmonkey parity:
  //   • @inject-into content              → always the isolated world (full protection).
  //   • @inject-into page / auto, @grant none
  //                                       → the page world, inert GM (the canonical "@grant none ⇒ real
  //                                         window" idiom). Path: buildPageWorldSource.
  //   • @inject-into page / auto, GRANTED with only page-world-SAFE grants
  //                                       → the page world WITH a working GM surface, so unsafeWindow ===
  //                                         window and the page's own globals are visible (Violentmonkey
  //                                         parity — VM defaults granted scripts to the page world too).
  //                                         Path: buildGrantedPageWorldSource.
  //   • @inject-into page / auto, GRANTED with any NON-page-safe grant (notifications, menu, openInTab)
  //                                       → the ISOLATED world (those still need native→world callback
  //                                         streaming that this PR doesn't yet route to the page world).
  //
  // The page-world-SAFE set is the GM surface where nothing a hostile page could read or forge crosses a
  // page-readable channel: value/resource READS (served synchronously from a cache pre-seeded into the
  // page-world closure — classic sync GM_getValue parity), DOM-local GM_addStyle/GM_addElement (page
  // document), own-data WRITES (GM_setValue/deleteValue/setValues/deleteValues/GM_setClipboard/GM_log), and
  // GM_xmlhttpRequest (request via the pristine vault, response delivered native→page via __bbPageXHR — see
  // below — with native @connect enforcement). Reads + DOM never leave the page. A write updates the
  // page-local cache synchronously, then persists to native through the
  // document-start VAULT's `window.__bbPageGM(token, api, payload)` — a pristine, page-unreadable bridge
  // to the RESTRICTED native `brownbearPage` handler (own-data writes only; native re-checks the token's
  // grants). The token lives only in this page-world closure (never on the DOM) and the vault binding is
  // non-configurable, so a hostile page can neither read the token, MITM the call, nor forge a write.
  // Cross-origin/streaming APIs are NOT in this set — they keep the script isolated.
  function normGrant(g) { return (typeof g === "string") ? g.replace(/^GM\./, "GM_") : ""; }
  // REGISTRY-backed page-world-safe grants: each maps to a function the page-world client provides, passed
  // to the script body as an argument. Value-change listeners are page-local (they fire on the script's own
  // writes; cross-frame remote delivery to the page world is a follow-up).
  var PAGE_WORLD_SAFE_GRANTS = {
    GM_getValue: 1, GM_listValues: 1, GM_getValues: 1, GM_getResourceText: 1,
    GM_getResourceURL: 1, GM_getResourceUrl: 1, GM_addStyle: 1, GM_addElement: 1,
    GM_setValue: 1, GM_deleteValue: 1, GM_setValues: 1, GM_deleteValues: 1,
    GM_setClipboard: 1, GM_log: 1, GM_addValueChangeListener: 1, GM_removeValueChangeListener: 1,
    // GM_xmlhttpRequest is page-world-safe HERE because its request goes through the pristine vault and
    // its response is delivered native→page (never via a page-readable DOM channel); native enforces the
    // token's @connect on every request. See pageWorldGMClient.GM_xmlhttpRequest + the vault's __bbPageXHR.
    GM_xmlhttpRequest: 1,
    // Request→reply APIs: native runs them (GM_cookie is @connect-gated) and returns the result through the
    // WKScriptMessageHandlerWithReply reply promise, which the vault settles via a pristine `.then` into the
    // caller's closure — never on the DOM. See pageWorldGMClient's GM_cookie/GM_getTab/etc + vault call.reply.
    GM_cookie: 1, GM_getTab: 1, GM_saveTab: 1, GM_listTabs: 1,
    // GM_download streams its lifecycle (progress/load/error/abort) native→page via the vault's minted-id
    // channel (__bbPageXHR), exactly like GM_xmlhttpRequest; the @connect host is enforced natively. See
    // pageWorldGMClient.GM_download + the native handleDownload fromPageWorld branch.
    GM_download: 1,
    // GM_registerMenuCommand registers in the native "•••" menu; a tap streams back native→page via the
    // vault's minted-id channel (__bbPageXHR(commandId, "menu")) to the script's callback. The minted id IS
    // the command id. See pageWorldGMClient.GM_registerMenuCommand + the native fireMenuCommand page branch.
    GM_registerMenuCommand: 1, GM_unregisterMenuCommand: 1,
    // GM_openInTab opens a tab and returns a handle; when that tab later closes native streams back via the
    // vault's minted-id channel (__bbPageXHR(openId, "close")) to fire the handle's onclose. The minted id IS
    // the openId. See pageWorldGMClient.GM_openInTab + the native dispatchTabClosed page branch.
    GM_openInTab: 1,
    // GM_notification posts a banner; click/close stream back native→page via the vault's minted-id channel
    // (__bbPageXHR(streamId, "click"|"close")) to the script's onclick/ondone/onclose; the native id is
    // returned via the reply for .remove(). See pageWorldGMClient.GM_notification + the native dispatch page
    // branch. GM_notificationClear is its paired clear API.
    GM_notification: 1, GM_notificationClear: 1
  };
  // DECLARATION grants that aren't relayed APIs — they're page-world-native capabilities a script asks for.
  // `@grant unsafeWindow` is the canonical "I want the REAL page window" request (the page-world client
  // gives unsafeWindow === window natively); `window.*` are page-window event/method declarations. These
  // count as page-world-safe for ROUTING but are NOT passed as body args (the body already gets unsafeWindow
  // and window as fixed params) — so they must stay out of buildGrantedPageWorldSource's param list.
  var PAGE_WORLD_SAFE_DECLARATIONS = {
    unsafeWindow: 1, "window.onurlchange": 1, "window.close": 1, "window.focus": 1, "window.onbeforeunload": 1
  };
  function isGrantPageSafe(g) {
    var n = normGrant(g);
    return !!(PAGE_WORLD_SAFE_GRANTS[n] || PAGE_WORLD_SAFE_DECLARATIONS[g] || PAGE_WORLD_SAFE_DECLARATIONS[n]);
  }
  function allGrantsPageSafe(grants) {
    for (var i = 0; i < grants.length; i += 1) {
      if (!isGrantPageSafe(grants[i])) { return false; }
    }
    return true;
  }
  // "isolated" | "page-grantless" | "page-granted"
  //
  // Violentmonkey parity: `@inject-into page` AND `@inject-into auto` (the default) run a granted script in
  // the PAGE world — just like VM, which defaults to the page world. Only `@inject-into content` forces the
  // isolated world. A granted script reaches the page world when all its grants are page-world-safe; a
  // non-page-safe grant (cross-origin/streaming) keeps it isolated. console.* still reaches the dashboard
  // Logs from the page world (forwarded through the vault), so there is no debugging regression.
  function pageWorldPlan(data) {
    var into = data.injectInto || "auto";
    if (into === "content") { return "isolated"; }
    if (data.grantNone) { return "page-grantless"; }   // page or auto, no grants → real-window page world
    if ((into === "page" || into === "auto") && allGrantsPageSafe(data.grants || [])) { return "page-granted"; }
    return "isolated";
  }

  // The page-world GM client. Injected by buildGrantedPageWorldSource via Function#toString and run in the
  // page's MAIN world, so it MUST be fully self-contained — it may reference ONLY its two parameters and
  // page globals, never any variable from this isolated closure. It serves value/resource reads
  // SYNCHRONOUSLY from the pre-seeded cache, runs GM_addStyle/GM_addElement on the page document, and
  // persists own-data WRITES through the pristine document-start vault (`window.__bbPageGM`), then invokes
  // the script body with unsafeWindow === window and the granted GM_* surface. `cfg.token` lives ONLY in
  // this closure (never on the DOM); the vault binding is non-configurable; native re-checks the token's
  // grants — so a hostile page can neither read the token, MITM a write, nor forge one.
  function pageWorldGMClient(cfg, bodyFn) {
    "use strict";
    var W = window, D = document;
    var _JSON = W.JSON, _Object = W.Object, _Array = W.Array, _Promise = W.Promise;
    var _btoaPage = W.btoa ? W.btoa.bind(W) : null;

    // Persist an own-data write to native via the pristine vault. Fire-and-forget — the page-local cache
    // already reflected the change synchronously. No-op if the vault didn't install (restricted handler
    // unavailable); reads still work for this session. The token authenticates the script to native.
    function pageGM(api, payload) {
      try { if (typeof W.__bbPageGM === "function") { W.__bbPageGM(cfg.token, api, payload); } }
      catch (e) { /* a write must never break the script */ }
    }

    var vals = cfg.values || {};   // key -> JSON string (pre-seeded snapshot; classic sync-read parity)
    function has(k) { return _Object.prototype.hasOwnProperty.call(vals, k); }
    function vparse(s) { try { return _JSON.parse(s); } catch (e) { return undefined; } }
    function GM_getValue(k, d) {
      if (has(k)) { try { return _JSON.parse(vals[k]); } catch (e) { return d; } }
      return d;
    }
    function GM_listValues() { return _Object.keys(vals); }
    function GM_getValues(spec) {
      var out = {};
      if (_Array.isArray(spec)) { spec.forEach(function (k) { out[k] = GM_getValue(k); }); }
      else if (spec && typeof spec === "object") { _Object.keys(spec).forEach(function (k) { out[k] = GM_getValue(k, spec[k]); }); }
      else { _Object.keys(vals).forEach(function (k) { out[k] = GM_getValue(k); }); }
      return out;
    }

    // Own-data writes: update the page-local cache SYNCHRONOUSLY (so the next GM_getValue is consistent),
    // fire same-context value-change listeners, then persist to native via the vault. (Remote cross-frame
    // change forwarding into the page world is a follow-up; same-context firing covers the common case.)
    var vcListeners = {}, vcSeq = 0;
    function fireVC(key, oldV, newV, remote) {
      _Object.keys(vcListeners).forEach(function (id) {
        var e = vcListeners[id];
        if (e.key === key) { try { e.fn(key, oldV, newV, !!remote); } catch (err) { /* listener must not break the writer */ } }
      });
    }
    function GM_setValue(k, v) {
      if (v === undefined) { GM_deleteValue(k); return; }
      var oldV = has(k) ? vparse(vals[k]) : undefined;
      var json = _JSON.stringify(v);
      vals[k] = json; fireVC(k, oldV, v, false);
      pageGM("GM_setValue", { key: k, value: json });
    }
    function GM_deleteValue(k) {
      var oldV = has(k) ? vparse(vals[k]) : undefined;
      delete vals[k]; fireVC(k, oldV, undefined, false);
      pageGM("GM_deleteValue", { key: k });
    }
    function GM_setValues(obj) {
      if (!obj || typeof obj !== "object") { return; }
      var enc = {};
      _Object.keys(obj).forEach(function (k) {
        var oldV = has(k) ? vparse(vals[k]) : undefined;
        var json = _JSON.stringify(obj[k]);
        enc[k] = json; vals[k] = json; fireVC(k, oldV, obj[k], false);
      });
      pageGM("GM_setValues", { values: enc });
    }
    function GM_deleteValues(keys) {
      if (!_Array.isArray(keys)) { return; }
      keys.forEach(function (k) {
        var oldV = has(k) ? vparse(vals[k]) : undefined;
        delete vals[k]; fireVC(k, oldV, undefined, false);
      });
      pageGM("GM_deleteValues", { keys: keys });
    }
    // Remote value-change sync: a change made by the SAME script in ANOTHER tab/frame or the dashboard is
    // pushed back native→page via the vault's minted-id channel (window.__bbPageXHR(vcStreamId,
    // "valueChange", {key, oldJSON, newJSON})) and fired to the local listeners with remote = true (TM/VM
    // cross-context parity). We subscribe lazily on the first listener so a script that never listens never
    // opens the channel. The page-local read cache (`vals`) is kept in sync so GM_getValue reflects it.
    var vcSubscribed = false, vcStreamId = null;
    function ensureVCSubscription() {
      if (vcSubscribed) { return; }
      var vault = W.__bbPageGM;
      if (!vault || typeof vault.xhr !== "function") { return; }
      vcSubscribed = true;
      vcStreamId = vault.xhr(function (type, payload) {
        if (type !== "valueChange" || !payload) { return; }
        var key = payload.key;
        var oldV = has(key) ? vparse(vals[key]) : undefined;
        var newV;
        if (payload.newJSON != null) { vals[key] = payload.newJSON; newV = vparse(payload.newJSON); }
        else { delete vals[key]; newV = undefined; }
        fireVC(key, oldV, newV, true);
      });
      pageGM("GM_subscribeValueChanges", { streamId: vcStreamId });
    }
    function GM_addValueChangeListener(k, fn) {
      ensureVCSubscription();
      vcSeq += 1; vcListeners[vcSeq] = { key: k, fn: fn }; return vcSeq;
    }
    function GM_removeValueChangeListener(id) { delete vcListeners[id]; }
    function GM_setClipboard(d, info) {
      var mimetype = typeof info === "string" ? info : (info && info.mimetype) || "text/plain";
      pageGM("GM_setClipboard", { data: String(d), mimetype: mimetype });
    }
    function GM_log() {
      var parts = [].slice.call(arguments).map(function (a) {
        return typeof a === "string" ? a : (function () { try { return _JSON.stringify(a); } catch (e) { return String(a); } })();
      });
      pageGM("GM_log", { message: parts.join(" "), level: "info" });
    }

    var res = cfg.resources || {};
    function GM_getResourceText(n) { return res[n] ? res[n].text : undefined; }
    function GM_getResourceURL(n) { return res[n] ? res[n].url : undefined; }

    function GM_addStyle(css) {
      // Primary: a real <style> (TM/VM semantics — the script can remove the returned element to toggle
      // the style off). Append the constructed adoptedStyleSheets sheet ONLY as a CSP fallback when the
      // <style> didn't take (its sheet has no rules), never alongside a working one — otherwise the CSS is
      // applied twice and the adopted sheet cascades AFTER the page's stylesheets, overriding harder than a
      // plain <style> and visibly mis-styling the page. Mirrors the isolated-world GM_addStyle (iOS 16.4+).
      var style = D.createElement("style");
      style.textContent = css;
      (D.head || D.documentElement).appendChild(style);
      var styleApplied = false;
      try { styleApplied = !!(style.sheet && style.sheet.cssRules && style.sheet.cssRules.length > 0); }
      catch (e) { styleApplied = false; }
      if (!styleApplied) {
        try {
          if (typeof W.CSSStyleSheet === "function" && "adoptedStyleSheets" in D) {
            var sheet = new W.CSSStyleSheet();
            sheet.replaceSync(String(css));
            D.adoptedStyleSheets = D.adoptedStyleSheets.concat([sheet]);
          }
        } catch (e) { /* constructed-sheet fallback is best-effort */ }
      }
      return style;
    }
    function GM_addElement(parent, tag, attrs) {
      if (typeof parent === "string") { attrs = tag; tag = parent; parent = null; }
      var el = D.createElement(tag);
      if (attrs) {
        _Object.keys(attrs).forEach(function (k) {
          if (k === "textContent") { el.textContent = attrs[k]; }
          else { try { el.setAttribute(k, attrs[k]); } catch (e) { /* ignore bad attr */ } }
        });
      }
      (parent || D.head || D.documentElement).appendChild(el);
      return el;
    }

    // --- GM_xmlhttpRequest (page world) ---------------------------------------------------------
    // The request goes through the vault (__bbPageGM, non-configurable) to the restricted brownbearPage
    // handler, which runs the real native request with @connect enforcement. Native streams events back by
    // EVALUATING window.__bbPageXHR(id, type, payload) in this page world — a native→page eval, never a
    // page-readable DOM channel, so a cross-origin response body cannot be snooped. The vault mints the
    // request id with pristine crypto, so a hostile page can't predict it and pre-register a handler.
    function xhrSafeCall(fn, arg) { if (typeof fn === "function") { try { fn(arg); } catch (e) { /* ignore */ } } }
    function xhrB64ToBytes(b64) {
      if (!W.atob) { return new W.Uint8Array(0); }
      var bin = W.atob(b64), len = bin.length, bytes = new W.Uint8Array(len);
      for (var i = 0; i < len; i += 1) { bytes[i] = bin.charCodeAt(i); }
      return bytes;
    }
    function xhrBuildResponse(p, responseType) {
      var resp = {
        readyState: p.readyState != null ? p.readyState : 4, status: p.status || 0,
        statusText: p.statusText || "", responseHeaders: p.responseHeaders || "", finalUrl: p.finalUrl || "",
        responseText: p.responseText || "", response: null, responseXML: null, loaded: p.loaded || 0,
        total: p.total || 0, lengthComputable: !!p.lengthComputable, context: p.context, error: p.error
      };
      var rt = responseType || "";
      try {
        if (p.isBase64 && (rt === "arraybuffer" || rt === "blob")) {
          var bytes = xhrB64ToBytes(p.response || "");
          resp.response = (rt === "blob" && typeof W.Blob === "function")
            ? new W.Blob([bytes], p.contentType ? { type: p.contentType } : undefined)
            : bytes.buffer;
        } else if (rt === "json") {
          resp.response = p.responseText ? _JSON.parse(p.responseText) : null;
        } else if (rt === "document" && typeof W.DOMParser === "function") {
          resp.response = new W.DOMParser().parseFromString(p.responseText || "", "text/html");
          resp.responseXML = resp.response;
        } else {
          resp.response = p.responseText || "";
        }
      } catch (e) { resp.response = p.responseText || ""; }
      return resp;
    }
    // Self-contained binary-body encoder — the module-scope encodeBinaryBody/bytesToB64 helpers live in
    // the isolated IIFE and are NOT in this serialized page-world closure, so the page world needs its own.
    // ArrayBuffer / typed array / DataView -> { data: base64, dataIsBase64: true }; null otherwise.
    function pwEncodeBinaryBody(data) {
      if (data == null || !_btoaPage) { return null; }
      var AB = W.ArrayBuffer, U8 = W.Uint8Array, bytes = null;
      if (!U8) { return null; }
      if (AB && data instanceof AB) { bytes = new U8(data); }
      else if (AB && data.buffer instanceof AB && typeof data.byteLength === "number") {
        bytes = new U8(data.buffer, data.byteOffset || 0, data.byteLength);
      }
      if (!bytes) { return null; }
      var CHUNK = 0x8000, parts = [];
      for (var i = 0; i < bytes.length; i += CHUNK) {
        parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK)));
      }
      return { data: _btoaPage(parts.join("")), dataIsBase64: true };
    }
    function xhrSerialize(details) {
      var req = {
        method: details.method || "GET", url: typeof details.url === "string" ? details.url : String(details.url),
        headers: _Object.assign({}, details.headers || {}), responseType: details.responseType || "",
        anonymous: !!details.anonymous
      };
      if (details.timeout) { req.timeout = details.timeout; }
      if (typeof details.overrideMimeType === "string" && details.overrideMimeType) {
        req.overrideMimeType = details.overrideMimeType;
      }
      function hasCT() { for (var k in req.headers) { if (k.toLowerCase() === "content-type") { return true; } } return false; }
      var data = details.data;
      var bin = pwEncodeBinaryBody(data);
      if (typeof data === "string") { req.data = data; }
      else if (bin) {
        req.data = bin.data; req.dataIsBase64 = true;   // bytes verbatim across the bridge
      } else if (data != null && typeof W.URLSearchParams === "function" && data instanceof W.URLSearchParams) {
        req.data = data.toString();
        if (!hasCT()) { req.headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"; }
      } else if (data != null && typeof W.FormData === "function" && data instanceof W.FormData) {
        var pairs = [];
        data.forEach(function (v, k) { if (typeof v === "string") { pairs.push(encodeURIComponent(k) + "=" + encodeURIComponent(v)); } });
        req.data = pairs.join("&");
        if (!hasCT()) { req.headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"; }
      } else if (data != null) {
        try { req.data = _JSON.stringify(data); } catch (e) { req.data = String(data); }
      }
      return req;
    }
    function GM_xmlhttpRequest(details) {
      details = details || {};
      var entry = { resolve: null, reject: null };
      var vault = W.__bbPageGM;
      if (!vault || typeof vault.xhr !== "function") {
        // No vault (handler unavailable) — fail closed with an onerror, like the isolated path's reject.
        var er = { error: "BrownBear page-world XHR unavailable", readyState: 4 };
        xhrSafeCall(details.onerror, er); return { abort: function () {} };
      }
      var requestId = vault.xhr(function (type, payload) {
        var resp = xhrBuildResponse(payload || {}, details.responseType);
        resp.context = details.context;
        switch (type) {
          case "loadstart": xhrSafeCall(details.onloadstart, resp); break;
          case "progress": xhrSafeCall(details.onprogress, resp); break;
          case "readystatechange": xhrSafeCall(details.onreadystatechange, resp); break;
          case "load": xhrSafeCall(details.onload, resp); if (entry.resolve) { entry.resolve(resp); } break;
          case "error": xhrSafeCall(details.onerror, resp); if (entry.reject) { entry.reject(resp); } break;
          case "timeout": xhrSafeCall(details.ontimeout, resp); if (entry.reject) { entry.reject(resp); } break;
          case "abort": xhrSafeCall(details.onabort, resp); if (entry.reject) { entry.reject(resp); } break;
          case "loadend": xhrSafeCall(details.onloadend, resp); if (typeof vault.xhrDone === "function") { vault.xhrDone(requestId); } break;
          default: break;
        }
      });
      pageGM("GM_xmlhttpRequest", { requestId: requestId, request: xhrSerialize(details) });
      return { _entry: entry, abort: function () { pageGM("GM_abortRequest", { requestId: requestId }); } };
    }

    // --- GM_download (page world) ---------------------------------------------------------------
    // Same model as the page-world GM_xmlhttpRequest: register a streaming handler on the vault (which mints
    // an unguessable id the page can't predict), post the request through the vault with that id, and native
    // streams the download's lifecycle (progress/load/error/abort/timeout) back via window.__bbPageXHR — a
    // native→page eval, NOT a DOM channel. native @connect-gates the URL host. TM/VM: details OR (url, name).
    function GM_download(arg1, arg2) {
      var d = (arg1 && typeof arg1 === "object") ? arg1 : { url: arg1, name: arg2 };
      var vault = W.__bbPageGM;
      if (!vault || typeof vault.xhr !== "function") {
        xhrSafeCall(d.onerror, { error: "BrownBear page-world download unavailable" });
        return { abort: function () {} };
      }
      var done = false;
      var requestId = vault.xhr(function (type, payload) {
        var p = payload || {};
        switch (type) {
          case "progress": xhrSafeCall(d.onprogress, p); break;
          case "timeout": xhrSafeCall(d.ontimeout, p); finish(); break;
          case "error": xhrSafeCall(d.onerror, p); finish(); break;
          case "abort": xhrSafeCall(d.onabort || d.onerror, p); finish(); break;
          case "load": xhrSafeCall(d.onload, p); finish(); break;
          default: break;
        }
      });
      function finish() {
        if (done) { return; }
        done = true;
        if (typeof vault.xhrDone === "function") { vault.xhrDone(requestId); }
      }
      var payload = {
        requestId: requestId, url: typeof d.url === "string" ? d.url : String(d.url),
        name: d.name || "", headers: d.headers || {}, saveAs: !!d.saveAs
      };
      if (d.timeout) { payload.timeout = d.timeout; }
      pageGM("GM_download", payload);
      return { abort: function () { pageGM("GM_downloadAbort", { requestId: requestId }); } };
    }

    // --- GM_registerMenuCommand / GM_unregisterMenuCommand (page world) -------------------------
    // The command lives in the native "•••" menu; when the user taps it, native streams back via the
    // vault's minted-id channel (window.__bbPageXHR(commandId, "menu")) to the callback registered here.
    // The vault-minted id IS the command id (unguessable, page can't forge a tap). The handler PERSISTS
    // (a command fires on every tap) until GM_unregisterMenuCommand reaps it. TM/VM signature parity.
    function GM_registerMenuCommand(title, callback, optionsOrAccessKey) {
      if (typeof callback !== "function") { return null; }
      var vault = W.__bbPageGM;
      if (!vault || typeof vault.xhr !== "function") { return null; }
      var accessKey = null, autoClose = true;
      if (typeof optionsOrAccessKey === "string") {
        accessKey = optionsOrAccessKey;
      } else if (optionsOrAccessKey && typeof optionsOrAccessKey === "object") {
        if (typeof optionsOrAccessKey.accessKey === "string") { accessKey = optionsOrAccessKey.accessKey; }
        if (optionsOrAccessKey.autoClose === false) { autoClose = false; }
      }
      var commandId = vault.xhr(function (type) {
        if (type === "menu") { try { callback(); } catch (e) { /* a command must not break delivery */ } }
      });
      pageGM("GM_registerMenuCommand", {
        commandId: commandId, title: String(title == null ? "" : title),
        accessKey: accessKey, autoClose: autoClose
      });
      return commandId;
    }
    function GM_unregisterMenuCommand(commandId) {
      var id = String(commandId);
      pageGM("GM_unregisterMenuCommand", { commandId: id });
      if (typeof W.__bbPageGM.xhrDone === "function") { W.__bbPageGM.xhrDone(id); }
    }

    // --- GM_openInTab (page world) --------------------------------------------------------------
    // Opens a tab and returns a REAL handle (TM/VM parity): close() dismisses it, and native fires the
    // handle's onclose + flips .closed when the tab later goes away (any path). The vault mints the openId
    // (which IS the streaming id); native streams the close back via window.__bbPageXHR(openId, "close").
    function GM_openInTab(url, options) {
      var active;
      if (typeof options === "boolean") { active = !options; }
      else if (options && typeof options === "object") { active = options.active !== false; }
      else { active = true; }
      var handle = { closed: false, onclose: null, close: function () {} };
      var vault = W.__bbPageGM;
      if (!vault || typeof vault.xhr !== "function") { handle.closed = true; return handle; }
      var openId = vault.xhr(function (type) {
        if (type !== "close") { return; }
        handle.closed = true;
        if (typeof vault.xhrDone === "function") { vault.xhrDone(openId); }
        if (typeof handle.onclose === "function") { try { handle.onclose(); } catch (e) { /* ignore */ } }
      });
      handle.close = function () { pageGM("GM_closeTab", { openId: openId }); };
      pageGM("GM_openInTab", { url: typeof url === "string" ? url : String(url), active: active, openId: openId });
      return handle;
    }

    // --- GM_notification (page world) -----------------------------------------------------------
    // Posts a banner and returns a control with .remove(). It's BOTH a reply (the native id, for clear) AND
    // a stream (click/close): we register a vault handler (minted streamId) for the click/close events, then
    // post GM_notification via the vault's request→REPLY channel to get the native id back. native streams
    // window.__bbPageXHR(streamId, "click"|"close") on tap/dismiss → the script's onclick/ondone/onclose.
    function pwNormalizeNotification(arg1, arg2, arg3, arg4) {
      if (arg1 && typeof arg1 === "object") {
        var d = arg1;
        return { title: d.title, text: (d.text != null ? d.text : d.message), image: d.image,
          silent: !!d.silent, timeout: d.timeout, id: d.id,
          onclick: d.onclick, ondone: d.ondone, onclose: d.onclose, oncreate: d.oncreate };
      }
      return { text: arg1, title: arg2, image: arg3, onclick: arg4 };
    }
    function GM_notification(arg1, arg2, arg3, arg4) {
      var n = pwNormalizeNotification(arg1, arg2, arg3, arg4);
      var control = { remove: function () { return _Promise.resolve(); } };
      var vault = W.__bbPageGM;
      if (!vault || typeof vault.xhr !== "function" || typeof vault.reply !== "function") { return control; }
      var wantClick = (typeof n.onclick === "function") || (typeof n.ondone === "function")
        || (typeof n.onclose === "function");
      var streamId = vault.xhr(function (type) {
        if (type === "click") { xhrSafeCall(n.onclick); }
        else if (type === "close") { xhrSafeCall(n.ondone); xhrSafeCall(n.onclose); if (typeof vault.xhrDone === "function") { vault.xhrDone(streamId); } }
      });
      var details = { title: n.title, text: n.text, silent: n.silent };
      vault.reply(cfg.token, "GM_notification", { details: details, id: n.id || null, wantClick: wantClick, streamId: streamId },
        function (res) {
          var id = res && res.id;
          if (!id) { if (typeof vault.xhrDone === "function") { vault.xhrDone(streamId); } return; }
          control.remove = function () {
            if (typeof vault.xhrDone === "function") { vault.xhrDone(streamId); }
            pageGM("GM_notificationClear", { id: id });
            return _Promise.resolve();
          };
          xhrSafeCall(n.oncreate, id);
        },
        function () { if (typeof vault.xhrDone === "function") { vault.xhrDone(streamId); } });
      return control;
    }

    // --- GM_cookie / GM_getTab / GM_saveTab / GM_listTabs (request → REPLY) ----------------------
    // One-shot APIs that return data (cookies are sensitive cross-origin data; tab objects the script's
    // own). The request goes out via the vault; native runs it (@connect-gated for cookies) and RETURNS
    // the result through the WKScriptMessageHandlerWithReply reply promise, which the vault settles via a
    // pristine `.then` into the caller's closure — never on the DOM, never through a page-tamperable `.then`.
    function pageReply(api, payload, cb, errcb) {
      var vault = W.__bbPageGM;
      if (vault && typeof vault.reply === "function") { vault.reply(cfg.token, api, payload, cb, errcb); }
      else if (errcb) { errcb("page-world GM unavailable"); }
    }
    function cookieAction(action, details) {
      return new _Promise(function (resolve, reject) {
        pageReply("GM_cookie", { action: action, details: details || {} }, resolve, reject);
      });
    }
    var GM_cookie = {
      list: function (details, cb) {
        var p = cookieAction("list", details);
        if (typeof cb === "function") { p.then(function (r) { cb(r, undefined); }, function (e) { cb(undefined, String(e)); }); }
        return p;
      },
      set: function (details, cb) {
        var p = cookieAction("set", details);
        if (typeof cb === "function") { p.then(function () { cb(undefined); }, function (e) { cb(String(e)); }); }
        return p;
      },
      delete: function (details, cb) {
        var p = cookieAction("delete", details);
        if (typeof cb === "function") { p.then(function () { cb(undefined); }, function (e) { cb(String(e)); }); }
        return p;
      }
    };
    function GM_getTab(callback) {
      pageReply("GM_getTab", {}, function (json) {
        var obj = (typeof json === "string") ? (function () { try { return _JSON.parse(json) || {}; } catch (e) { return {}; } })() : (json || {});
        if (typeof callback === "function") { callback(obj); }
      }, function () { if (typeof callback === "function") { callback({}); } });
    }
    function GM_saveTab(obj, callback) {
      var json;
      try { json = _JSON.stringify(obj == null ? {} : obj); } catch (e) { json = "{}"; }
      pageReply("GM_saveTab", { value: json },
        function () { if (typeof callback === "function") { callback(); } },
        function () { if (typeof callback === "function") { callback(); } });
    }
    function GM_listTabs(callback) {
      pageReply("GM_listTabs", {}, function (map) {
        var out = {};
        if (map && typeof map === "object") {
          _Object.keys(map).forEach(function (k) {
            var parsed = (typeof map[k] === "string") ? (function () { try { return _JSON.parse(map[k]); } catch (e) { return {}; } })() : map[k];
            out[k] = parsed || {};
          });
        }
        if (typeof callback === "function") { callback(out); }
      }, function () { if (typeof callback === "function") { callback({}); } });
    }

    var GM_info = cfg.info || {};
    if (!GM_info.scriptHandler) { GM_info.scriptHandler = "BrownBear"; }
    (function deepFreeze(o) {
      if (o && typeof o === "object") {
        _Object.keys(o).forEach(function (k) { var v = o[k]; if (v && typeof v === "object") { deepFreeze(v); } });
        try { _Object.freeze(o); } catch (e) { /* frozen-already / host obj */ }
      }
      return o;
    })(GM_info);

    var GM = {
      info: GM_info,
      getValue: function (k, d) { return _Promise.resolve(GM_getValue(k, d)); },
      setValue: function (k, v) { GM_setValue(k, v); return _Promise.resolve(); },
      deleteValue: function (k) { GM_deleteValue(k); return _Promise.resolve(); },
      listValues: function () { return _Promise.resolve(GM_listValues()); },
      getValues: function (s) { return _Promise.resolve(GM_getValues(s)); },
      setValues: function (o) { GM_setValues(o); return _Promise.resolve(); },
      deleteValues: function (k) { GM_deleteValues(k); return _Promise.resolve(); },
      addValueChangeListener: function (k, fn) { return GM_addValueChangeListener(k, fn); },
      removeValueChangeListener: function (id) { GM_removeValueChangeListener(id); },
      setClipboard: function (d, i) { GM_setClipboard(d, i); return _Promise.resolve(); },
      addStyle: function (c) { return _Promise.resolve(GM_addStyle(c)); },
      addElement: function () { return _Promise.resolve(GM_addElement.apply(null, arguments)); },
      getResourceText: function (n) { return _Promise.resolve(GM_getResourceText(n)); },
      getResourceUrl: function (n) { return _Promise.resolve(GM_getResourceURL(n)); },
      getResourceURL: function (n) { return _Promise.resolve(GM_getResourceURL(n)); },
      log: function () { GM_log.apply(null, arguments); return _Promise.resolve(); },
      xmlHttpRequest: function (details) {
        var handle = GM_xmlhttpRequest(details);
        var promise = new _Promise(function (resolve, reject) { handle._entry.resolve = resolve; handle._entry.reject = reject; });
        promise.abort = handle.abort;
        return promise;
      },
      cookie: GM_cookie,
      getTab: function () { return new _Promise(function (resolve) { GM_getTab(resolve); }); },
      saveTab: function (obj) { return new _Promise(function (resolve) { GM_saveTab(obj, function () { resolve(); }); }); },
      listTabs: function () { return new _Promise(function (resolve) { GM_listTabs(resolve); }); },
      download: function () { return GM_download.apply(null, arguments); },
      registerMenuCommand: function () { return GM_registerMenuCommand.apply(null, arguments); },
      unregisterMenuCommand: function () { return GM_unregisterMenuCommand.apply(null, arguments); },
      openInTab: function () { return GM_openInTab.apply(null, arguments); },
      notification: function () { return GM_notification.apply(null, arguments); }
    };

    var registry = {
      GM_getValue: GM_getValue, GM_listValues: GM_listValues, GM_getValues: GM_getValues,
      GM_setValue: GM_setValue, GM_deleteValue: GM_deleteValue, GM_setValues: GM_setValues,
      GM_deleteValues: GM_deleteValues, GM_setClipboard: GM_setClipboard, GM_log: GM_log,
      GM_addValueChangeListener: GM_addValueChangeListener,
      GM_removeValueChangeListener: GM_removeValueChangeListener,
      GM_getResourceText: GM_getResourceText, GM_getResourceURL: GM_getResourceURL,
      GM_getResourceUrl: GM_getResourceURL, GM_addStyle: GM_addStyle, GM_addElement: GM_addElement,
      GM_xmlhttpRequest: GM_xmlhttpRequest, GM_cookie: GM_cookie, GM_getTab: GM_getTab,
      GM_saveTab: GM_saveTab, GM_listTabs: GM_listTabs, GM_download: GM_download,
      GM_registerMenuCommand: GM_registerMenuCommand, GM_unregisterMenuCommand: GM_unregisterMenuCommand,
      GM_openInTab: GM_openInTab, GM_notification: GM_notification, GM_info: GM_info
    };

    // A console that writes to the page's real console AND forwards to the dashboard Logs via the vault,
    // so console.* from a page-world script still appears in the Logs tab (parity with the isolated world;
    // no debugging regression from running in the page world). The "log" api is ungated natively.
    var _pc = W.console || {};
    function fwd(method, level) {
      return function () {
        try { if (typeof _pc[method] === "function") { _pc[method].apply(_pc, arguments); } } catch (e) { /* ignore */ }
        var parts = [].slice.call(arguments).map(function (a) {
          return typeof a === "string" ? a : (function () { try { return _JSON.stringify(a); } catch (e) { return String(a); } })();
        });
        pageGM("log", { level: level, message: parts.join(" ") });
      };
    }
    var scriptConsole = {};
    ["dir", "dirxml", "table", "group", "groupCollapsed", "groupEnd", "count", "countReset",
     "time", "timeEnd", "timeLog", "assert", "clear"].forEach(function (m) {
      scriptConsole[m] = (typeof _pc[m] === "function") ? _pc[m].bind(_pc) : function () {};
    });
    scriptConsole.log = fwd("log", "info");
    scriptConsole.info = fwd("info", "info");
    scriptConsole.warn = fwd("warn", "warn");
    scriptConsole.error = fwd("error", "error");
    scriptConsole.debug = fwd("debug", "debug");
    scriptConsole.trace = fwd("trace", "debug");

    // SPA URL tracking (window.onurlchange + a 'urlchange' event), installed ONCE per page. In the page
    // world `window` IS the page window, so patching its history.pushState/replaceState + listening to
    // popstate/hashchange catches every navigation directly, and the script's window.onurlchange handler
    // fires with { url } (Tampermonkey parity; a script @grants window.onurlchange to use it).
    (function installPageUrlChange() {
      if (W.__bbPageUrlChangeOn) { return; }
      W.__bbPageUrlChangeOn = true;
      var hist = W.history, loc = W.location, _CE = W.CustomEvent, last = "";
      try { last = (loc && loc.href) || ""; } catch (e) { last = ""; }
      function emit() {
        var href = "";
        try { href = (loc && loc.href) || ""; } catch (e) { href = ""; }
        if (href === last) { return; }
        last = href;
        try { if (typeof _CE === "function") { W.dispatchEvent(new _CE("urlchange", { detail: { url: href } })); } } catch (e) { /* ignore */ }
        try { var h = W.onurlchange; if (typeof h === "function") { h.call(W, { url: href }); } } catch (e) { /* ignore */ }
      }
      if (hist) {
        ["pushState", "replaceState"].forEach(function (name) {
          var orig = hist[name];
          if (typeof orig !== "function" || orig.__bbWrapped) { return; }
          var wrapped = function () { var r = orig.apply(this, arguments); _Promise.resolve().then(emit); return r; };
          wrapped.__bbWrapped = true;
          try { hist[name] = wrapped; } catch (e) { /* non-configurable — events still cover it */ }
        });
      }
      try { W.addEventListener("popstate", function () { _Promise.resolve().then(emit); }, true); } catch (e) { /* ignore */ }
      try { W.addEventListener("hashchange", function () { _Promise.resolve().then(emit); }, true); } catch (e) { /* ignore */ }
    })();

    var unsafeWindow = W;
    var args = [unsafeWindow, GM, GM_info, scriptConsole, W];
    (cfg.grants || []).forEach(function (g) { args.push(registry[g]); });
    try { bodyFn.apply(W, args); }
    catch (e) {
      try { if (W.console && W.console.error) { W.console.error("[BrownBear] error running \"" + (cfg.name || "script") + "\":", e); } } catch (e2) { /* ignore */ }
    }
  }

  // Build the source native evaluates in the page's MAIN world for a GRANTED page-world script: an inline
  // call to the self-contained pageWorldGMClient with the pre-seeded config + the script body wrapped in a
  // real function literal (NOT eval — so a page's strict CSP unsafe-eval cannot block it; native eval into
  // .page is itself CSP-immune). The body function's parameter list mirrors the isolated `new Function`
  // surface (unsafeWindow, GM, GM_info, console, window, then each granted page-safe GM_* name in order),
  // and the client passes the matching page-world implementations.
  function buildGrantedPageWorldSource(data, body) {
    var seen = _Object.create(null), gnames = [];
    (data.grants || []).forEach(function (g) {
      var n = normGrant(g);
      if (PAGE_WORLD_SAFE_GRANTS[n] && !seen[n]) { seen[n] = true; gnames.push(n); }
    });
    var cfg = {
      // token authenticates own-data writes to native via the vault; it lives only in the page-world
      // closure (never on the DOM) and is useless without the non-configurable vault binding.
      token: data.token, name: data.name || "script",
      info: data.info || {}, values: data.values || {}, resources: data.resources || {}, grants: gnames
    };
    var cfgJSON = "{}";
    try { cfgJSON = _JSON.stringify(cfg); } catch (e) { cfgJSON = "{}"; }
    // `body` already ends with its own //# sourceURL (added in run()), so errors thrown in the page world
    // attribute to the script — no extra tag needed here.
    var paramList = ["unsafeWindow", "GM", "GM_info", "console", "window"].concat(gnames).join(", ");
    return "(" + pageWorldGMClient.toString() + ")(\n" + cfgJSON + ",\n" +
      "function (" + paramList + ") {\n" + body + "\n});";
  }

  // Build the self-contained source native evaluates in the page's MAIN world (WKContentWorld.page).
  // There `window` IS the page's window, so unsafeWindow === window and the page's own globals are
  // visible. Only the grant-none surface is provided: GM_info as inert data, a GM object carrying just
  // `.info` (GM.* methods require grants, which this path doesn't have), and the page's own `console`
  // (left to resolve to the page global — already captured for the Logs "Page" filter). The body runs
  // inside its own function so its var/const/let declarations don't leak onto the page, mirroring the
  // isolated world's `new Function` wrapper. Native eval (not an inline <script>) keeps this CSP-immune.
  // SPA URL tracking (window.onurlchange + a 'urlchange' event) as a self-contained source string for the
  // grant-none page-world path (which is built as a string, not the pageWorldGMClient function). Mirrors
  // installUrlChangeTracking (isolated) / installPageUrlChange (granted page world): wrap history.pushState/
  // replaceState + listen for popstate/hashchange, fire ONCE per page (guarded by window.__bbPageUrlChangeOn
  // so a page with several BrownBear page-world scripts installs it once). Tampermonkey parity.
  var PAGE_URLCHANGE_SRC =
    "(function(){if(window.__bbPageUrlChangeOn){return;}window.__bbPageUrlChangeOn=true;" +
    "var hist=window.history,loc=window.location,_CE=window.CustomEvent,_P=window.Promise,last='';" +
    "try{last=(loc&&loc.href)||'';}catch(e){last='';}" +
    "function defer(fn){if(_P){_P.resolve().then(fn);}else{setTimeout(fn,0);}}" +
    "function emit(){var href='';try{href=(loc&&loc.href)||'';}catch(e){href='';}if(href===last){return;}last=href;" +
    "try{if(typeof _CE==='function'){window.dispatchEvent(new _CE('urlchange',{detail:{url:href}}));}}catch(e){}" +
    "try{var h=window.onurlchange;if(typeof h==='function'){h.call(window,{url:href});}}catch(e){}}" +
    "if(hist){['pushState','replaceState'].forEach(function(n){var o=hist[n];" +
    "if(typeof o!=='function'||o.__bbWrapped){return;}" +
    "var w=function(){var r=o.apply(this,arguments);defer(emit);return r;};w.__bbWrapped=true;" +
    "try{hist[n]=w;}catch(e){}});}" +
    "try{window.addEventListener('popstate',function(){defer(emit);},true);}catch(e){}" +
    "try{window.addEventListener('hashchange',function(){defer(emit);},true);}catch(e){}" +
    "})();\n";

  function buildPageWorldSource(data, body) {
    var infoJSON = "{}";
    try { infoJSON = _JSON.stringify(data.info || {}); } catch (e) { infoJSON = "{}"; }
    return "(function(){\n" +
      "\"use strict\";\n" +
      PAGE_URLCHANGE_SRC +
      "var unsafeWindow = window;\n" +
      "var GM_info = " + infoJSON + ";\n" +
      "if (!GM_info.scriptHandler) { GM_info.scriptHandler = \"BrownBear\"; }\n" +
      "var GM = { info: GM_info };\n" +
      "(function (unsafeWindow, GM, GM_info, window) {\n" +
      body + "\n" +
      "}).call(window, unsafeWindow, GM, GM_info, window);\n" +
      "})();";
  }

  function run(data) {
    var token = data.token;
    return _Promise.all([loadRequires(data.requires, token, data.inlinedRequires),
                         loadResources(data.resources, token, data.inlinedResources)])
      .then(function (loaded) {
      var requireCode = loaded[0];
      data.resources = loaded[1];   // name -> { text, url } (fetched natively)

      var sourceURL = "//# sourceURL=brownbear://" + encodeURIComponent(data.name || "script") + ".user.js";
      var body = (requireCode ? requireCode + "\n;\n" : "") + data.source + "\n" + sourceURL;

      // Route by world. `injectPageWorld` hands the source to native to evaluate in this frame's real
      // page world (CSP-immune), where `window`/`unsafeWindow` are the page's own globals. The bridge
      // call is reachable only from this isolated world and native re-gates it on a valid session token.
      var plan = pageWorldPlan(data);

      // @grant none, page/auto: inert GM, page-world body (the canonical "@grant none ⇒ real window").
      if (plan === "page-grantless") {
        var pageSource = buildPageWorldSource(data, body);
        bridge("injectPageWorld", { code: pageSource }, token).catch(function (e) {
          _console.error("[BrownBear] page-world inject failed for \"" + (data.name || "script") + "\":", e);
        });
        return;
      }

      // GRANTED page/auto with only page-world-safe grants: run in the page world WITH a working GM
      // surface so unsafeWindow === window and the page's own globals are visible (Violentmonkey parity).
      // Value/resource reads are served synchronously from a cache pre-seeded into the page-world source;
      // GM_addStyle/GM_addElement run on the page DOM. No token or native channel is handed to the page.
      if (plan === "page-granted") {
        var grantedSource = buildGrantedPageWorldSource(data, body);
        bridge("injectPageWorld", { code: grantedSource }, token).catch(function (e) {
          _console.error("[BrownBear] granted page-world inject failed for \"" + (data.name || "script") + "\":", e);
        });
        return;
      }

      // plan === "isolated": the GM bridge lives only here. Run the body via `new Function` with the
      // isolated window as unsafeWindow/window.
      var env = buildGM(data);
      var grantNone = !!data.grantNone;
      var grants = data.grants || [];
      var grantSet = _Object.create(null);
      grants.forEach(function (g) { grantSet[g] = true; });

      // An explicit @inject-into page that takes a GM grant outside the page-world-safe set — a
      // callback-streaming API (GM_cookie, GM_download, GM_notification, menu/tab, value-change
      // listeners) — runs isolated; surface why, so an author knows unsafeWindow isn't the page window
      // for this script (those still need native→world streaming; a page-world path for them is coming).
      if (!grantNone && data.injectInto === "page") {
        try {
          makeConsole(token).warn("[BrownBear] \"@inject-into page\" runs in the page world with @grant " +
            "none or page-world-safe grants (value reads/writes, GM_getResource*, GM_addStyle/" +
            "GM_addElement, GM_setClipboard, GM_log, GM_xmlhttpRequest). This script grants a " +
            "callback-streaming API (e.g. GM_cookie/GM_download/GM_notification), so it runs in the " +
            "isolated world (unsafeWindow is the isolated window).");
        } catch (e) { /* logging must never break injection */ }
      }

      var scriptConsole = makeConsole(token);
      var argNames = ["unsafeWindow", "GM", "GM_info", "console", "window"];
      var argVals = [W, env.GM, env.GM_info, scriptConsole, W];

      if (!grantNone) {
        _Object.keys(env.registry).forEach(function (name) {
          if (grantSet[name]) { argNames.push(name); argVals.push(env.registry[name]); }
        });
      }

      try {
        var fn = _Function.apply(null, argNames.concat([body]));
        fn.apply(W, argVals);
      } catch (e) {
        _console.error("[BrownBear] error running \"" + (data.name || "script") + "\":", e);
      }
    });
  }

  // --- Loader (PRIVATE) -----------------------------------------------------------------------
  // Asks native which scripts match this URL, then runs each at the right @run-at moment. The
  // critical WebKit detail: async-evaluated injected scripts often start AFTER DOMContentLoaded
  // has fired, so we branch on document.readyState first, every time.
  function runAll(scripts) {
    for (var i = 0; i < scripts.length; i += 1) {
      try { run(scripts[i]); } catch (e) {
        if (_console.error) { _console.error("[BrownBear] run error:", e); }
      }
    }
  }
  function whenDOMReady(cb) {
    if (document.readyState === "interactive" || document.readyState === "complete") { cb(); }
    else { document.addEventListener("DOMContentLoaded", cb, { once: true }); }
  }
  // @run-at document-idle. Violentmonkey/Tampermonkey fire idle scripts right after DOMContentLoaded —
  // NOT at the window `load` event, which waits for every image and subresource and can land many
  // seconds later. We mirror VM exactly (inject.js: `await injectAll('end'); await injectAll('idle')`
  // where idle additionally `await nextTask()`): once the DOM is ready, yield ONE macrotask so the
  // page's own DOMContentLoaded handlers and our document-end scripts run first, then run. This is the
  // difference between "feels as instant as Violentmonkey" and "runs only after the whole page paints".
  function nextMacroTask(cb) {
    if (_MessageChannel) {
      try {
        var ch = new _MessageChannel();
        ch.port1.onmessage = function () { try { ch.port1.close(); } catch (e) { /* ignore */ } cb(); };
        ch.port2.postMessage(0);
        return;
      } catch (e) { /* MessageChannel blocked — fall through */ }
    }
    if (_setTimeout) { _setTimeout(cb, 0); return; }
    _Promise.resolve().then(cb);   // last resort: a microtask still beats waiting for `load`
  }
  function whenIdle(cb) {
    whenDOMReady(function () { nextMacroTask(cb); });
  }

  function loadAndRun() {
    var isSubframe = false;
    try { isSubframe = W.top !== W.self; } catch (e) { isSubframe = true; }
    bridge("getScripts", { url: location.href, isSubframe: isSubframe }, null)
      .then(function (scripts) {
        if (!scripts || !scripts.length) { return; }
        var starts = [], ends = [], idles = [], allTokens = [];
        for (var i = 0; i < scripts.length; i += 1) {
          var s = scripts[i];
          if (s.token) { allTokens.push(s.token); }
          if (s.runAt === "document-start") { starts.push(s); }
          else if (s.runAt === "document-idle") { idles.push(s); }
          else { ends.push(s); }
        }
        // WebKit's back-forward cache restores this document WITHOUT re-running document-start
        // scripts: the userscripts above keep running, but native purged their session tokens when
        // the tab navigated away — every later GM_* call then fails ("unrecognized or missing script
        // token") on exactly the pages reached via back/forward. Re-register this document's tokens
        // on every persisted pageshow (native revives them from its own tombstones).
        if (allTokens.length) {
          W.addEventListener("pageshow", function (ev) {
            if (!ev || !ev.persisted) { return; }
            bridge("revalidateSessions", { tokens: allTokens }, null).catch(function () {});
          });
        }
        if (starts.length) { runAll(starts); }
        if (ends.length) { whenDOMReady(function () { runAll(ends); }); }
        if (idles.length) { whenIdle(function () { runAll(idles); }); }
      })
      .catch(function (e) {
        if (_console.error) { _console.error("[BrownBear] loader error:", e); }
      });
  }

  // Apply a value change native forwarded from another frame/tab running the same script. The
  // payload is a JSON string: { token, key, old, new } where old/new are JSON-encoded values
  // (new === null means the key was deleted; a value set to JSON null arrives as the string "null").
  function applyRemoteValueChange(payloadJSON) {
    var p = safeParse(payloadJSON);
    if (!p || typeof p.token !== "string") { return; }
    var env = valueEnvByToken[p.token];
    if (!env) { return; }
    var oldVal = (p.old == null) ? undefined : safeParse(p.old);
    if (p.new == null) {
      delete env.cache[p.key];
      env.fire(p.key, oldVal, undefined, true);
    } else {
      env.cache[p.key] = p.new;
      env.fire(p.key, oldVal, safeParse(p.new), true);
    }
  }

  // Native (which minted the token) invokes a tapped GM_registerMenuCommand callback in THIS frame/
  // world. A page can't reach this object (isolated world) and can't name another script's token.
  function fireMenuCommand(token, commandId) {
    var reg = menuCommandsByToken[token];
    if (!reg) { return; }
    var cb = reg[commandId];
    if (typeof cb !== "function") { return; }
    try { cb(); } catch (e) { _console.error("[BrownBear] menu command error:", e); }
  }

  // Only these are exposed; bridge/getScripts/run remain private to this closure. applyValueChange
  // is reachable from native (in this isolated world) to deliver cross-frame/tab value changes.
  W.__brownbear = {
    dispatchXHR: dispatchXHR,
    applyValueChange: applyRemoteValueChange,
    dispatchNotification: dispatchNotification,
    dispatchDownload: dispatchDownload,
    dispatchTabClosed: dispatchTabClosed,
    fireMenuCommand: fireMenuCommand
  };

  loadAndRun();
})();
