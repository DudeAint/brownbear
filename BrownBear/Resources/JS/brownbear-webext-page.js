//
// brownbear-webext-page.js
//
// The chrome.* runtime for an extension PAGE — a popup (action.default_popup) or an options page —
// loaded in a WKWebView over the chrome-extension:// scheme. Unlike content scripts, a page's own
// <script> tags run at their natural time, so chrome.* must exist SYNCHRONOUSLY before they do.
// Native bakes the identity (token, manifest, baseURL, i18n messages) into window.__bbExtPage at
// document-start; this runtime reads it and assembles chrome.* immediately. Async work (storage,
// messaging the background worker) still flows over the WKScriptMessageHandler bridge.
//

(function () {
  "use strict";
  if (window.__brownbearExtPageReady) { return; }
  var data = window.__bbExtPage;
  if (!data || !data.token) { return; }

  var W = window;
  var _JSON = JSON;
  var _Object = Object;
  var _Array = Array;
  var _Promise = Promise;
  var handler = (W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.brownbearWebext) || null;

  function bridge(api, payload) {
    if (!handler) { return _Promise.reject(new Error("BrownBear extension bridge unavailable")); }
    try { return handler.postMessage({ api: api, payload: payload || {}, token: data.token }); }
    catch (e) { return _Promise.reject(e); }
  }

  // navigator.serviceWorker shim. WKWebView does NOT expose Service Workers for the custom
  // chrome-extension:// scheme, so on a real extension page (e.g. an MV3 offscreen document) any access
  // to `navigator.serviceWorker.*` throws "undefined is not an object" and aborts the whole bundle —
  // ScriptCat's offscreen.js does exactly this at load. Provide a spec-shaped, inert surface so the page
  // degrades gracefully (register() rejects; `ready` stays pending — there is genuinely no SW — and the
  // event/controller surface no-ops) instead of crashing. Defined at document-start, before page scripts.
  (function () {
    try {
      if ("serviceWorker" in W.navigator && W.navigator.serviceWorker) { return; }
      var swListeners = {};
      var sw = {
        controller: null,
        ready: new _Promise(function () {}),   // no active worker → never resolves (spec-correct)
        register: function () { return _Promise.reject(new Error("Service workers are unavailable in this context")); },
        getRegistration: function () { return _Promise.resolve(undefined); },
        getRegistrations: function () { return _Promise.resolve([]); },
        startMessages: function () {},
        addEventListener: function (type, fn) { (swListeners[type] = swListeners[type] || []).push(fn); },
        removeEventListener: function (type, fn) {
          var list = swListeners[type]; if (!list) { return; }
          var i = list.indexOf(fn); if (i >= 0) { list.splice(i, 1); }
        },
        dispatchEvent: function () { return false; },
        oncontrollerchange: null, onmessage: null, onmessageerror: null
      };
      _Object.defineProperty(W.navigator, "serviceWorker", { value: sw, configurable: true, enumerable: false });
    } catch (e) { /* navigator may be locked down; nothing we can do, but don't break the page */ }
  })();

  // Cross-origin fetch from an extension page. Chrome lets an extension page fetch hosts in its
  // host_permissions WITHOUT CORS (the privileged extension-page network path); a WKWebView page enforces
  // CORS, so a manager's install page (e.g. ScriptCat fetching a .user.js from greasyfork) failed with
  // "Load failed". Route host-permitted cross-origin http(s) through the native, host_permission-gated
  // fetch (CORS-free, like Chrome). The native side replies `notPermitted` for hosts the extension didn't
  // declare, and we fall back to the page's normal fetch — so CORS-enabled public APIs still work and
  // there is no regression. Only a string/absent body is forwarded; anything else uses the page's fetch.
  (function () {
    var origFetch = (typeof W.fetch === "function") ? W.fetch.bind(W) : null;
    if (!origFetch || !handler) { return; }
    var extOrigin = W.location.protocol + "//" + W.location.host;   // chrome-extension://<id>
    function headerObject(init, input) {
      var out = {};
      var h = (init && init.headers) || (input && typeof input === "object" && input.headers) || null;
      if (!h) { return out; }
      if (typeof h.forEach === "function") { h.forEach(function (v, k) { out[String(k)] = String(v); }); }
      else { _Object.keys(h).forEach(function (k) { out[k] = String(h[k]); }); }
      return out;
    }
    W.fetch = function (input, init) {
      init = init || {};
      var url, abs;
      try {
        url = (input && typeof input === "object" && input.url != null) ? input.url : String(input);
        abs = new URL(url, W.location.href);
      } catch (e) { return origFetch(input, init); }
      if (abs.origin === extOrigin || (abs.protocol !== "http:" && abs.protocol !== "https:")) {
        return origFetch(input, init);   // own packaged resource (scheme handler) or non-http scheme
      }
      // Body + method follow the init-then-Request-input fallback (like url above). Only a string body is
      // forwarded; anything else (FormData/Blob/stream) uses the page's own fetch.
      var body = (init.body != null) ? init.body
               : ((input && typeof input === "object" && input.body != null) ? input.body : null);
      if (body != null && typeof body !== "string") { return origFetch(input, init); }
      var method = String(init.method || (input && input.method) || "GET").trim().toUpperCase();
      return bridge("hostFetch", { url: abs.href, method: method, headers: headerObject(init, input), body: body })
        .then(function (r) {
          if (r && r.notPermitted) { return origFetch(input, init); }   // not declared → normal CORS fetch
          if (!r || r.error) { throw new TypeError("Failed to fetch" + (r && r.error ? ": " + r.error : "")); }
          var status = r.status || 200;
          var bin = W.atob(r.bodyBase64 || "");
          var bytes = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i) & 0xff; }
          // 204/205/304 are null-body statuses — the Response constructor rejects a body for them.
          var nullBody = (status === 204 || status === 205 || status === 304);
          return new Response(nullBody ? null : bytes,
                              { status: status, statusText: r.statusText || "", headers: r.headers || {} });
        }, function () { return origFetch(input, init); });
    };
  })();

  // Forward the page's own console + uncaught errors to the native extension log. Popup/options
  // failures are otherwise invisible (a blank page with no surfaced reason); this makes them show up
  // in the dashboard's per-extension log. Installed at document-start so it captures the page's own
  // module scripts throwing during init.
  (function () {
    function fmt(args) {
      var parts = [];
      for (var i = 0; i < args.length; i++) {
        var a = args[i];
        if (a instanceof Error) { parts.push(a.message + (a.stack ? "\n" + a.stack : "")); }
        else if (a === null || a === undefined || typeof a !== "object") { parts.push(String(a)); }
        else { try { parts.push(_JSON.stringify(a)); } catch (e) { parts.push(String(a)); } }
      }
      var s = parts.join(" ");
      return s.length > 4000 ? s.slice(0, 4000) + "…" : s;
    }
    function emit(level, args) { try { bridge("runtime.pageLog", { level: level, message: fmt(args) }).catch(function () {}); } catch (e) {} }
    var c = W.console || (W.console = {});
    var map = { log: "info", info: "info", debug: "debug", warn: "warn", error: "error" };
    _Object.keys(map).forEach(function (name) {
      var orig = c[name];
      c[name] = function () {
        emit(map[name], arguments);
        if (typeof orig === "function") { try { orig.apply(c, arguments); } catch (e) {} }
      };
    });
    // Capture phase (true) so FAILED SUB-RESOURCE loads are caught too — a 404'd `<script type=
    // module>` import is the classic "blank page" cause and only surfaces as a non-bubbling error
    // on the element.
    W.addEventListener("error", function (e) {
      var t = e && e.target;
      if (t && t !== W && t.tagName) {
        emit("error", ["Failed to load " + String(t.tagName).toLowerCase() + ": " + (t.src || t.href || "")]);
        return;
      }
      var msg = (e && e.message) ? e.message : "script error";
      if (e && e.filename) { msg += " (" + e.filename + ":" + (e.lineno || 0) + ")"; }
      if (e && e.error && e.error.stack) { msg += "\n" + e.error.stack; }
      emit("error", [msg]);
    }, true);
    W.addEventListener("unhandledrejection", function (e) {
      var r = e && e.reason;
      emit("error", ["Unhandled promise rejection: " + ((r && r.message) ? r.message : String(r))]);
    });
  })();

  var messages = data.messages || {};
  var manifest = {};
  try {
    // Chrome substitutes __MSG_<key>__ in the manifest that getManifest() returns (name, description,
    // action.default_title, …) from the default-locale messages — so an extension that names itself
    // `__MSG_extName__` reads back its real localized name (e.g. Violentmonkey's popup header). Do the same.
    var manifestJSON = (data.manifestJSON || "{}").replace(/__MSG_(@?\w+)__/g, function (token, key) {
      var value = messages[key];
      return (typeof value === "string") ? value : token;
    });
    manifest = _JSON.parse(manifestJSON);
  } catch (e) { manifest = {}; }

  // chrome.runtime.lastError slot for this page. Settable so the message/port paths can set it before
  // invoking a callback (Chrome semantics), then clear it.
  var _bbLastError = null;
  function settle(promise, callback) {
    if (typeof callback === "function") {
      promise.then(function (v) { callback(v); }, function (e) {
        // A `__bbLastError`-tagged rejection populates chrome.runtime.lastError for the callback's
        // duration (Chrome calls the callback with lastError set, then clears it); result undefined.
        if (e && e.__bbLastError) { _bbLastError = { message: e.message }; }
        try { callback(undefined); } finally { _bbLastError = null; }
      });
      return undefined;
    }
    return promise;   // promise form: a tagged rejection propagates (Chrome rejects the promise)
  }

  function makeEvent(list) {
    return {
      addListener: function (fn) { if (typeof fn === "function" && list.indexOf(fn) < 0) { list.push(fn); } },
      removeListener: function (fn) { var i = list.indexOf(fn); if (i >= 0) { list.splice(i, 1); } },
      hasListener: function (fn) { return list.indexOf(fn) >= 0; }
    };
  }

  // chrome.privacy ChromeSetting — same {get,set,clear,onChange} shape the background shim exposes. A
  // popup PAGE has chrome.privacy too, and VeePN's popup reads chrome.privacy.network.webRTCIPHandlingPolicy
  // in a class FIELD INITIALIZER at module-eval; with chrome.privacy missing, that read threw and JSC
  // reported it at the enclosing `super()` ("undefined is not an object (evaluating 'super()')") -> the
  // pre-linked popup bundle aborted. Page-local value (reads report controllable, writes store locally);
  // onChange exists so an extension wrapping a setting in a class can addListener at init without throwing.
  function makePrivacySetting() {
    var _value;
    return {
      get: function (details, cb) { var r = { value: _value, levelOfControl: "controllable_by_this_extension" }; if (typeof cb === "function") { cb(r); return undefined; } return _Promise.resolve(r); },
      set: function (details, cb) { if (details && "value" in details) { _value = details.value; } if (typeof cb === "function") { cb(); return undefined; } return _Promise.resolve(); },
      clear: function (details, cb) { _value = undefined; if (typeof cb === "function") { cb(); return undefined; } return _Promise.resolve(); },
      onChange: makeEvent([])
    };
  }
  var privacyApi = {
    network: { networkPredictionEnabled: makePrivacySetting(), webRTCIPHandlingPolicy: makePrivacySetting() },
    websites: { hyperlinkAuditingEnabled: makePrivacySetting() },
    services: { autofillAddressEnabled: makePrivacySetting(), autofillCreditCardEnabled: makePrivacySetting(), passwordSavingEnabled: makePrivacySetting() }
  };
  // chrome.proxy.settings — a ChromeSetting, same shape as privacy.*. A popup PAGE has chrome.proxy too;
  // VeePN (a VPN) reads chrome.proxy.settings in a class field initializer at module-eval (the next crash
  // after privacy, manifesting as the same JSC `super()` error). The actual per-dataStore proxy control
  // runs in the service worker (chrome.proxy there routes to native iOS 17+ proxyConfigurations); the
  // page surface is the Chrome-correct ChromeSetting so the popup reads/writes without throwing.
  var proxyApi = { settings: makePrivacySetting(), onProxyError: makeEvent([]) };

  // ---- page-shim ⇄ background-shim namespace parity ----
  // A popup/options PAGE carries the SAME chrome.* surface as the background for any namespace the
  // extension is permitted to use. The page shim historically exposed a SUBSET, so a popup that read a
  // background-only namespace at boot — in a property access OR a class field initializer — threw and
  // rendered blank (Tampermonkey: webRequest; VeePN: privacy/proxy). Mirror the remaining page-legitimate
  // namespaces. Surfaces that need a live SW/native (downloads list, idle state, media capture, OS TTS)
  // resolve empty/inert on a short-lived popup; the real work runs in the SW. NONE may crash boot.
  // (chrome.devtools is intentionally NOT here — Chrome exposes it only to a devtools_page context.)
  function pres(value, cb) { return settle(_Promise.resolve(value), cb); }
  var idleApi = {
    queryState: function (interval, cb) { return pres("active", cb); },
    setDetectionInterval: function () {},
    getAutoLockDelay: function (cb) { return pres(0, cb); },
    onStateChanged: makeEvent([])
  };
  var downloadsApi = {
    download: function (opts, cb) { return pres(0, cb); },
    search: function (q, cb) { return pres([], cb); },
    cancel: function (id, cb) { return pres(undefined, cb); },
    pause: function (id, cb) { return pres(undefined, cb); },
    resume: function (id, cb) { return pres(undefined, cb); },
    erase: function (q, cb) { return pres([], cb); },
    removeFile: function (id, cb) { return pres(undefined, cb); },
    acceptDanger: function (id, cb) { return pres(undefined, cb); },
    getFileIcon: function (id, opts, cb) { return pres("", (typeof opts === "function") ? opts : cb); },
    open: function () {}, show: function () {}, showDefaultFolder: function () {}, setShelfEnabled: function () {},
    onCreated: makeEvent([]), onChanged: makeEvent([]), onErased: makeEvent([]), onDeterminingFilename: makeEvent([])
  };
  var bookmarksApi = {
    get: function (id, cb) { return pres([], cb); },
    getChildren: function (id, cb) { return pres([], cb); },
    getRecent: function (n, cb) { return pres([], cb); },
    getTree: function (cb) { return pres([], cb); },
    getSubTree: function (id, cb) { return pres([], cb); },
    search: function (q, cb) { return pres([], cb); },
    create: function (b, cb) { return pres({ id: "0", title: (b && b.title) || "" }, cb); },
    move: function (id, dest, cb) { return pres({ id: String(id) }, cb); },
    update: function (id, changes, cb) { return pres({ id: String(id) }, cb); },
    remove: function (id, cb) { return pres(undefined, cb); },
    removeTree: function (id, cb) { return pres(undefined, cb); },
    MAX_WRITE_OPERATIONS_PER_HOUR: 1000000, MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000,
    onCreated: makeEvent([]), onRemoved: makeEvent([]), onChanged: makeEvent([]), onMoved: makeEvent([]),
    onChildrenReordered: makeEvent([]), onImportBegan: makeEvent([]), onImportEnded: makeEvent([])
  };
  var historyApi = {
    search: function (q, cb) { return pres([], cb); },
    getVisits: function (d, cb) { return pres([], cb); },
    addUrl: function (d, cb) { return pres(undefined, cb); },
    deleteUrl: function (d, cb) { return pres(undefined, cb); },
    deleteRange: function (r, cb) { return pres(undefined, cb); },
    deleteAll: function (cb) { return pres(undefined, cb); },
    onVisited: makeEvent([]), onVisitRemoved: makeEvent([])
  };
  var sessionsApi = {
    getRecentlyClosed: function (filter, cb) { return pres([], (typeof filter === "function") ? filter : cb); },
    getDevices: function (filter, cb) { return pres([], (typeof filter === "function") ? filter : cb); },
    restore: function (sessionId, cb) { return pres({}, (typeof sessionId === "function") ? sessionId : cb); },
    MAX_SESSION_RESULTS: 25,
    onChanged: makeEvent([])
  };
  var searchApi = { query: function (info, cb) { return pres(undefined, cb); } };
  var pageActionApi = {
    show: function (id, cb) { return pres(undefined, cb); },
    hide: function (id, cb) { return pres(undefined, cb); },
    setTitle: function (d, cb) { return pres(undefined, cb); },
    getTitle: function (d, cb) { return pres("", cb); },
    setIcon: function (d, cb) { return pres(undefined, cb); },
    setPopup: function (d, cb) { return pres(undefined, cb); },
    getPopup: function (d, cb) { return pres("", cb); },
    onClicked: makeEvent([])
  };
  var sidePanelApi = {
    open: function (opts, cb) { return pres(undefined, cb); },
    setOptions: function (opts, cb) { return pres(undefined, cb); },
    getOptions: function (opts, cb) { return pres({}, (typeof opts === "function") ? opts : cb); },
    setPanelBehavior: function (b, cb) { return pres(undefined, cb); },
    getPanelBehavior: function (cb) { return pres({ openPanelOnActionClick: false }, cb); },
    onShown: makeEvent([]), onHidden: makeEvent([])
  };
  var offscreenApi = {
    createDocument: function (opts, cb) { return pres(undefined, cb); },
    closeDocument: function (cb) { return pres(undefined, cb); },
    hasDocument: function (cb) { return pres(false, cb); },
    Reason: { TESTING: "TESTING", AUDIO_PLAYBACK: "AUDIO_PLAYBACK", IFRAME_SCRIPTING: "IFRAME_SCRIPTING", DOM_SCRAPING: "DOM_SCRAPING", BLOBS: "BLOBS", DOM_PARSER: "DOM_PARSER", USER_MEDIA: "USER_MEDIA", DISPLAY_MEDIA: "DISPLAY_MEDIA", WEB_RTC: "WEB_RTC", CLIPBOARD: "CLIPBOARD", LOCAL_STORAGE: "LOCAL_STORAGE", WORKERS: "WORKERS", BATTERY_STATUS: "BATTERY_STATUS" }
  };
  var systemApi = {
    cpu: { getInfo: function (cb) { var n = (W.navigator && W.navigator.hardwareConcurrency) || 4; var info = { numOfProcessors: n, archName: "arm64", modelName: "Apple silicon", features: [], processors: [] }; for (var i = 0; i < n; i++) { info.processors.push({ usage: { user: 0, kernel: 0, idle: 0, total: 0 } }); } return pres(info, cb); } },
    memory: { getInfo: function (cb) { return pres({ capacity: 4 * 1024 * 1024 * 1024, availableCapacity: 2 * 1024 * 1024 * 1024 }, cb); } },
    display: {
      getInfo: function (opts, cb) {
        var w = (W.screen && W.screen.width) || 390, h = (W.screen && W.screen.height) || 844, b = { left: 0, top: 0, width: w, height: h };
        return pres([{ id: "0", name: "BrownBear Display", isPrimary: true, isEnabled: true, isInternal: true, bounds: b, workArea: b, dpiX: 96, dpiY: 96, rotation: 0, overscan: { left: 0, top: 0, right: 0, bottom: 0 } }], (typeof opts === "function") ? opts : cb);
      },
      getDisplayLayout: function (cb) { return pres([], cb); }, onDisplayChanged: makeEvent([])
    },
    storage: { getInfo: function (cb) { return pres([], cb); }, onAttached: makeEvent([]), onDetached: makeEvent([]) }
  };
  var tabCaptureApi = {
    capture: function (opts, cb) { if (typeof cb === "function") { cb(null); } return undefined; },
    getCapturedTabs: function (cb) { return pres([], cb); },
    getMediaStreamId: function (opts, cb) { return settle(_Promise.reject(new Error("Tab capture is not supported on this platform")), (typeof opts === "function") ? opts : cb); },
    onStatusChanged: makeEvent([])
  };
  var desktopCaptureApi = {
    chooseDesktopMedia: function (sources, targetOrCb, cb) { var callback = (typeof targetOrCb === "function") ? targetOrCb : cb; if (typeof callback === "function") { callback("", { canRequestAudioTrack: false }); } return 0; },
    cancelChooseDesktopMedia: function () {}
  };
  var ttsApi = {
    speak: function (utt, opts, cb) {
      if (typeof opts === "function") { cb = opts; opts = null; }
      var onEvent = (opts && typeof opts.onEvent === "function") ? opts.onEvent : null;
      if (onEvent) { try { onEvent({ type: "error", charIndex: 0, errorMessage: "TTS engine unavailable on this platform" }); } catch (e) {} }
      if (typeof cb === "function") { cb(); return undefined; }
      return _Promise.resolve();
    },
    stop: function () {}, pause: function () {}, resume: function () {},
    isSpeaking: function (cb) { return pres(false, cb); },
    getVoices: function (cb) { return pres([], cb); },
    onEvent: makeEvent([])
  };
  var ttsEngineApi = {
    updateVoices: function () {}, sendTtsEvent: function () {}, sendTtsAudio: function () {},
    onSpeak: makeEvent([]), onSpeakWithAudioStream: makeEvent([]), onStop: makeEvent([]), onPause: makeEvent([]), onResume: makeEvent([]),
    onInstallLanguageRequest: makeEvent([]), onUninstallLanguageRequest: makeEvent([]), onLanguageStatusRequest: makeEvent([])
  };
  var domApi = { openOrClosedShadowRoot: function (el) { try { return (el && el.shadowRoot) || null; } catch (e) { return null; } } };

  // chrome.runtime.connect / onConnect long-lived ports (popup/options page = CONNECTOR). Mirrors the
  // content runtime, adapted to the page's 2-arg bridge(api, payload). A synchronous Port buffers
  // postMessage() until the async native id-mint resolves, then flushes; native pushes the worker's
  // replies via W.__brownbearExtPage.onPortMessage/onPortDisconnect.
  var connectListeners = [];
  var ports = Object.create(null);
  function makePort(name, sender) {
    var msgListeners = [], discListeners = [];
    var portId = null, disconnected = false, buffer = [];
    var port = {
      name: name || "", sender: sender || null,
      onMessage: makeEvent(msgListeners),
      onDisconnect: makeEvent(discListeners),
      postMessage: function (msg) {
        if (disconnected) { return; }
        var m = (msg === undefined ? null : msg);
        if (portId) { bridge("port.postMessage", { portId: portId, message: m }); }
        else { buffer.push(m); }
      },
      disconnect: function () {
        if (disconnected) { return; }
        disconnected = true;
        if (portId) { bridge("port.disconnect", { portId: portId }); delete ports[portId]; }
      }
    };
    port._bindId = function (id) {
      portId = id;
      if (!id) { return; }
      ports[id] = port;
      if (disconnected) { bridge("port.disconnect", { portId: id }); delete ports[id]; return; }
      for (var i = 0; i < buffer.length; i++) { bridge("port.postMessage", { portId: id, message: buffer[i] }); }
      buffer = [];
    };
    port._fireMessage = function (m) { for (var i = 0; i < msgListeners.length; i++) { try { msgListeners[i](m, port); } catch (e) {} } };
    port._fireDisconnect = function () { disconnected = true; for (var i = 0; i < discListeners.length; i++) { try { discListeners[i](port); } catch (e) {} } };
    return port;
  }
  function runtimeConnect(connectInfo) {
    var ci = connectInfo || {};
    var port = makePort(ci.name || "", null);
    // Include this page's URL: Chrome's onConnect Port.sender carries the connecting page's url, and
    // uBO's vAPI.messaging onConnect does `sender.url.startsWith(...)` — undefined threw in the
    // worker's onConnect and killed the popup's port before any reply.
    bridge("port.connect", { name: ci.name || "",
                             url: (W.location && W.location.href) || "" }).then(function (res) {
      port._bindId(res && res.portId ? res.portId : null);
    }, function () { port._bindId(null); });
    return port;
  }

  function storageArea(area) {
    function get(keys, callback) {
      if (typeof keys === "function") { callback = keys; keys = null; }
      var keyList = null, defaults = null;
      if (typeof keys === "string") { keyList = [keys]; }
      else if (_Array.isArray(keys)) { keyList = keys; }
      else if (keys && typeof keys === "object") { defaults = keys; keyList = _Object.keys(keys); }
      var promise = bridge("storage.get", { area: area, keys: keyList }).then(function (raw) {
        var out = {};
        // Deep-clone each default so a caller mutating the get() result can't corrupt its own defaults
        // object (Chrome returns independent copies). A stored value overrides the default below.
        if (defaults) {
          _Object.keys(defaults).forEach(function (k) {
            try { out[k] = (typeof structuredClone === "function") ? structuredClone(defaults[k]) : _JSON.parse(_JSON.stringify(defaults[k])); }
            catch (e) { out[k] = defaults[k]; }
          });
        }
        var map = raw || {};
        _Object.keys(map).forEach(function (k) { try { out[k] = _JSON.parse(map[k]); } catch (e) { out[k] = map[k]; } });
        return out;
      });
      return settle(promise, callback);
    }
    function set(items, callback) {
      var enc = {};
      _Object.keys(items || {}).forEach(function (k) { enc[k] = _JSON.stringify(items[k]); });
      return settle(bridge("storage.set", { area: area, items: enc }).then(function () { return undefined; }), callback);
    }
    function remove(keys, callback) {
      var list = typeof keys === "string" ? [keys] : (keys || []);
      return settle(bridge("storage.remove", { area: area, keys: list }).then(function () { return undefined; }), callback);
    }
    function clear(callback) {
      return settle(bridge("storage.clear", { area: area }).then(function () { return undefined; }), callback);
    }
    // chrome.storage.<area>.getBytesInUse — we don't track byte usage; report 0 (Chrome permits an
    // approximate/zero value), mirroring the background worker so the method exists everywhere.
    function getBytesInUse(keys, callback) {
      if (typeof keys === "function") { callback = keys; }
      if (typeof callback === "function") { callback(0); return undefined; }
      return _Promise.resolve(0);
    }
    // chrome.storage.session.setAccessLevel — no-op (BrownBear has no separate untrusted tier); resolves.
    function setAccessLevel(_opts, callback) {
      if (typeof callback === "function") { callback(); return undefined; }
      return _Promise.resolve();
    }
    return { get: get, set: set, remove: remove, clear: clear,
             getBytesInUse: getBytesInUse, setAccessLevel: setAccessLevel,
             // Per-area StorageArea.onChanged (Chrome 73+): listener gets (changes) for THIS area only.
             // uBO Lite's dashboard calls storage.local.onChanged.addListener — its absence threw.
             onChanged: makeEvent(areaStorageListeners[area] || (areaStorageListeners[area] = [])) };
  }

  function getURL(path) {
    var p = String(path || "");
    return data.baseURL + (p.charAt(0) === "/" ? p.slice(1) : p);
  }

  function i18nGetMessage(key, substitutions) {
    var text = messages[key] || "";
    if (substitutions != null) {
      var subs = _Array.isArray(substitutions) ? substitutions : [substitutions];
      text = text.replace(/\$(\d+)\$?/g, function (_, n) { var i = parseInt(n, 10) - 1; return subs[i] != null ? subs[i] : ""; });
    }
    return text;
  }

  function tabsApi() {
    function query(queryInfo, callback) { return settle(bridge("tabs.query", { query: queryInfo || {} }), callback); }
    function get(tabId, callback) { return settle(bridge("tabs.get", { tabId: tabId }), callback); }
    function getCurrent(callback) { return settle(bridge("tabs.getCurrent", {}), callback); }
    function create(props, callback) {
      props = props || {};
      return settle(bridge("tabs.create", { url: props.url, active: props.active !== false }), callback);
    }
    function update(tabId, props, callback) {
      if (tabId !== null && typeof tabId === "object") { callback = props; props = tabId; tabId = undefined; }
      props = props || {};
      return settle(bridge("tabs.update", { tabId: tabId, url: props.url, active: props.active }), callback);
    }
    function remove(tabIds, callback) {
      var ids = _Array.isArray(tabIds) ? tabIds : [tabIds];
      return settle(bridge("tabs.remove", { tabIds: ids }).then(function () { return undefined; }), callback);
    }
    function reload(tabId, props, callback) {
      if (typeof tabId === "function") { callback = tabId; tabId = undefined; props = {}; }
      else if (tabId !== null && typeof tabId === "object") { callback = props; props = tabId; tabId = undefined; }
      props = props || {};
      return settle(bridge("tabs.reload", { tabId: tabId, bypassCache: !!props.bypassCache }).then(function () { return undefined; }), callback);
    }
    function executeScript(tabId, details, callback) {
      if (tabId !== null && typeof tabId === "object") { callback = details; details = tabId; tabId = undefined; }
      details = details || {};
      return settle(bridge("tabs.executeScript", { tabId: tabId, code: details.code, file: details.file, world: details.world }), callback);
    }
    function insertCSS(tabId, details, callback) {
      if (tabId !== null && typeof tabId === "object") { callback = details; details = tabId; tabId = undefined; }
      details = details || {};
      return settle(bridge("tabs.insertCSS", { tabId: tabId, code: details.code, file: details.file }).then(function () { return undefined; }), callback);
    }
    function sendMessage() {
      // chrome.tabs.sendMessage(tabId, message, options?, callback?) — a popup messaging a tab's
      // content scripts. Native delivers to that tab and resolves with the content listener's response.
      var args = _Array.prototype.slice.call(arguments);
      var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
      var tabId = args[0];
      var message = args[1];
      return settle(bridge("tabs.sendMessage", { tabId: tabId, message: (message === undefined ? null : message) }), cb);
    }
    function captureVisibleTab() {
      // (windowId?, options?, callback?) — windowId ignored (single window). Returns a data URL of the
      // active tab. Chrome exposes this in the popup too (a screenshot extension's GoFullPage captures
      // from its popup); without it here the call is undefined and the popup blanks with a TypeError.
      var args = _Array.prototype.slice.call(arguments);
      var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
      var options = null;
      for (var i = 0; i < args.length; i++) { if (args[i] && typeof args[i] === "object") { options = args[i]; } }
      options = options || {};
      return settle(bridge("tabs.captureVisibleTab", {
        format: options.format || "png",
        quality: typeof options.quality === "number" ? options.quality : 92
      }), cb);
    }
    function move(tabIds, moveProps, cb) {
      if (typeof moveProps === "function") { cb = moveProps; moveProps = {}; }
      moveProps = moveProps || {};
      var single = !_Array.isArray(tabIds);
      var ids = single ? [tabIds] : tabIds;
      return settle(bridge("tabs.move", { tabIds: ids, index: typeof moveProps.index === "number" ? moveProps.index : -1 })
        .then(function (moved) { return (single && _Array.isArray(moved)) ? moved[0] : moved; }), cb);
    }
    function duplicate(tabId, cb) { return settle(bridge("tabs.duplicate", { tabId: tabId }), cb); }
    function getZoom(a, b) {
      var tabId = (typeof a === "number") ? a : null;
      var cb = (typeof a === "function") ? a : (typeof b === "function" ? b : null);
      return settle(bridge("tabs.getZoom", { tabId: tabId }), cb);
    }
    function setZoom(a, b, c) {
      var tabId = null, zoomFactor, cb = null;
      if (typeof b === "number") { tabId = a; zoomFactor = b; cb = (typeof c === "function") ? c : null; }
      else { zoomFactor = a; cb = (typeof b === "function") ? b : null; }
      return settle(bridge("tabs.setZoom", { tabId: typeof tabId === "number" ? tabId : null, zoomFactor: zoomFactor })
        .then(function () { return undefined; }), cb);
    }
    return {
      query: query, get: get, getCurrent: getCurrent, create: create, update: update, remove: remove, reload: reload,
      executeScript: executeScript, insertCSS: insertCSS, sendMessage: sendMessage,
      captureVisibleTab: captureVisibleTab, move: move, duplicate: duplicate, getZoom: getZoom, setZoom: setZoom,
      // iOS has no tab groups — non-throwing no-ops so unguarded callers don't crash (see background).
      group: function (options, cb) { return settle(Promise.resolve(-1), cb); },
      ungroup: function (tabIds, cb) { return settle(Promise.resolve(undefined), cb); },
      onCreated: makeEvent(tabEventLists["tabs.onCreated"]),
      onUpdated: makeEvent(tabEventLists["tabs.onUpdated"]),
      onActivated: makeEvent(tabEventLists["tabs.onActivated"]),
      onRemoved: makeEvent(tabEventLists["tabs.onRemoved"]),
      onReplaced: makeEvent([]),
      // Multi-select highlighting + zoom have no iOS analog (single-tab model); inert but present so a
      // page that registers these unguarded doesn't throw. onHighlightChanged is the deprecated alias.
      onHighlighted: makeEvent([]),
      onHighlightChanged: makeEvent([]),
      onZoomChange: makeEvent([])
    };
  }

  function scriptingApi() {
    function serialize(injection) {
      var payload = { target: injection.target || {}, world: injection.world || "ISOLATED" };
      if (injection.files) { payload.files = injection.files; }
      else if (typeof injection.func === "function") {
        payload.code = "(" + injection.func.toString() + ").apply(null, " + _JSON.stringify(injection.args || []) + ")";
      } else if (typeof injection.code === "string") { payload.code = injection.code; }
      return payload;
    }
    function cssPayload(injection) {
      var payload = { target: injection.target || {} };
      if (injection.files) { payload.files = injection.files; } else { payload.css = injection.css || ""; }
      return payload;
    }
    return {
      executeScript: function (injection, callback) { return settle(bridge("scripting.executeScript", serialize(injection)), callback); },
      insertCSS: function (injection, callback) { return settle(bridge("scripting.insertCSS", cssPayload(injection)).then(function () { return undefined; }), callback); },
      removeCSS: function (injection, callback) { return settle(bridge("scripting.removeCSS", cssPayload(injection)).then(function () { return undefined; }), callback); }
    };
  }

  var storageListeners = [];
  // Per-area StorageArea.onChanged listeners (local/sync/session/managed), fanned from the same native
  // push as the global storage.onChanged — Chrome's per-area listener receives (changes) only.
  var areaStorageListeners = {};
  var messageListeners = [];
  // Browser-pushed chrome.tabs.* / chrome.webNavigation.* event lists, driven by native via
  // window.__brownbearExtPage.dispatchExtEvent (extension pages DO receive these events).
  var tabEventLists = {
    "tabs.onCreated": [], "tabs.onUpdated": [], "tabs.onActivated": [], "tabs.onRemoved": []
  };
  var webNavLists = {
    "webNavigation.onBeforeNavigate": [], "webNavigation.onCommitted": [],
    "webNavigation.onDOMContentLoaded": [], "webNavigation.onCompleted": [],
    "webNavigation.onHistoryStateUpdated": [], "webNavigation.onErrorOccurred": []
  };
  // chrome.permissions.onAdded/onRemoved — Chrome fires these in extension PAGES too (not just the
  // worker) when a runtime permission grant/revoke happens; native dispatchExtEvent routes them here.
  var permissionsEventLists = { "permissions.onAdded": [], "permissions.onRemoved": [] };

  // --- chrome.cookies (live onChanged via the native push surface below) -----------------------
  var cookieChangedListeners = [];
  function cookiesApi() {
    function get(details, callback) { return settle(bridge("cookies.get", { details: details || {} }), callback); }
    function getAll(details, callback) {
      if (typeof details === "function") { callback = details; details = {}; }
      return settle(bridge("cookies.getAll", { details: details || {} }), callback);
    }
    function set(details, callback) { return settle(bridge("cookies.set", { details: details || {} }), callback); }
    function remove(details, callback) { return settle(bridge("cookies.remove", { details: details || {} }), callback); }
    function getAllCookieStores(callback) { return settle(bridge("cookies.getAllCookieStores", {}), callback); }
    return {
      get: get, getAll: getAll, set: set, remove: remove,
      getAllCookieStores: getAllCookieStores, onChanged: makeEvent(cookieChangedListeners)
    };
  }

  // --- chrome.notifications (live on* events via the native push surface below) ----------------
  var notificationClickedListeners = [];
  var notificationClosedListeners = [];
  var notificationButtonListeners = [];
  function notificationsApi() {
    function create(notificationId, options, callback) {
      if (notificationId !== null && typeof notificationId === "object") { callback = options; options = notificationId; notificationId = undefined; }
      if (typeof options === "function") { callback = options; options = {}; }
      options = options || {};
      return settle(bridge("notifications.create", { notificationId: notificationId || null, options: options }), callback);
    }
    function update(notificationId, options, callback) {
      if (typeof options === "function") { callback = options; options = {}; }
      options = options || {};
      return settle(bridge("notifications.update", { notificationId: notificationId, options: options }), callback);
    }
    function clear(notificationId, callback) {
      return settle(bridge("notifications.clear", { notificationId: notificationId }), callback);
    }
    function getAll(callback) { return settle(bridge("notifications.getAll", {}), callback); }
    function getPermissionLevel(callback) {
      var level = "granted";
      if (typeof callback === "function") { callback(level); return undefined; }
      return _Promise.resolve(level);
    }
    return {
      create: create, update: update, clear: clear, getAll: getAll, getPermissionLevel: getPermissionLevel,
      onClicked: makeEvent(notificationClickedListeners),
      onClosed: makeEvent(notificationClosedListeners),
      onButtonClicked: makeEvent(notificationButtonListeners),
      onShowSettings: makeEvent([]), onPermissionLevelChanged: makeEvent([])
    };
  }

  // --- chrome.action / chrome.browserAction (extension page) ----------------------------------
  var actionClickedListeners = [];
  function actionApi() {
    function setter(api) {
      return function (details, callback) {
        details = details || {};
        var payload = {};
        for (var k in details) { if (_Object.prototype.hasOwnProperty.call(details, k)) { payload[k] = details[k]; } }
        return settle(bridge(api, payload).then(function () { return undefined; }), callback);
      };
    }
    function getter(api) {
      return function (details, callback) {
        if (typeof details === "function") { callback = details; details = {}; }
        return settle(bridge(api, details || {}), callback);
      };
    }
    function toggle(api) {
      return function (tabId, callback) {
        if (typeof tabId === "function") { callback = tabId; tabId = undefined; }
        return settle(bridge(api, { tabId: tabId }).then(function () { return undefined; }), callback);
      };
    }
    function setIcon(details, callback) {
      details = details || {};
      var payload = { tabId: details.tabId };
      if (typeof details.path === "string") { payload.path = details.path; }
      else if (details.path && typeof details.path === "object") {
        var map = {}; for (var k in details.path) { if (typeof details.path[k] === "string") { map[k] = details.path[k]; } }
        payload.path = map;
      }
      return settle(bridge("action.setIcon", payload).then(function () { return undefined; }), callback);
    }
    return {
      setBadgeText: setter("action.setBadgeText"),
      setBadgeBackgroundColor: setter("action.setBadgeBackgroundColor"),
      setBadgeTextColor: setter("action.setBadgeTextColor"),
      setTitle: setter("action.setTitle"),
      setPopup: setter("action.setPopup"),
      setIcon: setIcon,
      enable: toggle("action.enable"),
      disable: toggle("action.disable"),
      getBadgeText: getter("action.getBadgeText"),
      getTitle: getter("action.getTitle"),
      getBadgeBackgroundColor: getter("action.getBadgeBackgroundColor"),
      getBadgeTextColor: getter("action.getBadgeTextColor"),
      onClicked: makeEvent(actionClickedListeners)
    };
  }

  // --- chrome.windows / management / permissions (extension page) -----------------------------
  var noopEvent = { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } };
  function windowsApi() {
    function normalize(getInfo, cb) {
      if (typeof getInfo === "function") { cb = getInfo; getInfo = null; }
      return { populate: !!(getInfo && getInfo.populate), cb: cb };
    }
    function get(windowId, getInfo, cb) {
      if (typeof windowId === "object" && windowId !== null) { cb = getInfo; getInfo = windowId; }
      else if (typeof windowId === "function") { cb = windowId; getInfo = null; }
      var n = normalize(getInfo, cb);
      return settle(bridge("windows.get", { populate: n.populate }), n.cb);
    }
    function getCurrent(getInfo, cb) { var n = normalize(getInfo, cb); return settle(bridge("windows.getCurrent", { populate: n.populate }), n.cb); }
    function getLastFocused(getInfo, cb) { var n = normalize(getInfo, cb); return settle(bridge("windows.getLastFocused", { populate: n.populate }), n.cb); }
    function getAll(getInfo, cb) { var n = normalize(getInfo, cb); return settle(bridge("windows.getAll", { populate: n.populate }), n.cb); }
    function create(createData, cb) {
      createData = createData || {};
      var url = createData.url;
      if (_Array.isArray(url)) { url = url[0]; }
      return settle(bridge("windows.create", { url: url, focused: createData.focused !== false, populate: false }), cb);
    }
    function update(windowId, updateInfo, cb) { return settle(bridge("windows.update", { populate: false }), cb); }
    function remove(windowId, cb) { return settle(bridge("windows.remove", {}).then(function () { return undefined; }), cb); }
    return {
      WINDOW_ID_NONE: -1, WINDOW_ID_CURRENT: -2,
      get: get, getCurrent: getCurrent, getLastFocused: getLastFocused, getAll: getAll,
      create: create, update: update, remove: remove,
      onCreated: noopEvent, onRemoved: noopEvent, onFocusChanged: noopEvent, onBoundsChanged: noopEvent
    };
  }
  function managementApi() {
    return {
      getSelf: function (cb) { return settle(bridge("management.getSelf", {}), cb); },
      get: function (id, cb) { return settle(bridge("management.get", { id: id }), cb); },
      getAll: function (cb) { return settle(bridge("management.getAll", {}), cb); },
      onInstalled: noopEvent, onUninstalled: noopEvent, onEnabled: noopEvent, onDisabled: noopEvent
    };
  }
  function permissionsApi() {
    function perms(p) { p = p || {}; return { permissions: p.permissions || [], origins: p.origins || [] }; }
    return {
      getAll: function (cb) { return settle(bridge("permissions.getAll", {}), cb); },
      contains: function (p, cb) { return settle(bridge("permissions.contains", perms(p)), cb); },
      request: function (p, cb) { return settle(bridge("permissions.request", perms(p)), cb); },
      remove: function (p, cb) { return settle(bridge("permissions.remove", perms(p)), cb); },
      onAdded: makeEvent(permissionsEventLists["permissions.onAdded"]),
      onRemoved: makeEvent(permissionsEventLists["permissions.onRemoved"])
    };
  }

  // --- chrome.declarativeNetRequest + chrome.userScripts (page/popup) -------------------------
  function unwrap(result) {
    if (result && typeof result === "object" && typeof result.error === "string") {
      return _Promise.reject(new Error(result.error));
    }
    return result;
  }
  var declarativeNetRequest = {
    // Chrome exposes these enums + limits as constants; extensions read them directly (e.g.
    // ResourceType.MAIN_FRAME). Their absence throws "undefined is not an object".
    ResourceType: { MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other' },
    RuleActionType: { BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests' },
    HeaderOperation: { APPEND: 'append', SET: 'set', REMOVE: 'remove' },
    DomainType: { FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty' },
    UnsupportedRegexReason: { SYNTAX_ERROR: 'syntaxError', MEMORY_LIMIT_EXCEEDED: 'memoryLimitExceeded' },
    DYNAMIC_RULESET_ID: '_dynamic', SESSION_RULESET_ID: '_session',
    MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000,
    MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
    GETMATCHEDRULES_QUOTA_INTERVAL: 600, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20,
    updateDynamicRules: function (options, callback) {
      return settle(bridge("dnr.updateDynamicRules", options || {}).then(unwrap).then(function () { return undefined; }), callback);
    },
    getDynamicRules: function (filter, callback) {
      if (typeof filter === "function") { callback = filter; filter = null; }
      return settle(bridge("dnr.getDynamicRules", { ruleIds: (filter && filter.ruleIds) || null }).then(unwrap), callback);
    },
    updateSessionRules: function (options, callback) {
      return settle(bridge("dnr.updateSessionRules", options || {}).then(unwrap).then(function () { return undefined; }), callback);
    },
    getSessionRules: function (filter, callback) {
      if (typeof filter === "function") { callback = filter; filter = null; }
      return settle(bridge("dnr.getSessionRules", { ruleIds: (filter && filter.ruleIds) || null }).then(unwrap), callback);
    },
    updateEnabledRulesets: function (options, callback) {
      return settle(bridge("dnr.updateEnabledRulesets", options || {}).then(unwrap).then(function () { return undefined; }), callback);
    },
    getEnabledRulesets: function (callback) {
      return settle(bridge("dnr.getEnabledRulesets", {}).then(unwrap), callback);
    },
    getMatchedRules: function (filter, callback) {
      if (typeof filter === "function") { callback = filter; filter = null; }
      return settle(_Promise.resolve({ rulesMatchedInfo: [] }), callback);
    },
    setExtensionActionOptions: function (options, callback) { return settle(_Promise.resolve(undefined), callback); },
    isRegexSupported: function (regexOptions, callback) { return settle(_Promise.resolve({ isSupported: true }), callback); },
    onRuleMatchedDebug: { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } },
    MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000,
    MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
    DYNAMIC_RULESET_ID: "_dynamic",
    SESSION_RULESET_ID: "_session"
  };
  var userScripts = {
    register: function (scripts, callback) {
      return settle(bridge("userScripts.register", { scripts: scripts || [] }).then(unwrap).then(function () { return undefined; }), callback);
    },
    update: function (scripts, callback) {
      return settle(bridge("userScripts.update", { scripts: scripts || [] }).then(unwrap).then(function () { return undefined; }), callback);
    },
    unregister: function (filter, callback) {
      if (typeof filter === "function") { callback = filter; filter = null; }
      return settle(bridge("userScripts.unregister", { filter: filter || null }).then(unwrap).then(function () { return undefined; }), callback);
    },
    getScripts: function (filter, callback) {
      if (typeof filter === "function") { callback = filter; filter = null; }
      return settle(bridge("userScripts.getScripts", { filter: filter || null }).then(unwrap), callback);
    },
    configureWorld: function (properties, callback) {
      return settle(bridge("userScripts.configureWorld", { properties: properties || {} }).then(unwrap).then(function () { return undefined; }), callback);
    }
  };

  // --- chrome.contextMenus (page/popup: create/update/remove over the bridge; onClicked is
  //     background-only in Chrome, so the event here is inert) -----------------------------------
  function contextMenusApi() {
    function unwrapMenu(result) {
      if (result && typeof result === "object" && typeof result.error === "string") {
        return _Promise.reject(new Error(result.error));
      }
      return result;
    }
    return {
      create: function (createProperties, callback) {
        createProperties = createProperties || {};
        bridge("contextMenus.create", { properties: createProperties }).then(unwrapMenu).then(function () {
          if (typeof callback === "function") { callback(); }
        }, function () { if (typeof callback === "function") { callback(); } });
        return (createProperties.id !== undefined && createProperties.id !== null) ? createProperties.id : undefined;
      },
      update: function (id, updateProperties, callback) {
        return settle(bridge("contextMenus.update", { id: id, properties: updateProperties || {} }).then(unwrapMenu).then(function () { return undefined; }), callback);
      },
      remove: function (menuItemId, callback) {
        return settle(bridge("contextMenus.remove", { id: menuItemId }).then(unwrapMenu).then(function () { return undefined; }), callback);
      },
      removeAll: function (callback) {
        return settle(bridge("contextMenus.removeAll", {}).then(unwrapMenu).then(function () { return undefined; }), callback);
      },
      onClicked: { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } },
      ACTION_MENU_TOP_LEVEL_LIMIT: 6
    };
  }

  var chrome = {
    storage: {
      local: storageArea("local"),
      sync: storageArea("sync"),
      session: storageArea("session"),
      managed: storageArea("managed"),   // read-only policy store; resolves {} with no MDM policy
      onChanged: makeEvent(storageListeners)
    },
    // chrome.identity — getRedirectURL is the real Chrome value an extension registers as its OAuth
    // redirect URI; launchWebAuthFlow's interactive UI lands in a follow-up (rejects clearly until then).
    identity: {
      getRedirectURL: function (path) {
        var p = (path == null) ? "" : String(path);
        if (p.charAt(0) === "/") { p = p.slice(1); }
        return "https://" + data.extensionId + ".chromiumapp.org/" + p;
      },
      launchWebAuthFlow: function (details, cb) {
        return settle(_Promise.reject(new Error("identity.launchWebAuthFlow is not yet available")), cb);
      },
      getAuthToken: function (details, cb) {
        if (typeof details === "function") { cb = details; }
        return settle(_Promise.reject(new Error("identity.getAuthToken is not supported; use launchWebAuthFlow")), cb);
      },
      removeCachedAuthToken: function (details, cb) { return settle(_Promise.resolve(), cb); },
      clearAllCachedAuthTokens: function (cb) { return settle(_Promise.resolve(), cb); },
      getProfileUserInfo: function (details, cb) {
        if (typeof details === "function") { cb = details; }
        return settle(_Promise.resolve({ email: "", id: "" }), cb);
      },
      getAccounts: function (cb) { return settle(_Promise.resolve([]), cb); },
      // chrome.identity.AccountStatus enum (Google Keep reads AccountStatus.ANY at boot).
      AccountStatus: { SYNC: "SYNC", ANY: "ANY" },
      onSignInChanged: makeEvent([])
    },
    // chrome.omnibox — address-bar keyword API; inert on a page (keyword input isn't routed to
    // extensions yet) but must exist so a popup/options script registering it doesn't throw.
    omnibox: {
      setDefaultSuggestion: function () {},
      onInputStarted: makeEvent([]), onInputChanged: makeEvent([]), onInputEntered: makeEvent([]),
      onInputCancelled: makeEvent([]), onDeleteSuggestion: makeEvent([])
    },
    cookies: cookiesApi(),
    notifications: notificationsApi(),
    contextMenus: contextMenusApi(),
    menus: contextMenusApi(),
    action: actionApi(),
    browserAction: actionApi(),
    windows: windowsApi(),
    management: managementApi(),
    permissions: permissionsApi(),
    declarativeNetRequest: declarativeNetRequest,
    userScripts: userScripts,
    privacy: privacyApi,
    proxy: proxyApi,
    idle: idleApi,
    downloads: downloadsApi,
    bookmarks: bookmarksApi,
    history: historyApi,
    sessions: sessionsApi,
    search: searchApi,
    pageAction: pageActionApi,
    sidePanel: sidePanelApi,
    offscreen: offscreenApi,
    system: systemApi,
    tabCapture: tabCaptureApi,
    desktopCapture: desktopCaptureApi,
    tts: ttsApi,
    ttsEngine: ttsEngineApi,
    dom: domApi,
    // chrome.webRequest — exists on every Chrome extension page even though WKWebView can't intercept
    // requests (so the events are inert here, as in the background). The namespace + enums MUST exist:
    // Tampermonkey's popup reads chrome.webRequest.<...> UNGUARDED at boot (incl. a Firefox feature-detect
    // on filterResponseData), and an undefined namespace threw "undefined is not an object" → blank popup.
    // We deliberately OMIT filterResponseData (it is Firefox-only; its absence is the correct "not Firefox"
    // signal in Chrome) — providing it would make managers take the Firefox code path.
    webRequest: {
      ResourceType: { MAIN_FRAME: "main_frame", SUB_FRAME: "sub_frame", STYLESHEET: "stylesheet", SCRIPT: "script", IMAGE: "image", FONT: "font", OBJECT: "object", XMLHTTPREQUEST: "xmlhttprequest", PING: "ping", CSP_REPORT: "csp_report", MEDIA: "media", WEBSOCKET: "websocket", WEBTRANSPORT: "webtransport", WEBBUNDLE: "webbundle", OTHER: "other" },
      OnBeforeSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", BLOCKING: "blocking", EXTRA_HEADERS: "extraHeaders" },
      OnSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", EXTRA_HEADERS: "extraHeaders" },
      OnHeadersReceivedOptions: { RESPONSE_HEADERS: "responseHeaders", BLOCKING: "blocking", EXTRA_HEADERS: "extraHeaders" },
      OnAuthRequiredOptions: { RESPONSE_HEADERS: "responseHeaders", BLOCKING: "blocking", ASYNC_BLOCKING: "asyncBlocking", EXTRA_HEADERS: "extraHeaders" },
      OnResponseStartedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
      OnBeforeRedirectOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
      OnCompletedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
      MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
      onBeforeRequest: makeEvent([]), onBeforeSendHeaders: makeEvent([]), onSendHeaders: makeEvent([]),
      onHeadersReceived: makeEvent([]), onAuthRequired: makeEvent([]), onResponseStarted: makeEvent([]),
      onBeforeRedirect: makeEvent([]), onCompleted: makeEvent([]), onErrorOccurred: makeEvent([]),
      onActionIgnored: makeEvent([]),
      handlerBehaviorChanged: function (cb) { if (typeof cb === "function") { cb(); return undefined; } return _Promise.resolve(); }
    },
    // chrome.alarms on a page — page-created alarms aren't scheduled in the popup's short-lived context,
    // so create/clear resolve and reads report none; onAlarm exists (inert). Must be present: Tampermonkey
    // and others read chrome.alarms at boot.
    alarms: {
      create: function () {},
      get: function (name, cb) { if (typeof name === "function") { cb = name; } if (typeof cb === "function") { cb(null); return undefined; } return _Promise.resolve(null); },
      getAll: function (cb) { if (typeof cb === "function") { cb([]); return undefined; } return _Promise.resolve([]); },
      clear: function (name, cb) { if (typeof name === "function") { cb = name; } if (typeof cb === "function") { cb(true); return undefined; } return _Promise.resolve(true); },
      clearAll: function (cb) { if (typeof cb === "function") { cb(true); return undefined; } return _Promise.resolve(true); },
      onAlarm: makeEvent([])
    },
    // chrome.commands — keyboard-shortcut registry; a page reads getAll to show shortcuts. No bound
    // commands surface on iOS yet, so getAll reports none; the events exist (inert).
    commands: {
      getAll: function (cb) { if (typeof cb === "function") { cb([]); return undefined; } return _Promise.resolve([]); },
      onCommand: makeEvent([]), onChanged: makeEvent([])
    },
    // chrome.declarativeContent — page-state action rules. iOS has no action-rule engine, so the rules are
    // inert (addRules resolves, getRules reports none); the constructors are no-op stubs. Must exist:
    // Tampermonkey's popup references chrome.declarativeContent.{onPageChanged,PageStateMatcher,...}.
    declarativeContent: {
      onPageChanged: {
        addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; },
        addRules: function (rules, cb) { if (typeof cb === "function") { cb(rules || []); } },
        removeRules: function (ids, cb) { var c = (typeof ids === "function") ? ids : cb; if (typeof c === "function") { c(); } },
        getRules: function (ids, cb) { var c = (typeof ids === "function") ? ids : cb; if (typeof c === "function") { c([]); } }
      },
      PageStateMatcher: function () {}, RequestContentScript: function () {}, ShowAction: function () {},
      ShowPageAction: function () {}, SetIcon: function () {}
    },
    webNavigation: {
      onBeforeNavigate: makeEvent(webNavLists["webNavigation.onBeforeNavigate"]),
      onCommitted: makeEvent(webNavLists["webNavigation.onCommitted"]),
      onDOMContentLoaded: makeEvent(webNavLists["webNavigation.onDOMContentLoaded"]),
      onCompleted: makeEvent(webNavLists["webNavigation.onCompleted"]),
      onHistoryStateUpdated: makeEvent(webNavLists["webNavigation.onHistoryStateUpdated"]),
      onReferenceFragmentUpdated: makeEvent(webNavLists["webNavigation.onReferenceFragmentUpdated"] || []),
      onErrorOccurred: makeEvent(webNavLists["webNavigation.onErrorOccurred"]),
      onTabReplaced: makeEvent([]),
      getFrame: function (details, cb) { if (typeof cb === "function") { cb(null); return undefined; } return _Promise.resolve(null); },
      getAllFrames: function (details, cb) { if (typeof cb === "function") { cb([]); return undefined; } return _Promise.resolve([]); }
    },
    runtime: {
      id: data.extensionId,
      getManifest: function () { return manifest; },
      getURL: getURL,
      onMessage: makeEvent(messageListeners),
      onConnect: makeEvent(connectListeners),
      onInstalled: { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } },
      // Chrome exposes the full runtime-event surface on EVERY extension page, even a popup that never
      // receives these. Tampermonkey's popup (extension.js) builds its messaging wrapper at boot with an
      // UNGUARDED `chrome.runtime.onMessageExternal.addListener(...)` / `onConnectExternal.addListener(...)`,
      // so a missing property threw "Cannot read properties of undefined (reading 'addListener')" and the
      // whole popup rendered blank. These events legitimately never fire on a page in our model (external
      // messaging and userScript ports are routed at the worker), so expose them as inert, spec-shaped
      // events: listeners register without error and simply never get called.
      onConnectExternal: makeEvent([]),
      onMessageExternal: makeEvent([]),
      onUserScriptConnect: makeEvent([]),
      onUserScriptMessage: makeEvent([]),
      onStartup: makeEvent([]),
      onSuspend: makeEvent([]),
      onSuspendCanceled: makeEvent([]),
      onUpdateAvailable: makeEvent([]),
      onRestartRequired: makeEvent([]),
      sendMessage: function () {
        var args = _Array.prototype.slice.call(arguments);
        var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
        var message = (typeof args[0] === "string" && args.length > 1) ? args[1] : args[0];
        var promise = bridge("runtime.sendMessage", { message: (message === undefined ? null : message), url: location.href })
          .then(function (resp) {
            if (resp && resp.__bbNoReceiver) {
              var e = new Error("Could not establish connection. Receiving end does not exist.");
              e.__bbLastError = true; throw e;
            }
            return resp ? resp.value : undefined;
          });
        return settle(promise, cb);
      },
      connect: runtimeConnect,
      openOptionsPage: function (cb) {
        return settle(bridge("runtime.openOptionsPage", {}).then(function () { return undefined; }), cb);
      },
      setUninstallURL: function (url, cb) {
        return settle(bridge("runtime.setUninstallURL", { url: url || "" }).then(function () { return undefined; }), cb);
      },
      get lastError() { return _bbLastError; },
      getPlatformInfo: function (cb) { var info = { os: "ios", arch: "arm64", nacl_arch: "arm64" }; if (typeof cb === "function") { cb(info); return undefined; } return _Promise.resolve(info); }
    },
    tabs: tabsApi(),
    tabGroups: {
      TAB_GROUP_ID_NONE: -1,
      query: function (q, cb) { return settle(Promise.resolve([]), cb); },
      get: function (id, cb) { return settle(Promise.resolve(null), cb); },
      update: function (id, props, cb) { return settle(Promise.resolve(null), cb); },
      move: function (id, props, cb) { return settle(Promise.resolve(null), cb); },
      onCreated: makeEvent([]), onUpdated: makeEvent([]), onMoved: makeEvent([]), onRemoved: makeEvent([])
    },
    scripting: scriptingApi(),
    i18n: {
      getMessage: i18nGetMessage,
      getUILanguage: function () { return (W.navigator && W.navigator.language) || "en"; },
      getAcceptLanguages: function (cb) { var langs = [(W.navigator && W.navigator.language) || "en"]; if (typeof cb === "function") { cb(langs); return undefined; } return _Promise.resolve(langs); }
    },
    extension: { getURL: getURL, inIncognitoContext: false }
  };

  W.chrome = chrome;
  W.browser = chrome;

  // Native push surface: storage.onChanged is delivered by the host evaluating into this page.
  W.__brownbearExtPage = {
    dispatchStorageChanged: function (areaName, changesJSON) {
      var raw;
      try { raw = _JSON.parse(changesJSON); } catch (e) { raw = {}; }
      var changes = {};
      _Object.keys(raw || {}).forEach(function (k) {
        var c = {};
        if (raw[k].oldValue != null) { try { c.oldValue = _JSON.parse(raw[k].oldValue); } catch (e) {} }
        if (raw[k].newValue != null) { try { c.newValue = _JSON.parse(raw[k].newValue); } catch (e) {} }
        changes[k] = c;
      });
      for (var i = 0; i < storageListeners.length; i++) {
        try { storageListeners[i](changes, areaName); } catch (e) {}
      }
      // Fan to the matching per-area StorageArea.onChanged listeners (signature: (changes) only).
      var areaLs = areaStorageListeners[areaName] || [];
      for (var j = 0; j < areaLs.length; j++) {
        try { areaLs[j](changes); } catch (e) {}
      }
    },
    dispatchCookieChanged: function (changeJSON) {
      var change;
      try { change = _JSON.parse(changeJSON); } catch (e) { return; }
      for (var i = 0; i < cookieChangedListeners.length; i++) {
        try { cookieChangedListeners[i](change); } catch (e) {}
      }
    },
    dispatchNotificationClicked: function (notificationId) {
      for (var i = 0; i < notificationClickedListeners.length; i++) {
        try { notificationClickedListeners[i](notificationId); } catch (e) {}
      }
    },
    dispatchNotificationClosed: function (notificationId, byUser) {
      for (var i = 0; i < notificationClosedListeners.length; i++) {
        try { notificationClosedListeners[i](notificationId, !!byUser); } catch (e) {}
      }
    },
    dispatchNotificationButtonClicked: function (notificationId, buttonIndex) {
      for (var i = 0; i < notificationButtonListeners.length; i++) {
        try { notificationButtonListeners[i](notificationId, buttonIndex | 0); } catch (e) {}
      }
    },
    dispatchExtEvent: function (name, argsJSON) {
      var args;
      try { args = _JSON.parse(argsJSON); } catch (e) { args = []; }
      if (!_Array.isArray(args)) { args = []; }
      var list = tabEventLists[name] || webNavLists[name] || permissionsEventLists[name];
      if (!list) { return; }
      for (var i = 0; i < list.length; i++) {
        try { list[i].apply(null, args); } catch (e) {}
      }
    },
    // A runtime.sendMessage delivered INTO this page (from a content script, the background worker,
    // or another extension page). Mirrors the content runtime's onMessage: run chrome.runtime
    // .onMessage listeners and post the first sendResponse back over the bridge, correlated by
    // responseId. message/sender arrive already parsed as JS literals (native embeds them).
    dispatchMessage: function (message, sender, responseId) {
      var responded = false;
      var willRespondAsync = false;
      function sendResponse(value) {
        if (responded) { return; }
        responded = true;
        bridge("runtime.messageResponse",
          { responseId: responseId, value: (value === undefined ? null : value) }).catch(function () {});
      }
      for (var i = 0; i < messageListeners.length; i++) {
        var returned;
        try { returned = messageListeners[i](message, sender || {}, sendResponse); }
        catch (e) { continue; }
        if (returned === true) {
          willRespondAsync = true;
        } else if (returned && typeof returned.then === "function") {
          willRespondAsync = true;
          (function (p) { p.then(function (v) { sendResponse(v); }, function () { sendResponse(undefined); }); })(returned);
        }
        if (responded) { break; }
      }
      if (!responded && !willRespondAsync) { sendResponse(undefined); }
    },
    // Port pushes from native (the worker's replies on a port this page opened). name/sender for
    // onPortConnect (responder path, present for symmetry) arrive already parsed as JS literals.
    onPortConnect: function (portId, name, sender) {
      var port = makePort(typeof name === "string" ? name : "", sender || null);
      port._bindId(portId);
      for (var i = 0; i < connectListeners.length; i++) { try { connectListeners[i](port); } catch (e) {} }
    },
    onPortMessage: function (portId, message) {
      var p = ports[portId];
      if (p) { p._fireMessage(message); }
    },
    onPortDisconnect: function (portId) {
      var p = ports[portId];
      if (p) { delete ports[portId]; p._fireDisconnect(); }
    }
  };
  W.__brownbearExtPageReady = true;
})();
