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
    if (typeof details.data === "string") { req.data = details.data; }
    else if (details.data != null) {
      try { req.data = _JSON.stringify(details.data); } catch (e) { req.data = String(details.data); }
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
  function loadRequires(requires, token) {
    if (!requires || !requires.length) { return _Promise.resolve(""); }
    return _Promise.all(requires.map(function (url) {
      return bridge("fetchResource", { url: url }, token)
        .then(function (r) { return (r && r.text) || ""; })
        .catch(function () { return ""; });
    })).then(function (codes) { return codes.join("\n;\n"); });
  }

  function loadResources(resources, token) {
    var names = resources ? _Object.keys(resources) : [];
    var out = _Object.create(null);
    if (!names.length) { return _Promise.resolve(out); }
    return _Promise.all(names.map(function (name) {
      var url = resources[name];
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
      _Object.keys(obj).forEach(function (k) { enc[k] = _JSON.stringify(obj[k]); cache[k] = enc[k]; });
      call("GM_setValues", { values: enc });
    }
    function GM_deleteValues(keys) {
      keys.forEach(function (k) { delete cache[k]; });
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

    var GM_info = data.info || {};
    GM_info.scriptHandler = "BrownBear";

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
      log: function () { GM_log.apply(null, arguments); return _Promise.resolve(); },
      xmlHttpRequest: function (details) {
        var handle = startXHR(details, token);
        var promise = new _Promise(function (resolve, reject) {
          handle._entry.resolve = resolve;
          handle._entry.reject = reject;
        });
        promise.abort = handle.abort;
        return promise;
      }
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
        GM_xmlhttpRequest: GM_xmlhttpRequest
      },
      GM: GM,
      GM_info: GM_info
    };
  }

  function run(data) {
    var token = data.token;
    return _Promise.all([loadRequires(data.requires, token), loadResources(data.resources, token)])
      .then(function (loaded) {
      var requireCode = loaded[0];
      data.resources = loaded[1];   // name -> { text, url } (fetched natively)
      var env = buildGM(data);
      var grantNone = !!data.grantNone;
      var grants = data.grants || [];
      var grantSet = _Object.create(null);
      grants.forEach(function (g) { grantSet[g] = true; });

      var scriptConsole = makeConsole(token);
      var argNames = ["unsafeWindow", "GM", "GM_info", "console", "window"];
      var argVals = [W, env.GM, env.GM_info, scriptConsole, W];

      if (!grantNone) {
        _Object.keys(env.registry).forEach(function (name) {
          if (grantSet[name]) { argNames.push(name); argVals.push(env.registry[name]); }
        });
      }

      var sourceURL = "//# sourceURL=brownbear://" + encodeURIComponent(data.name || "script") + ".user.js";
      var body = (requireCode ? requireCode + "\n;\n" : "") + data.source + "\n" + sourceURL;

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
        var starts = [], ends = [], idles = [];
        for (var i = 0; i < scripts.length; i += 1) {
          var s = scripts[i];
          if (s.runAt === "document-start") { starts.push(s); }
          else if (s.runAt === "document-idle") { idles.push(s); }
          else { ends.push(s); }
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

  // Only these are exposed; bridge/getScripts/run remain private to this closure. applyValueChange
  // is reachable from native (in this isolated world) to deliver cross-frame/tab value changes.
  W.__brownbear = { dispatchXHR: dispatchXHR, applyValueChange: applyRemoteValueChange };

  loadAndRun();
})();
