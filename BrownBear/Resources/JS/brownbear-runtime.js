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
  var _atob = W.atob ? W.atob.bind(W) : null;
  var _fetch = W.fetch ? W.fetch.bind(W) : null;
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
        resp.response = (rt === "blob") ? new Blob([bytes]) : bytes.buffer;
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
    req.headers = _Object.assign({}, details.headers || {});   // clone so we can default Content-Type
    function hasContentType() {
      for (var hk in req.headers) { if (hk.toLowerCase() === "content-type") { return true; } }
      return false;
    }
    var data = details.data;
    if (typeof data === "string") { req.data = data; }
    else if (data != null && typeof URLSearchParams === "function" && data instanceof URLSearchParams) {
      req.data = data.toString();   // x-www-form-urlencoded, NOT JSON
      if (!hasContentType()) { req.headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"; }
    } else if (data != null && typeof FormData === "function" && data instanceof FormData) {
      // Serialize text fields as urlencoded (file parts aren't supported over this sync path).
      var pairs = [];
      data.forEach(function (v, k) { if (typeof v === "string") { pairs.push(encodeURIComponent(k) + "=" + encodeURIComponent(v)); } });
      req.data = pairs.join("&");
      if (!hasContentType()) { req.headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"; }
    } else if (data != null) {
      // Don't JSON.stringify ArrayBuffers/typed arrays into "{}" — send their string form; a real string
      // body should be passed as a string (handled above). Objects still serialize to JSON.
      if (data instanceof ArrayBuffer || (data.buffer instanceof ArrayBuffer)) { req.data = String(data); }
      else { try { req.data = _JSON.stringify(data); } catch (e) { req.data = String(data); } }
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
      var style = document.createElement("style");
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
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
      call("GM_openInTab", { url: url, active: active });
      return { closed: false, onclose: null, close: function () {} };
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
        GM_download(d);
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
  //   • @inject-into content        → always the isolated world (current behavior).
  //   • @inject-into page / auto     → the page world ONLY when the script takes NO GM grants
  //                                    (@grant none). A granted script needs the GM bridge, which is
  //                                    reachable solely from this isolated world, so it stays here.
  // The grant-none page case is exactly the canonical "@grant none ⇒ real window" idiom users rely on.
  function wantsPageWorld(data) {
    var into = data.injectInto || "auto";
    if (into === "content") { return false; }
    return !!data.grantNone;   // page or auto → page world iff there are no grants to bridge
  }

  // Build the self-contained source native evaluates in the page's MAIN world (WKContentWorld.page).
  // There `window` IS the page's window, so unsafeWindow === window and the page's own globals are
  // visible. Only the grant-none surface is provided: GM_info as inert data, a GM object carrying just
  // `.info` (GM.* methods require grants, which this path doesn't have), and the page's own `console`
  // (left to resolve to the page global — already captured for the Logs "Page" filter). The body runs
  // inside its own function so its var/const/let declarations don't leak onto the page, mirroring the
  // isolated world's `new Function` wrapper. Native eval (not an inline <script>) keeps this CSP-immune.
  function buildPageWorldSource(data, body) {
    var infoJSON = "{}";
    try { infoJSON = _JSON.stringify(data.info || {}); } catch (e) { infoJSON = "{}"; }
    return "(function(){\n" +
      "\"use strict\";\n" +
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

      // Page (main) world: hand the source to native to evaluate in this frame's real page world, so
      // `window`/`unsafeWindow` are the page's own globals. buildGM is skipped — a grant-none script
      // has no GM bridge to wire. The injectPageWorld bridge call is reachable only from this isolated
      // world, and native re-gates it on a valid session token.
      if (wantsPageWorld(data)) {
        var pageSource = buildPageWorldSource(data, body);
        bridge("injectPageWorld", { code: pageSource }, token).catch(function (e) {
          _console.error("[BrownBear] page-world inject failed for \"" + (data.name || "script") + "\":", e);
        });
        return;
      }

      var env = buildGM(data);
      var grantNone = !!data.grantNone;
      var grants = data.grants || [];
      var grantSet = _Object.create(null);
      grants.forEach(function (g) { grantSet[g] = true; });

      // An explicit @inject-into page that ALSO takes GM grants can't run in the page world (the GM
      // bridge lives only here), so it runs isolated — surface that instead of silently ignoring the
      // directive, so a script author knows why unsafeWindow isn't the page window.
      if (!grantNone && data.injectInto === "page") {
        try {
          makeConsole(token).warn("[BrownBear] \"@inject-into page\" needs \"@grant none\" for real " +
            "page-window access; with GM grants this script runs in the isolated world (unsafeWindow " +
            "is the isolated window, not the page's).");
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
  function whenLoaded(cb) {
    if (document.readyState === "complete") { cb(); }
    else { W.addEventListener("load", cb, { once: true }); }
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
        if (idles.length) { whenLoaded(function () { runAll(idles); }); }
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
    fireMenuCommand: fireMenuCommand
  };

  loadAndRun();
})();
