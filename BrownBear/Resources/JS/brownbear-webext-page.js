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

  // --- window.localStorage / sessionStorage polyfill ------------------------------------------------
  // WKWebView gives the chrome-extension:// custom-scheme PAGE origin NO DOM storage, so window.localStorage
  // is undefined. A page that touches it then throws "null is not an object" at init and never renders —
  // ScriptCat's editor does `localStorage.getItem(...)` / `localStorage.lightMode = …`, Momentum reads
  // `localStorage.firstSynchronized`, etc. Install a SYNCHRONOUS Storage polyfill (the only shape that
  // works — localStorage is sync) so those pages run. A Proxy backs BOTH the method API (getItem/setItem/
  // removeItem/clear/key/length) AND direct property access (`localStorage.foo = "x"`), exactly like a real
  // Storage object; values are coerced to strings per spec.
  //
  // PERSISTENCE: localStorage is native-backed across reloads/relaunches — native seeds the page's last
  // snapshot at document-start as `window.__bb_ls_seed` (a flat string→string map), and the polyfill hands
  // a debounced snapshot back via `window.__bb_ls_save` (a WKScriptMessageHandler → BrownBearPageLocalStorage
  // Store, keyed per extension). So a popup/options page that stores its settings in localStorage reads its
  // own writes back across reopen, exactly like a real browser — without this, every such page lost its
  // state the moment it closed ("localStorage reads don't work"). sessionStorage stays in-memory per load
  // (a fresh popup IS a new session — matching the spec). Both installed at document-start, before any page
  // script. The seed/save wiring is absent → a missing snapshot or save hook degrades to in-memory cleanly.
  (function () {
    function makeStorage(persist) {
      var store = _Object.create(null);
      if (persist) {
        // Seed from native's last snapshot so the very first synchronous read already sees prior writes.
        try {
          var seed = W.__bb_ls_seed;
          if (seed && typeof seed === "object") {
            for (var sk in seed) {
              if (_Object.prototype.hasOwnProperty.call(seed, sk)) { store[String(sk)] = String(seed[sk]); }
            }
          }
        } catch (e) {}
      }
      var flushTimer = null;
      function snapshot() { var plain = {}; for (var k in store) { plain[k] = store[k]; } return _JSON.stringify(plain); }
      function persistNow() {
        try { if (typeof W.__bb_ls_save === "function") { W.__bb_ls_save(snapshot()); } } catch (e) {}
      }
      function flush() {
        if (!persist) { return; }
        try {
          if (flushTimer) { return; }   // debounce: coalesce a burst of writes into one native round-trip
          flushTimer = (W.setTimeout || setTimeout)(function () { flushTimer = null; persistNow(); }, 250);
        } catch (e) { persistNow(); }
      }
      if (persist) {
        // The 250 ms debounce may not fire before a dismissed popup is torn down — force a final snapshot
        // when the page is hidden/unloaded so the last write is never lost.
        try {
          var forceFlush = function () {
            try { if (flushTimer) { (W.clearTimeout || clearTimeout)(flushTimer); flushTimer = null; } } catch (e) {}
            persistNow();
          };
          W.addEventListener("pagehide", forceFlush, true);
          W.addEventListener("visibilitychange", function () {
            if (W.document && W.document.visibilityState === "hidden") { forceFlush(); }
          }, true);
        } catch (e) {}
      }
      var api = {
        getItem: function (k) { k = String(k); return _Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
        setItem: function (k, v) { store[String(k)] = String(v); flush(); },
        removeItem: function (k) { delete store[String(k)]; flush(); },
        clear: function () { for (var k in store) { delete store[k]; } flush(); },
        key: function (i) { var ks = _Object.keys(store); i = i >> 0; return (i >= 0 && i < ks.length) ? ks[i] : null; }
      };
      return new Proxy(api, {
        get: function (t, prop) {
          if (prop === "length") { return _Object.keys(store).length; }
          if (prop in t) { return t[prop]; }
          if (typeof prop === "symbol") { return undefined; }
          var k = String(prop);
          return _Object.prototype.hasOwnProperty.call(store, k) ? store[k] : undefined;
        },
        set: function (t, prop, value) {
          if (prop === "length" || prop in t) { return true; }   // never let a page clobber the API surface
          store[String(prop)] = String(value); flush(); return true;
        },
        has: function (t, prop) { return prop === "length" || prop in t || _Object.prototype.hasOwnProperty.call(store, String(prop)); },
        deleteProperty: function (t, prop) { if (prop in t) { return true; } delete store[String(prop)]; flush(); return true; },
        ownKeys: function () { return _Object.keys(store); },
        getOwnPropertyDescriptor: function (t, prop) {
          var k = String(prop);
          if (_Object.prototype.hasOwnProperty.call(store, k)) { return { value: store[k], writable: true, enumerable: true, configurable: true }; }
          return _Object.getOwnPropertyDescriptor(t, prop);
        }
      });
    }
    // Only polyfill when the real one is missing or non-functional (a write/read round-trip that throws or
    // doesn't stick) — never override a working Storage.
    function needsPolyfill(name) {
      try {
        var s = W[name];
        if (!s) { return true; }
        var probe = "__bb_ls_probe__";
        s.setItem(probe, "1"); var ok = s.getItem(probe) === "1"; s.removeItem(probe);
        return !ok;
      } catch (e) { return true; }
    }
    try { if (needsPolyfill("localStorage")) { _Object.defineProperty(W, "localStorage", { value: makeStorage(true), configurable: true }); } } catch (e) {}
    try { if (needsPolyfill("sessionStorage")) { _Object.defineProperty(W, "sessionStorage", { value: makeStorage(false), configurable: true }); } } catch (e) {}
  })();

  // --- window.MediaSource inert constructor ---------------------------------------------------------
  // WKWebView does NOT expose window.MediaSource on this extension-page origin (MSE is gated off by
  // default). MetaMask's bundled LavaMoat "SNOW" realm sandbox unconditionally TAMES window.MediaSource
  // during boot: it reads `window.MediaSource`, then `Object.setPrototypeOf(wrapper, window.MediaSource)`
  // — with MediaSource `undefined`, JSC throws "Prototype value can only be an object or null" and the
  // ENTIRE wallet UI aborts before render (the popup/home page never loads). Provide an inert MediaSource
  // constructor (a real function whose `.prototype` is a real object) ONLY when the platform lacks one, so
  // the taming step sees a valid object. This is scoped to EXTENSION PAGES (this runtime never runs on a
  // normal web page), so no streaming site is affected; any genuine MSE use still fails honestly.
  try {
    if (typeof W.MediaSource === "undefined") {
      var BBMediaSource = function MediaSource() {
        throw new TypeError("MediaSource is not supported on this platform");
      };
      _Object.defineProperty(W, "MediaSource", { value: BBMediaSource, configurable: true, writable: true });
    }
  } catch (e) {}

  // navigator.serviceWorker BRIDGE. WKWebView exposes no Service Worker for the custom chrome-/moz-
  // extension:// scheme, so navigator.serviceWorker.controller is null and `.ready` never resolves.
  // Some popups talk to their MV3 worker ENTIRELY over SW client messaging — Stylus does
  // `createPortExec(controller || ready.then(active))`, posting controller.postMessage(data, [port])
  // and RPCing over the transferred MessageChannel; with an inert controller/ready every invokeAPI call
  // awaits forever and the popup hangs blank. Present a WORKING surface: controller.postMessage tunnels
  // the message + the transferred port through a chrome.runtime port (the popup↔worker hub) to the
  // worker's self.onmessage, relaying the channel both ways. Defined at document-start, before page
  // scripts. (Also keeps register/getRegistration spec-shaped so a page that only probes the API — e.g.
  // ScriptCat's offscreen.js — degrades gracefully rather than throwing.)
  (function () {
    try {
      var swListeners = {};
      function controllerPostMessage(message, transfer) {
        var clientPort = (transfer && transfer.length && transfer[0]) || null;   // the page's MessageChannel port
        var rp;
        try { rp = runtimeConnect({ name: "__bb_swclient" }); } catch (e) { return; }
        // First frame carries the client's payload so the worker's onmessage gets event.data; the port
        // (if any) is relayed frame-by-frame in both directions over the same runtime port.
        rp.postMessage({ __bbSwInit: true, data: (message === undefined ? null : message) });
        if (clientPort) {
          try { clientPort.onmessage = function (e) { rp.postMessage({ __bbSwPort: true, data: e.data }); }; } catch (e) {}
          rp.onMessage.addListener(function (msg) { if (msg && msg.__bbSwPort) { try { clientPort.postMessage(msg.data); } catch (e) {} } });
          try { if (clientPort.start) { clientPort.start(); } } catch (e) {}
        }
      }
      var controller = { postMessage: controllerPostMessage, scriptURL: (data.baseURL || "") + "sw.js",
                         state: "activated", onstatechange: null,
                         addEventListener: function () {}, removeEventListener: function () {} };
      var registration = {
        active: controller, installing: null, waiting: null, scope: data.baseURL || "/",
        updateViaCache: "none", update: function () { return _Promise.resolve(); },
        unregister: function () { return _Promise.resolve(false); },
        addEventListener: function () {}, removeEventListener: function () {}
      };
      var sw = {
        controller: controller,
        ready: _Promise.resolve(registration),
        register: function () { return _Promise.resolve(registration); },
        getRegistration: function () { return _Promise.resolve(registration); },
        getRegistrations: function () { return _Promise.resolve([registration]); },
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

      // SW → CLIENT messaging (offscreen documents). The reverse of controller.postMessage above: an MV3
      // service worker reaches its offscreen document via clients.matchAll() + client.postMessage(data,
      // [port]); the document receives it on navigator.serviceWorker.onmessage with the transferred port
      // as event.ports[0]. WKWebView exposes no real SW and the worker (a headless JSContext) can't open
      // a port toward us — so the offscreen page opens a persistent "__bb_swclient_host" runtime port,
      // announces its URL, and the worker pushes client.postMessage payloads back over it. Stylus runs ALL
      // of its offscreen RPCs over this — usercss parsing (a NESTED Web Worker whose port is transferred
      // back to the SW), blob URLs, prefers-color-scheme — so the relay supports MessagePort transfer,
      // recursively. Only the offscreen document registers (popups talk to the worker the other way, via
      // controller.postMessage). Channel ids are 'c<n>' here vs the worker's 'w<n>', so they never collide.
      if (data && data.kind === "offscreen" && handler) {
        try {
          var fireSwMessage = function (ev) {
            if (typeof sw.onmessage === "function") { try { sw.onmessage(ev); } catch (e) {} }
            var ls = swListeners.message;
            if (ls) { for (var i = 0; i < ls.length; i++) { try { ls[i](ev); } catch (e) {} } }
          };
          var hostPort = runtimeConnect({ name: "__bb_swclient_host" });
          var channels = _Object.create(null);   // chId -> { deliver: function (data, ports) }
          var chSeq = 0;
          var registerTransfers = function (portList) {
            var ids = [];
            if (!portList || !portList.length) { return ids; }
            for (var i = 0; i < portList.length; i++) {
              (function (p) {
                if (!p) { return; }
                var ch = "c" + (++chSeq);
                p.onmessage = function (e) {
                  try { hostPort.postMessage({ k: "p", ch: ch, data: e && e.data, ports: registerTransfers(e && e.ports) }); } catch (x) {}
                };
                try { if (p.start) { p.start(); } } catch (x) {}
                channels[ch] = { deliver: function (d, ports) { try { p.postMessage(d, reconstruct(ports)); } catch (x) {} } };
                ids.push(ch);
              })(portList[i]);
            }
            return ids;
          };
          var reconstruct = function (ids) {
            var out = [];
            if (!ids || !ids.length) { return out; }
            for (var i = 0; i < ids.length; i++) { out.push(makeBridgedPort(ids[i])); }
            return out;
          };
          var makeBridgedPort = function (ch) {
            var listeners = [];
            var bp = {
              onmessage: null, onmessageerror: null, onerror: null,
              postMessage: function (d, transfer) {
                try { hostPort.postMessage({ k: "p", ch: ch, data: d, ports: registerTransfers(transfer) }); } catch (x) {}
              },
              start: function () {}, close: function () {},
              addEventListener: function (t, fn) { if (t === "message" && typeof fn === "function") { listeners.push(fn); } },
              removeEventListener: function (t, fn) { var i = listeners.indexOf(fn); if (i >= 0) { listeners.splice(i, 1); } }
            };
            channels[ch] = { deliver: function (d, ports) {
              var ev = { data: d, ports: reconstruct(ports), type: "message", origin: "", lastEventId: "", source: null };
              if (typeof bp.onmessage === "function") { try { bp.onmessage(ev); } catch (x) {} }
              for (var i = 0; i < listeners.length; i++) { try { listeners[i](ev); } catch (x) {} }
            } };
            return bp;
          };
          hostPort.onMessage.addListener(function (msg) {
            if (!msg) { return; }
            if (msg.k === "cmsg") {
              fireSwMessage({ data: (msg.data === undefined ? null : msg.data), ports: reconstruct(msg.ports),
                              type: "message", origin: "", lastEventId: "", source: null });
            } else if (msg.k === "p") {
              var c = channels[msg.ch];
              if (c) { c.deliver(msg.data, msg.ports); }
            }
          });
          hostPort.postMessage({ k: "init", url: (W.location && W.location.href) || "", kind: "offscreen" });
        } catch (e) { /* offscreen client registration is best-effort */ }
      }
    } catch (e) { /* navigator may be a non-configurable native; nothing we can do, but don't break the page */ }
  })();

  // --- Blob object-URL polyfill -------------------------------------------------------------------
  // WebKit REFUSES URL.createObjectURL on a custom-scheme (chrome-extension://) origin — it throws a
  // TypeError ("createObjectURL@[native code]"). That breaks any extension page that turns a Blob into a
  // URL: Tampermonkey's OFFSCREEN document does exactly this to hand a decoded userscript back to its
  // worker (the "import from URL → stuck at 'Decoding…'" bug). Consumers fetch the URL
  // (`fetch(objUrl).then(r => r.blob())` — TM's path) and don't require the literal `blob:` scheme, so we
  // keep the Blob in-page in a Map and answer it from the fetch wrapper below. Lifetime matches a real
  // object URL (alive until revoked / page unload), and TM creates AND consumes it in the same document.
  var __bbObjectUrls = new (W.Map || Map)();   // url string -> Blob
  (function () {
    var URLCtor = W.URL;
    if (!URLCtor || typeof URLCtor.createObjectURL !== "function") { return; }
    var BlobCtor = W.Blob;
    var nativeCreate = URLCtor.createObjectURL;
    var nativeRevoke = URLCtor.revokeObjectURL;
    var seq = 0;
    URLCtor.createObjectURL = function (obj) {
      if (BlobCtor && obj instanceof BlobCtor) {   // covers File (extends Blob) too
        seq += 1;
        // Mimic a real blob URL's shape (blob:<origin>/<id>) so a consumer that does
        // String(u).startsWith("blob:") or new URL(u).protocol === "blob:" still sees what it expects.
        var key = "blob:" + W.location.origin + "/bb-" + seq + "-" +
          Math.floor(Math.random() * 1e9).toString(36);
        __bbObjectUrls.set(key, obj);
        return key;
      }
      // MediaSource / MediaStream — defer to the platform (our store only covers Blobs/Files; the native
      // call may still throw on this origin, but that is the platform's own behavior, not ours to mask).
      return nativeCreate.call(URLCtor, obj);
    };
    URLCtor.revokeObjectURL = function (url) {
      if (__bbObjectUrls.has(url)) { __bbObjectUrls.delete(url); return; }
      try { nativeRevoke.call(URLCtor, url); } catch (e) { /* unknown/native url — ignore */ }
    };
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
      } catch (e) { return origFetch(input, init); }
      // An in-page Blob object URL minted by our createObjectURL polyfill — WebKit can't fetch a synthetic
      // blob: URL on a custom-scheme origin, but we hold the Blob, so answer straight from it (any method;
      // a body is irrelevant for a blob fetch). This is what makes `fetch(objUrl).blob()` work.
      if (__bbObjectUrls.has(url)) {
        return _Promise.resolve(new Response(__bbObjectUrls.get(url)));
      }
      try {
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
      var msg = "Unhandled promise rejection: " + ((r && r.message) ? r.message : String(r));
      // Append the stack (file:line of the throwing frame) — a rejection with no source is undiagnosable
      // (a bare "undefined is not an object (evaluating 'e.replace')" names neither the page nor the API
      // that resolved undefined). The window 'error' handler already attaches a stack; mirror it here.
      if (r && r.stack) { msg += "\n" + r.stack; }
      emit("error", [msg]);
    });
  })();

  // One-shot DOM-storage availability probe. Some extension pages (Momentum, Tabliss, …) keep ALL their
  // state in window.localStorage / IndexedDB rather than chrome.storage — they don't even request the
  // `storage` permission. On the chrome-extension:// custom-scheme page origin, DOM storage can be
  // unavailable or non-persistent (a WebKit custom-scheme limitation): localStorage may throw, and
  // IndexedDB.open() fails ASYNCHRONOUSLY — open() never succeeds, with NO thrown error — so the page
  // just hangs on its loading spinner with nothing in the log (the reported Momentum "stuck on the M"
  // symptom). Probe both and surface ONE tagged line ONLY when something is missing or fails — turning an
  // invisible stuck-load into a diagnosable cause. Silent (no log) when storage works, so it's noise-free
  // for the common case where pages use chrome.storage.
  (function () {
    function note(msg) {
      try { bridge("runtime.pageLog", { level: "error", message: "[bb-storage-probe] " + msg }).catch(function () {}); } catch (e) {}
    }
    try {
      if (!W.localStorage) { note("window.localStorage is undefined on this page origin"); }
      else {
        var k = "__bb_storage_probe__";
        W.localStorage.setItem(k, "1");
        if (W.localStorage.getItem(k) !== "1") { note("localStorage write/read did not round-trip"); }
        W.localStorage.removeItem(k);
      }
    } catch (e) { note("localStorage threw: " + (e && e.message ? e.message : e)); }
    try {
      if (!W.indexedDB || typeof W.indexedDB.open !== "function") {
        note("window.indexedDB is unavailable on this page origin — pages that store data in IndexedDB (Momentum/Tabliss) will hang on load");
      } else {
        var req = W.indexedDB.open("__bb_storage_probe_db__", 1);
        req.onerror = function () {
          note("indexedDB.open errored: " + ((req.error && req.error.message) || "unknown")
            + " — pages that store data in IndexedDB (Momentum/Tabliss) will hang on load");
        };
        req.onblocked = function () { note("indexedDB.open blocked"); };
        req.onsuccess = function () { try { req.result.close(); W.indexedDB.deleteDatabase("__bb_storage_probe_db__"); } catch (e) {} };
      }
    } catch (e) { note("indexedDB threw: " + (e && e.message ? e.message : e)); }
  })();

  var messages = data.messages || {};
  // messageKey → { placeholderName(lowercased): content } for chrome.i18n named placeholders.
  var i18nPlaceholders = data.placeholders || {};
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
  // proxy.onRequest is Firefox's blocking PAC-in-JS hook (Sidebery registers it); it cannot run on iOS
  // WKWebView, so it's an inert event — present so addListener doesn't throw, but never fires.
  var proxyApi = { settings: makePrivacySetting(), onProxyError: makeEvent([]), onRequest: makeEvent([]) };

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
  // Native returns the stored JSON string, or null when the key was never set. Firefox resolves an unset
  // key to undefined (NOT null) — Sidebery branches on `=== undefined`, so the distinction matters.
  function decodeSessionValue(raw) {
    if (raw === null || raw === undefined) { return undefined; }
    try { return _JSON.parse(raw); } catch (e) { return raw; }
  }
  var sessionsApi = {
    getRecentlyClosed: function (filter, cb) { return pres([], (typeof filter === "function") ? filter : cb); },
    getDevices: function (filter, cb) { return pres([], (typeof filter === "function") ? filter : cb); },
    restore: function (sessionId, cb) { return pres({}, (typeof sessionId === "function") ? sessionId : cb); },
    // Firefox per-window / per-tab session values. Sidebery (MV2 bg PAGE + sidebar_action) calls
    // getWindowValue with BOTH a resolved window id and windows.WINDOW_ID_CURRENT (-2); iOS is single-
    // window, so every window id collapses to ONE native bucket ("w"). Values are JSON; an unset key
    // resolves to undefined. Routed natively so the bg page and sidebar share one live, persisted store.
    getWindowValue: function (windowId, key, cb) {
      return settle(bridge("sessions.getValue", { scope: "window", id: "w", key: String(key) })
        .then(decodeSessionValue), cb);
    },
    setWindowValue: function (windowId, key, value, cb) {
      return settle(bridge("sessions.setValue", { scope: "window", id: "w", key: String(key),
        value: _JSON.stringify(value === undefined ? null : value) }).then(function () { return undefined; }), cb);
    },
    removeWindowValue: function (windowId, key, cb) {
      return settle(bridge("sessions.removeValue", { scope: "window", id: "w", key: String(key) })
        .then(function () { return undefined; }), cb);
    },
    getTabValue: function (tabId, key, cb) {
      return settle(bridge("sessions.getValue", { scope: "tab", id: String(tabId), key: String(key) })
        .then(decodeSessionValue), cb);
    },
    setTabValue: function (tabId, key, value, cb) {
      return settle(bridge("sessions.setValue", { scope: "tab", id: String(tabId), key: String(key),
        value: _JSON.stringify(value === undefined ? null : value) }).then(function () { return undefined; }), cb);
    },
    removeTabValue: function (tabId, key, cb) {
      return settle(bridge("sessions.removeValue", { scope: "tab", id: String(tabId), key: String(key) })
        .then(function () { return undefined; }), cb);
    },
    MAX_SESSION_RESULTS: 25,
    onChanged: makeEvent([])
  };
  // Firefox browser.theme — iOS WKWebView has no Firefox theme, but getCurrent must return a valid (empty)
  // theme object rather than be undefined, or a consumer (Sidebery, in Firefox mode) crashes reading it.
  var themeApi = {
    getCurrent: function (windowId, cb) {
      var c = (typeof windowId === "function") ? windowId : cb;
      return pres({ colors: null, images: null, properties: null }, c);
    },
    update: function () { var c = arguments[arguments.length - 1]; return pres(undefined, (typeof c === "function") ? c : undefined); },
    reset: function () { var c = arguments[arguments.length - 1]; return pres(undefined, (typeof c === "function") ? c : undefined); },
    onUpdated: makeEvent([])
  };
  // Firefox browser.contextualIdentities (containers) — iOS has none; present an inert namespace so the
  // sidebar shows "no containers" instead of throwing. query MUST resolve [] (not reject), the rest reject.
  var contextualIdentitiesApi = {
    query: function (details, cb) { return settle(_Promise.resolve([]), (typeof details === "function") ? details : cb); },
    get: function (id, cb) { return settle(_Promise.reject(new Error("No contextual identity: " + id)), cb); },
    create: function (details, cb) { return settle(_Promise.reject(new Error("contextualIdentities unsupported")), cb); },
    update: function (id, details, cb) { return settle(_Promise.reject(new Error("contextualIdentities unsupported")), cb); },
    remove: function (id, cb) { return settle(_Promise.reject(new Error("contextualIdentities unsupported")), cb); },
    move: function (id, position, cb) { return settle(_Promise.reject(new Error("contextualIdentities unsupported")), (typeof position === "function") ? position : cb); },
    onCreated: makeEvent([]), onUpdated: makeEvent([]), onRemoved: makeEvent([])
  };
  // Firefox browser.fontSettings.getFontList → []; browser.browsingData.remove* → resolve. Both are
  // typeof/permission-guarded by the extensions that use them (Dark Reader popup, Multi-Account Containers),
  // so they're non-blocking, but present so the guarded branch resolves instead of hitting undefined.
  var fontSettingsApi = {
    getFontList: function (cb) { return pres([], cb); },
    getFont: function (d, cb) { return pres({ fontId: "", levelOfControl: "not_controllable" }, (typeof d === "function") ? d : cb); },
    setFont: function (d, cb) { return pres(undefined, (typeof d === "function") ? d : cb); },
    clearFont: function (d, cb) { return pres(undefined, (typeof d === "function") ? d : cb); }
  };
  var browsingDataApi = {
    settings: function (cb) { return pres({ options: {}, dataToRemove: {}, dataRemovalPermitted: {} }, cb); },
    remove: function (opts, data, cb) { return pres(undefined, (typeof opts === "function") ? opts : ((typeof data === "function") ? data : cb)); },
    removeCookies: function (opts, cb) { return pres(undefined, (typeof opts === "function") ? opts : cb); },
    removeLocalStorage: function (opts, cb) { return pres(undefined, (typeof opts === "function") ? opts : cb); },
    removeCache: function (opts, cb) { return pres(undefined, (typeof opts === "function") ? opts : cb); },
    removeHistory: function (opts, cb) { return pres(undefined, (typeof opts === "function") ? opts : cb); }
  };
  var searchApi = {
    query: function (info, cb) { return pres(undefined, cb); },
    // Firefox browser.search.search({query, tabId}) runs a search in a tab; get([]) lists engines. Inert
    // (no on-device search-engine routing yet) but present so Sidebery's search panel doesn't throw.
    search: function (details, cb) { return pres(undefined, (typeof details === "function") ? details : cb); },
    get: function (cb) { return pres([], cb); }
  };
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

  // Chrome's documented per-area quota constants (some scripts size writes against QUOTA_BYTES_PER_ITEM).
  // managed is read-only (no quota). Standard Chrome values.
  function withStorageQuotas(area, name) {
    if (name === "sync") {
      area.QUOTA_BYTES = 102400; area.QUOTA_BYTES_PER_ITEM = 8192; area.MAX_ITEMS = 512;
      area.MAX_WRITE_OPERATIONS_PER_HOUR = 1800; area.MAX_WRITE_OPERATIONS_PER_MINUTE = 120;
    } else if (name !== "managed") { area.QUOTA_BYTES = 10485760; }
    return area;
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
    // 1. Named placeholders: a message may be "$NAME$ $VERSION$ is available" with a declared
    //    placeholders map {name:{content:"$1"}, version:{content:"$2"}}. Chrome substitutes $name$ with
    //    its content (case-insensitive name) BEFORE positional args; without this the literal "$version$"
    //    leaks into the UI (Tampermonkey's options/popup version line). Unknown $tokens$ are left as-is.
    var ph = i18nPlaceholders[key];
    if (ph) {
      text = text.replace(/\$([A-Za-z0-9_@]+)\$/g, function (whole, name) {
        var content = ph[name.toLowerCase()];
        return (typeof content === "string") ? content : whole;
      });
    }
    // 2. Positional substitutions ($1..$9) + the $$ escape — only when args are supplied, so a message
    //    containing a literal "$5" with no substitutions is left untouched (matches Chrome).
    if (substitutions != null) {
      var subs = _Array.isArray(substitutions) ? substitutions : [substitutions];
      text = text.replace(/\$([1-9])\$?|\$\$/g, function (m, d) {
        if (m === "$$") { return "$"; }
        var i = parseInt(d, 10) - 1;
        return (i >= 0 && i < subs.length && subs[i] != null) ? subs[i] : "";
      });
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
    function removeCSS(tabId, details, callback) {   // MV2 chrome.tabs.removeCSS — undo a prior insertCSS
      if (tabId !== null && typeof tabId === "object") { callback = details; details = tabId; tabId = undefined; }
      details = details || {};
      return settle(bridge("tabs.removeCSS", { tabId: tabId, code: details.code, file: details.file }).then(function () { return undefined; }), callback);
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
      // Chrome exposes these as enumerable static numeric constants on the tabs namespace. TAB_ID_NONE marks
      // a tab.id that doesn't reference a real tab; MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND is the per-second
      // rate cap for captureVisibleTab. Feature-detectors (Web Developer) enumerate the namespace and read
      // them, so they must exist with Chrome's exact values even though iOS doesn't rate-limit captures.
      TAB_ID_NONE: -1, MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2,
      query: query, get: get, getCurrent: getCurrent, create: create, update: update, remove: remove, reload: reload,
      executeScript: executeScript, insertCSS: insertCSS, removeCSS: removeCSS, sendMessage: sendMessage,
      captureVisibleTab: captureVisibleTab, move: move, duplicate: duplicate, getZoom: getZoom, setZoom: setZoom,
      // iOS has no tab groups — non-throwing no-ops so unguarded callers don't crash (see background).
      group: function (options, cb) { return settle(Promise.resolve(-1), cb); },
      ungroup: function (tabIds, cb) { return settle(Promise.resolve(undefined), cb); },
      // Firefox-specific tab management — no analog in BrownBear's single-tab iOS model, but present and
      // non-throwing so a Firefox extension (Sidebery) that calls them at init doesn't crash. Inert:
      // hide reports nothing hidden, captureTab yields an empty image, the rest resolve void.
      hide: function (tabIds, cb) { return settle(_Promise.resolve([]), (typeof tabIds === "function") ? tabIds : cb); },
      show: function (tabIds, cb) { return settle(_Promise.resolve(undefined), (typeof tabIds === "function") ? tabIds : cb); },
      discard: function (tabIds, cb) { return settle(_Promise.resolve(undefined), (typeof tabIds === "function") ? tabIds : cb); },
      warmup: function (tabId, cb) { return settle(_Promise.resolve(undefined), (typeof tabId === "function") ? tabId : cb); },
      highlight: function (info, cb) { return settle(_Promise.resolve({ tabs: [] }), (typeof info === "function") ? info : cb); },
      moveInSuccession: function () { var c = arguments[arguments.length - 1]; return settle(_Promise.resolve(undefined), (typeof c === "function") ? c : undefined); },
      captureTab: function () { var c = arguments[arguments.length - 1]; return settle(_Promise.resolve(""), (typeof c === "function") ? c : undefined); },
      // tabs.connect(tabId, info) opens a Port to a tab's content script (Violentmonkey/Stylus install-
      // from-tab). Live port-to-content-script routing isn't wired here yet, so return an inert Port that
      // looks immediately disconnected — the caller degrades instead of crashing on undefined.
      connect: function () {
        return { name: "", sender: undefined, postMessage: function () {}, disconnect: function () {},
                 onMessage: makeEvent([]), onDisconnect: makeEvent([]) };
      },
      toggleReaderMode: function (tabId, cb) { return settle(_Promise.resolve(undefined), (typeof tabId === "function") ? tabId : cb); },
      onCreated: makeEvent(tabEventLists["tabs.onCreated"]),
      onUpdated: makeEvent(tabEventLists["tabs.onUpdated"]),
      onActivated: makeEvent(tabEventLists["tabs.onActivated"]),
      onRemoved: makeEvent(tabEventLists["tabs.onRemoved"]),
      onReplaced: makeEvent([]),
      // iOS is single-window, so tabs never attach/detach/move between windows — these never fire, but
      // they must EXIST: Stylus's editor (edit.js) registers chrome.tabs.onAttached.addListener
      // unconditionally at init, and `undefined.addListener` threw an unhandled rejection that aborted the
      // whole page's module init. Inert no-ops keep such pages alive.
      onAttached: makeEvent([]),
      onDetached: makeEvent([]),
      onMoved: makeEvent([]),
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
      // Chrome exposes the injection-world enum on chrome.scripting; a popup/options page reads
      // chrome.scripting.ExecutionWorld.MAIN directly (a Firefox adblocker's popup.js does), and its
      // absence throws "undefined is not an object (reading 'MAIN')" before the page finishes booting.
      ExecutionWorld: { ISOLATED: "ISOLATED", MAIN: "MAIN" },
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
      // Firefox action/browserAction.getUserSettings → { isOnToolbar }. LanguageTool/Privacy Badger read it
      // (typeof-guarded, so non-blocking) — present so the guard resolves and the popup can branch.
      getUserSettings: function (cb) { var s = { isOnToolbar: true }; if (typeof cb === "function") { cb(s); return undefined; } return _Promise.resolve(s); },
      getPopup: getter("action.getPopup"),
      openPopup: function (cb) { return pres(undefined, cb); },
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
    // Chrome 121+ split the combined dynamic/session cap into per-bucket limits, and adblockers
    // (uBO/uBO Lite, AdGuard, Ghostery) read these directly to chunk their rule writes. These are
    // namespace constants Chrome exposes in EVERY extension context (popup/options too), so the page
    // shim must match the background shim or a `rules.length < MAX_…` guard compares against undefined.
    MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000,
    MAX_NUMBER_OF_SESSION_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
    MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000,
    MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
    GUARANTEED_MINIMUM_STATIC_RULES: 30000,
    GETMATCHEDRULES_QUOTA_INTERVAL: 10, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20,
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
    onRuleMatchedDebug: { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } }
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
      // Firefox menus.overrideContext (Sidebery uses it to show a custom menu in its sidebar). It only
      // affects the NEXT contextmenu event's menu set; on iOS we have no such hook, so it's an inert no-op
      // (present so the call doesn't throw). Harmless on the Chrome `contextMenus` alias (never called there).
      overrideContext: function () { return undefined; },
      // Firefox menus.onShown/onHidden fire around the native context menu; Tree Style Tab registers them
      // UNGUARDED at background top-level, so their absence threw on `.addListener` and killed bg init. No
      // iOS hook → inert events. refresh() re-reads the menu during a shown event → inert resolve.
      onShown: makeEvent([]), onHidden: makeEvent([]),
      refresh: function (cb) { return pres(undefined, cb); },
      ACTION_MENU_TOP_LEVEL_LIMIT: 6
    };
  }

  var chrome = {
    storage: {
      local: withStorageQuotas(storageArea("local"), "local"),
      sync: withStorageQuotas(storageArea("sync"), "sync"),
      session: withStorageQuotas(storageArea("session"), "session"),
      managed: storageArea("managed"),   // read-only policy store; resolves {} with no MDM policy
      onChanged: makeEvent(storageListeners)
    },
    // chrome.identity — getRedirectURL is the real Chrome value an extension registers as its OAuth redirect
    // URI; launchWebAuthFlow presents a native system auth session (ASWebAuthenticationSession, iOS 17.4+)
    // and resolves with the redirect URL the provider lands on. Popups/options pages are the usual caller.
    identity: {
      getRedirectURL: function (path) {
        var p = (path == null) ? "" : String(path);
        if (p.charAt(0) === "/") { p = p.slice(1); }
        return "https://" + data.extensionId + ".chromiumapp.org/" + p;
      },
      launchWebAuthFlow: function (details, cb) {
        details = details || {};
        return settle(bridge("identity.launchWebAuthFlow",
          { url: details.url, interactive: details.interactive === true }), cb);
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
    // chrome.readingList — Chrome's MV3 reading list. iOS has no reading-list store; an inert query→[]
    // (+ no-op mutators) mirrors the background shim so an extension PAGE that calls it directly — e.g.
    // OneTab's onetab.html "import from Reading List" flow does `chrome.readingList.query({})` — doesn't
    // throw "chrome.readingList is undefined" once the user grants the optional permission and picks it.
    readingList: {
      query: function (info, cb) { return settle(_Promise.resolve([]), cb); },
      addEntry: function (entry, cb) { return settle(_Promise.resolve(undefined), cb); },
      removeEntry: function (info, cb) { return settle(_Promise.resolve(undefined), cb); },
      updateEntry: function (info, cb) { return settle(_Promise.resolve(undefined), cb); },
      onEntryAdded: makeEvent([]), onEntryRemoved: makeEvent([]), onEntryUpdated: makeEvent([])
    },
    declarativeNetRequest: declarativeNetRequest,
    userScripts: userScripts,
    privacy: privacyApi,
    proxy: proxyApi,
    idle: idleApi,
    downloads: downloadsApi,
    bookmarks: bookmarksApi,
    history: historyApi,
    sessions: sessionsApi,
    theme: themeApi,
    contextualIdentities: contextualIdentitiesApi,
    fontSettings: fontSettingsApi,
    browsingData: browsingDataApi,
    extensionTypes: { ImageFormat: { JPEG: "jpeg", PNG: "png" }, RunAt: { DOCUMENT_START: "document_start", DOCUMENT_END: "document_end", DOCUMENT_IDLE: "document_idle" }, CSSOrigin: { USER: "user", AUTHOR: "author" } },
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
      // Firefox browser.commands.update/reset reassign a shortcut (Sidebery's keybinding settings). No
      // bound-command surface on iOS, so these are inert resolves — present so the calls don't throw.
      update: function (details, cb) { return pres(undefined, (typeof details === "function") ? details : cb); },
      reset: function (name, cb) { return pres(undefined, (typeof name === "function") ? name : cb); },
      onCommand: makeEvent([]), onChanged: makeEvent([])
    },
    // Firefox browser.sidebarAction (Sidebery IS a sidebar_action extension). Its sidebar runs as this very
    // page, so isOpen reports true and open/close/toggle are no-ops; the title/panel/icon setters are inert
    // but present so Sidebery's calls don't throw. moz-extension-only; harmless on Chrome (never called).
    sidebarAction: {
      isOpen: function (details, cb) { return settle(_Promise.resolve(true), (typeof details === "function") ? details : cb); },
      open: function (cb) { return pres(undefined, cb); },
      close: function (cb) { return pres(undefined, cb); },
      toggle: function (cb) { return pres(undefined, cb); },
      setPanel: function (details, cb) { return pres(undefined, (typeof details === "function") ? details : cb); },
      getPanel: function (details, cb) { return pres("", (typeof details === "function") ? details : cb); },
      setTitle: function (details, cb) { return pres(undefined, (typeof details === "function") ? details : cb); },
      getTitle: function (details, cb) { return pres("", (typeof details === "function") ? details : cb); },
      setIcon: function (details, cb) { return pres(undefined, (typeof details === "function") ? details : cb); }
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
      // uBlock Origin's vAPI.Tabs constructor registers onCreatedNavigationTarget UNGUARDED at background
      // top-level, so its absence threw and aborted uBO's background init. No iOS analog (it fires when a
      // navigation opens a new tab/window) → inert event, present so .addListener doesn't throw.
      onCreatedNavigationTarget: makeEvent([]),
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
      getPlatformInfo: function (cb) { var info = { os: "ios", arch: "arm64", nacl_arch: "arm64" }; if (typeof cb === "function") { cb(info); return undefined; } return _Promise.resolve(info); },
      // Firefox browser.runtime.getBrowserInfo — present (a non-Firefox-shaped object, so version-gated FF
      // code paths stay off) so backgrounds/sidebars that `await getBrowserInfo()` at init (Tree Style Tab,
      // Simple Tab Groups, Violentmonkey, image-search) don't throw "is not a function".
      getBrowserInfo: function (cb) {
        var info = { name: "BrownBear", vendor: "BrownBear", version: (manifest && manifest.version) || "1.0", buildID: "0" };
        if (typeof cb === "function") { cb(info); return undefined; } return _Promise.resolve(info);
      },
      // runtime.reload — restart the extension. Inert page-side; routed so a future native handler can act,
      // wrapped so a missing handler never throws (uBO/Stylus/STG "restart" buttons just no-op for now).
      reload: function () { try { bridge("runtime.reload", {}); } catch (e) {} return undefined; },
      // runtime.getBackgroundPage — MV3 has no persistent background window; Stylus/STG call it at init and
      // crashed on undefined. Return null (Chrome returns the window or null) so the page proceeds.
      getBackgroundPage: function (cb) { if (typeof cb === "function") { cb(null); return undefined; } return _Promise.resolve(null); },
      // runtime.getContexts (MV3) — no extension-context registry on iOS; resolve [] so an awaiting caller
      // doesn't throw (Tab Session Manager).
      getContexts: function (filter, cb) { return pres([], (typeof filter === "function") ? filter : cb); },
      // runtime.connectNative — no native-messaging hosts on iOS; hand back an inert Port that immediately
      // looks disconnected so a try-wrapped caller (multi-account-containers' Firefox VPN) degrades.
      connectNative: function () {
        return { name: "", postMessage: function () {}, disconnect: function () {},
                 onMessage: makeEvent([]), onDisconnect: makeEvent([]) };
      },
      OnInstalledReason: { INSTALL: "install", UPDATE: "update", CHROME_UPDATE: "chrome_update", BROWSER_UPDATE: "browser_update", SHARED_MODULE_UPDATE: "shared_module_update" },
      OnRestartRequiredReason: { APP_UPDATE: "app_update", OS_UPDATE: "os_update", PERIODIC: "periodic" },
      PlatformOs: { MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" },
      PlatformArch: { ARM: "arm", ARM64: "arm64", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" }
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
      getAcceptLanguages: function (cb) { var langs = [(W.navigator && W.navigator.language) || "en"]; if (typeof cb === "function") { cb(langs); return undefined; } return _Promise.resolve(langs); },
      // chrome.i18n.detectLanguage(text) — Chrome returns {isReliable, languages:[{language, percentage}]}.
      // A popup that calls `chrome.i18n.detectLanguage(text).then(...)` (an adblocker's popup_compiled.js
      // does) crashed on undefined.then without this. Route to the background's native detector; it always
      // returns a promise so the page degrades gracefully (an 'und' result) rather than throwing.
      detectLanguage: function (text, cb) { return settle(bridge("i18n.detectLanguage", { text: String(text == null ? "" : text) }), cb); }
    },
    extension: {
      getURL: getURL,
      inIncognitoContext: false,
      // chrome.extension.* legacy surface real pages still read. getBackgroundPage is synchronous in
      // Chrome and returns null under MV3 (no persistent background page) — provide the function so a
      // popup calling it gets null instead of "getBackgroundPage is not a function". The access checks
      // resolve false (iOS WKWebView grants extensions neither file-scheme nor incognito access).
      getBackgroundPage: function () { return null; },
      getViews: function () { return []; },
      isAllowedFileSchemeAccess: function (cb) { if (typeof cb === "function") { cb(false); return undefined; } return _Promise.resolve(false); },
      isAllowedIncognitoAccess: function (cb) { if (typeof cb === "function") { cb(false); return undefined; } return _Promise.resolve(false); }
    }
  };

  W.chrome = chrome;
  W.browser = chrome;

  // Native push surface: storage.onChanged is delivered by the host evaluating into this page.
  var __bbExtPageBridge = {
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

  // Lock the native→page bridge as a NON-configurable, NON-writable own property so a hardened bundle
  // that scuttles globalThis can't replace it with a throwing getter. LavaMoat's scuttleGlobalThis
  // (MetaMask) walks every own window property and, for any not in its allowlist, installs a throwing
  // accessor IF the prop is configurable, a throwing Proxy IF non-configurable-but-writable, and SKIPS
  // it only when it is BOTH non-configurable AND non-writable (`if (desc.writable !== true) return`) —
  // which is exactly why `chrome`/`browser` survive. A plain `W.__brownbearExtPage = {…}` is
  // configurable, so it was scuttled into a getter that throws "property … is inaccessible under
  // scuttling mode" the instant native evaluated `window.__brownbearExtPage.dispatchX(...)`, killing
  // every push (messages, ports, storage/cookie/notification events) into the wallet UI. Locking it
  // here makes scuttle skip it. The bridge object is fully assembled above and only ever READ by native
  // afterward (its members stay mutable; only the binding is frozen), so immutability is safe. Use the
  // captured `_Object` so a page that tampered with Object.defineProperty can't subvert the lock; the
  // try/catch degrades to today's plain assignment (never worse) if defineProperty is unavailable.
  try {
    _Object.defineProperty(W, "__brownbearExtPage",
      { value: __bbExtPageBridge, writable: false, configurable: false, enumerable: false });
  } catch (e) { W.__brownbearExtPage = __bbExtPageBridge; }
  try {
    _Object.defineProperty(W, "__brownbearExtPageReady",
      { value: true, writable: false, configurable: false, enumerable: false });
  } catch (e) { W.__brownbearExtPageReady = true; }
})();
