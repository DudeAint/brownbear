//
//  brownbear-webext-background.js
//  BrownBear
//
//  The chrome.* / browser.* surface for an extension BACKGROUND context (MV2 background scripts and
//  MV3 service workers), running headless in a JavaScriptCore JSContext — there is no DOM, no
//  `window`, no `fetch` beyond what we expose. Native blocks (installed before this file runs by
//  WebExtensionBackgroundContext) back the async parts: __bb_storage_*, __bb_alarm_*, __bb_log,
//  __bb_send_message, __bb_message_response, __bb_tabs, __bb_tabs_send_message, __bb_scripting. This
//  file wires the idiomatic chrome shape around them and exposes a single dispatch object (__bbBg) the
//  native side calls to deliver events.
//
//  Isolation: this runs in its own JSContext per extension, so one extension's globals, listeners,
//  and storage namespace never touch another's.
//

(function () {
  'use strict';

  var manifest = {};
  try { manifest = typeof __bbBgManifest === 'string' ? JSON.parse(__bbBgManifest) : {}; } catch (e) {}
  var extId = (typeof __bbBgExtId === 'string') ? __bbBgExtId : '';
  var baseURL = (typeof __bbBgBaseURL === 'string') ? __bbBgBaseURL : '';
  var messages = {};
  try { messages = typeof __bbBgMessages === 'string' ? JSON.parse(__bbBgMessages) : {}; } catch (e) {}

  function parseJSON(s) {
    if (s === null || s === undefined) { return undefined; }
    try { return JSON.parse(s); } catch (e) { return undefined; }
  }
  function deepClone(v) {
    if (v === undefined) { return undefined; }
    try { return JSON.parse(JSON.stringify(v)); } catch (e) { return undefined; }
  }

  // ---------------------------------------------------------------- console + timers
  // JavaScriptCore gives us neither, and background scripts lean on both. console.* routes to the
  // app log; the timer shims are backed by native GCD timers on this context's own queue.

  (function () {
    function fmt(a) { try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); } }
    function join() { return Array.prototype.map.call(arguments, fmt).join(' '); }
    globalThis.console = {
      log: function () { __bb_log('info', join.apply(null, arguments)); },
      info: function () { __bb_log('info', join.apply(null, arguments)); },
      warn: function () { __bb_log('warn', join.apply(null, arguments)); },
      error: function () { __bb_log('error', join.apply(null, arguments)); },
      debug: function () { __bb_log('debug', join.apply(null, arguments)); },
      trace: function () { __bb_log('debug', join.apply(null, arguments)); }
    };
    globalThis.setTimeout = function (fn, ms) {
      if (typeof fn !== 'function') { return 0; }
      var extra = Array.prototype.slice.call(arguments, 2);
      return __bb_set_timeout(function () { fn.apply(null, extra); }, ms || 0, false);
    };
    globalThis.setInterval = function (fn, ms) {
      if (typeof fn !== 'function') { return 0; }
      var extra = Array.prototype.slice.call(arguments, 2);
      return __bb_set_timeout(function () { fn.apply(null, extra); }, ms || 0, true);
    };
    globalThis.clearTimeout = function (id) { __bb_clear_timer(id || 0); };
    globalThis.clearInterval = function (id) { __bb_clear_timer(id || 0); };
    globalThis.queueMicrotask = globalThis.queueMicrotask || function (fn) { Promise.resolve().then(fn); };

    // ---------------------------------------------------------------- Web Crypto + importScripts
    // JavaScriptCore ships neither. ScriptCat-derived service workers and any crypto-using extension
    // throw "Can't find variable: crypto" / "Can't find variable: importScripts" without these. We
    // back getRandomValues / randomUUID / subtle.digest with native secure-random + CryptoKit
    // (__bb_crypto_*), and importScripts with a synchronous fetch of the extension's own packaged
    // files or an http(s) URL (__bb_import_script), evaluated in global scope.
    if (!globalThis.crypto || typeof globalThis.crypto.getRandomValues !== 'function') {
      var digestName = function (algo) {
        if (typeof algo === 'string') { return algo; }
        if (algo && typeof algo.name === 'string') { return algo.name; }
        return '';
      };
      globalThis.crypto = {
        getRandomValues: function (typedArray) {
          if (!typedArray || typeof typedArray.length !== 'number') {
            throw new TypeError('getRandomValues expects an integer TypedArray');
          }
          if (typedArray.BYTES_PER_ELEMENT === 8) {
            throw new Error("getRandomValues does not support 64-bit arrays");
          }
          var byteLen = typedArray.length * (typedArray.BYTES_PER_ELEMENT || 1);
          var bytes = __bb_crypto_random(byteLen) || [];
          var view = new Uint8Array(typedArray.buffer, typedArray.byteOffset || 0, byteLen);
          for (var i = 0; i < byteLen; i++) { view[i] = bytes[i] & 0xff; }
          return typedArray;
        },
        randomUUID: function () { return __bb_crypto_uuid(); },
        subtle: {
          digest: function (algo, data) {
            return new Promise(function (resolve, reject) {
              try {
                var name = digestName(algo);
                var src;
                if (data instanceof ArrayBuffer) { src = new Uint8Array(data); }
                else if (data && data.buffer instanceof ArrayBuffer) {
                  src = new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
                } else if (Array.isArray(data)) { src = data; }
                else { reject(new TypeError('digest expects a BufferSource')); return; }
                var input = [];
                for (var i = 0; i < src.length; i++) { input.push(src[i] & 0xff); }
                var out = __bb_crypto_digest(name, input);
                if (!out) { reject(new Error('Unsupported digest algorithm: ' + name)); return; }
                var result = new Uint8Array(out.length);
                for (var j = 0; j < out.length; j++) { result[j] = out[j] & 0xff; }
                resolve(result.buffer);
              } catch (e) { reject(e); }
            });
          }
        }
      };
    }
    if (typeof globalThis.importScripts !== 'function') {
      globalThis.importScripts = function () {
        for (var i = 0; i < arguments.length; i++) {
          var spec = String(arguments[i]);
          var src = __bb_import_script(spec);
          if (typeof src === 'string') {
            (0, eval)(src);
          } else {
            throw new Error("importScripts failed to load: " + spec);
          }
        }
      };
    }
  })();

  // ---------------------------------------------------------------- service-worker web globals
  // JavaScriptCore is not a browser: it ships no `self`, no base64 (atob/btoa), no TextEncoder/
  // TextDecoder, and no fetch. MV3 service workers and ScriptCat-derived background bundles assume all
  // of them, throwing "Can't find variable: self / TextEncoder", "undefined is not an object
  // (evaluating '…fetch.bind')". We provide pure-JS implementations plus a native-backed fetch
  // (__bb_fetch, host_permissions-gated on the Swift side).
  (function () {
    // `self` is the service-worker global alias.
    if (typeof globalThis.self === 'undefined') { globalThis.self = globalThis; }

    var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    function btoa(str) {
      str = String(str);
      var out = '', i = 0;
      while (i < str.length) {
        var c1 = str.charCodeAt(i++) & 0xff;
        var c2 = i < str.length ? str.charCodeAt(i++) & 0xff : NaN;
        var c3 = i < str.length ? str.charCodeAt(i++) & 0xff : NaN;
        var e1 = c1 >> 2;
        var e2 = ((c1 & 3) << 4) | (c2 >> 4);
        var e3 = isNaN(c2) ? 64 : (((c2 & 15) << 2) | (c3 >> 6));
        var e4 = isNaN(c3) ? 64 : (c3 & 63);
        out += B64.charAt(e1) + B64.charAt(e2) +
               (e3 === 64 ? '=' : B64.charAt(e3)) + (e4 === 64 ? '=' : B64.charAt(e4));
      }
      return out;
    }
    function atob(input) {
      var str = String(input).replace(/[^A-Za-z0-9+/=]/g, '').replace(/=+$/, '');
      var output = '';
      for (var bc = 0, bs = 0, buffer, i = 0; (buffer = str.charAt(i++)); ) {
        buffer = B64.indexOf(buffer);
        if (buffer === -1) { continue; }
        bs = bc % 4 ? bs * 64 + buffer : buffer;
        if (bc++ % 4) { output += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6))); }
      }
      return output;
    }
    if (typeof globalThis.btoa !== 'function') { globalThis.btoa = btoa; }
    if (typeof globalThis.atob !== 'function') { globalThis.atob = atob; }

    function TextEncoder() {}
    TextEncoder.prototype.encoding = 'utf-8';
    TextEncoder.prototype.encode = function (str) {
      str = String(str === undefined ? '' : str);
      var bytes = [];
      for (var i = 0; i < str.length; i++) {
        var code = str.charCodeAt(i);
        if (code < 0x80) { bytes.push(code); }
        else if (code < 0x800) { bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f)); }
        else if (code >= 0xd800 && code <= 0xdbff) {
          var lo = str.charCodeAt(++i);
          var cp = 0x10000 + ((code - 0xd800) << 10) + (lo - 0xdc00);
          bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        } else { bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f)); }
      }
      return new Uint8Array(bytes);
    };
    function TextDecoder(label) { this.encoding = String(label || 'utf-8').toLowerCase(); this.fatal = false; }
    TextDecoder.prototype.decode = function (input) {
      if (!input) { return ''; }
      var bytes;
      if (input instanceof Uint8Array) { bytes = input; }
      else if (input instanceof ArrayBuffer) { bytes = new Uint8Array(input); }
      else if (input.buffer instanceof ArrayBuffer) { bytes = new Uint8Array(input.buffer, input.byteOffset || 0, input.byteLength); }
      else { bytes = new Uint8Array(input); }
      var out = '', i = 0, len = bytes.length;
      while (i < len) {
        var b1 = bytes[i++];
        if (b1 < 0x80) { out += String.fromCharCode(b1); }
        else if (b1 >= 0xc0 && b1 < 0xe0) { out += String.fromCharCode(((b1 & 0x1f) << 6) | (bytes[i++] & 0x3f)); }
        else if (b1 >= 0xe0 && b1 < 0xf0) {
          var c2 = bytes[i++] & 0x3f, c3 = bytes[i++] & 0x3f;
          out += String.fromCharCode(((b1 & 0x0f) << 12) | (c2 << 6) | c3);
        } else {
          var d2 = bytes[i++] & 0x3f, d3 = bytes[i++] & 0x3f, d4 = bytes[i++] & 0x3f;
          var cp = (((b1 & 0x07) << 18) | (d2 << 12) | (d3 << 6) | d4) - 0x10000;
          out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        }
      }
      return out;
    };
    if (typeof globalThis.TextEncoder !== 'function') { globalThis.TextEncoder = TextEncoder; }
    if (typeof globalThis.TextDecoder !== 'function') { globalThis.TextDecoder = TextDecoder; }

    // --- fetch (native-backed via __bb_fetch; host_permissions-gated on the Swift side) ----------
    function Headers(map) {
      this._m = {};
      if (!map) { return; }
      var self = this;
      if (map._m) {   // another Headers shim instance
        for (var hk in map._m) { if (Object.prototype.hasOwnProperty.call(map._m, hk)) { this._m[hk] = map._m[hk]; } }
      } else if (typeof map.forEach === 'function') {   // a Map (or real Headers)
        map.forEach(function (v, k) { self._m[String(k).toLowerCase()] = String(v); });
      } else {   // a plain object
        for (var k in map) { if (Object.prototype.hasOwnProperty.call(map, k)) { this._m[String(k).toLowerCase()] = String(map[k]); } }
      }
    }
    Headers.prototype.get = function (n) { var v = this._m[String(n).toLowerCase()]; return v === undefined ? null : v; };
    Headers.prototype.has = function (n) { return Object.prototype.hasOwnProperty.call(this._m, String(n).toLowerCase()); };
    Headers.prototype.set = function (n, v) { this._m[String(n).toLowerCase()] = String(v); };
    Headers.prototype.append = function (n, v) { var k = String(n).toLowerCase(); this._m[k] = this._m[k] ? this._m[k] + ', ' + v : String(v); };
    Headers.prototype['delete'] = function (n) { delete this._m[String(n).toLowerCase()]; };
    Headers.prototype.forEach = function (cb, thisArg) { for (var k in this._m) { if (Object.prototype.hasOwnProperty.call(this._m, k)) { cb.call(thisArg, this._m[k], k, this); } } };
    Headers.prototype.keys = function () { return Object.keys(this._m); };
    Headers.prototype.entries = function () { var e = []; this.forEach(function (v, k) { e.push([k, v]); }); return e; };

    function bytesFromBase64(b64) {
      var bin = atob(b64 || '');
      var bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i) & 0xff; }
      return bytes;
    }
    function Response(result) {
      result = result || {};
      this.ok = !!result.ok;
      this.status = result.status || 0;
      this.statusText = result.statusText || '';
      this.url = result.url || '';
      this.headers = new Headers(result.headers || {});
      this.redirected = false;
      this.type = 'basic';
      this.bodyUsed = false;
      this._b64 = result.bodyBase64 || '';
    }
    Response.prototype.arrayBuffer = function () { this.bodyUsed = true; return Promise.resolve(bytesFromBase64(this._b64).buffer); };
    Response.prototype.text = function () { this.bodyUsed = true; return Promise.resolve(new TextDecoder('utf-8').decode(bytesFromBase64(this._b64))); };
    Response.prototype.json = function () { return this.text().then(function (t) { return JSON.parse(t); }); };
    Response.prototype.clone = function () {
      return new Response({ ok: this.ok, status: this.status, statusText: this.statusText,
                            url: this.url, headers: this.headers._m, bodyBase64: this._b64 });
    };
    if (typeof globalThis.Headers !== 'function') { globalThis.Headers = Headers; }
    if (typeof globalThis.Response !== 'function') { globalThis.Response = Response; }

    function fetch(input, init) {
      init = init || {};
      var url, method = 'GET', headers = {}, body = null, bodyEncoding = 'utf8';
      if (input && typeof input === 'object' && input.url) { url = String(input.url); method = input.method || method; }
      else { url = String(input); }
      if (init.method) { method = init.method; }
      if (init.headers) {
        if (init.headers._m) { headers = init.headers._m; }                       // our Headers instance
        else if (typeof init.headers.forEach === 'function') {                    // a Map
          init.headers.forEach(function (v, k) { headers[k] = v; });
        } else { headers = init.headers; }                                        // a plain object
      }
      if (init.body != null) {
        if (typeof init.body === 'string') { body = init.body; bodyEncoding = 'utf8'; }
        else if (init.body instanceof ArrayBuffer || (init.body.buffer instanceof ArrayBuffer)) {
          var u8 = init.body instanceof ArrayBuffer ? new Uint8Array(init.body)
                 : new Uint8Array(init.body.buffer, init.body.byteOffset || 0, init.body.byteLength);
          var bin = '';
          for (var i = 0; i < u8.length; i++) { bin += String.fromCharCode(u8[i]); }
          body = btoa(bin); bodyEncoding = 'base64';
        } else {
          try { body = JSON.stringify(init.body); } catch (e) { body = String(init.body); }
          bodyEncoding = 'utf8';
        }
      }
      var reqJSON = JSON.stringify({ url: url, method: method, headers: headers, body: body, bodyEncoding: bodyEncoding });
      return new Promise(function (resolve, reject) {
        if (typeof __bb_fetch !== 'function') { reject(new TypeError('fetch is unavailable')); return; }
        try {
          __bb_fetch(reqJSON, function (resJSON) {
            var r;
            try { r = JSON.parse(resJSON); } catch (e) { reject(new TypeError('Failed to fetch')); return; }
            if (r.error) { reject(new TypeError('Failed to fetch: ' + r.error)); return; }
            resolve(new Response(r));
          });
        } catch (e) { reject(e); }
      });
    }
    if (typeof globalThis.fetch !== 'function') { globalThis.fetch = fetch; }

    // --- ServiceWorkerGlobalScope event surface --------------------------------------------------
    // MV3 service workers register lifecycle handlers via self.addEventListener('install'|'activate').
    // JSC has no addEventListener on the global, so that throws. We provide one and synthetically fire
    // install+activate once, AFTER the background source's top-level code has registered its handlers
    // (deferred via the timer shim, which runs after this synchronous boot completes). Other event
    // types (message/fetch/push/sync) are stored so registration never throws; we don't synthesize
    // those (extensions receive messages via chrome.runtime.onMessage, the authoritative path).
    if (typeof globalThis.addEventListener !== 'function') {
      var swListeners = {};
      globalThis.addEventListener = function (type, listener) {
        if (typeof listener !== 'function') { return; }
        (swListeners[type] = swListeners[type] || []).push(listener);
      };
      globalThis.removeEventListener = function (type, listener) {
        var arr = swListeners[type];
        if (!arr) { return; }
        var idx = arr.indexOf(listener);
        if (idx >= 0) { arr.splice(idx, 1); }
      };
      globalThis.dispatchEvent = function (event) {
        var arr = swListeners[event && event.type];
        if (!arr) { return true; }
        arr.slice().forEach(function (l) {
          try { l(event); } catch (e) {
            __bb_log('error', 'event listener (' + (event && event.type) + ') threw: ' + (e && e.message ? e.message : e));
          }
        });
        return !(event && event.defaultPrevented);
      };
      var fireLifecycle = function () {
        ['install', 'activate'].forEach(function (type) {
          globalThis.dispatchEvent({ type: type, waitUntil: function () {}, preventDefault: function () {} });
        });
      };
      // Runs after the synchronous boot (runtime + background source) completes.
      setTimeout(fireLifecycle, 0);
    }
    if (typeof globalThis.skipWaiting !== 'function') { globalThis.skipWaiting = function () { return Promise.resolve(); }; }

    // Minimal Clients / ServiceWorkerRegistration so the universal `self.clients.claim()` /
    // `self.registration` in SW activate handlers don't throw. There is one headless context per
    // extension and no controllable window clients on iOS, so matchAll resolves empty.
    if (typeof globalThis.clients === 'undefined') {
      globalThis.clients = {
        claim: function () { return Promise.resolve(); },
        matchAll: function () { return Promise.resolve([]); },
        get: function () { return Promise.resolve(undefined); },
        openWindow: function () { return Promise.resolve(null); }
      };
    }
    if (typeof globalThis.registration === 'undefined') {
      globalThis.registration = {
        scope: baseURL,
        active: null, installing: null, waiting: null,
        unregister: function () { return Promise.resolve(true); },
        update: function () { return Promise.resolve(); },
        showNotification: function () { return Promise.resolve(); },
        getNotifications: function () { return Promise.resolve([]); }
      };
    }

    // --- URL / URLSearchParams / location / performance ------------------------------------------
    // JavaScriptCore ships none of these web globals; extensions throw "Can't find variable: URL /
    // location / performance". Pure-JS implementations (no DOM needed).
    if (typeof globalThis.URLSearchParams !== 'function') {
      var USP = function (init) {
        this._list = [];
        if (typeof init === 'string') {
          var q = init.charAt(0) === '?' ? init.slice(1) : init;
          if (q) {
            var pairs = q.split('&');
            for (var i = 0; i < pairs.length; i++) {
              if (!pairs[i]) { continue; }
              var eq = pairs[i].indexOf('=');
              var k = eq < 0 ? pairs[i] : pairs[i].slice(0, eq);
              var v = eq < 0 ? '' : pairs[i].slice(eq + 1);
              this._list.push([decodeURIComponent(k.replace(/\+/g, ' ')), decodeURIComponent(v.replace(/\+/g, ' '))]);
            }
          }
        } else if (init && typeof init === 'object') {
          if (Array.isArray(init)) {
            for (var j = 0; j < init.length; j++) { this._list.push([String(init[j][0]), String(init[j][1])]); }
          } else {
            for (var key in init) { if (Object.prototype.hasOwnProperty.call(init, key)) { this._list.push([key, String(init[key])]); } }
          }
        }
      };
      USP.prototype.append = function (k, v) { this._list.push([String(k), String(v)]); };
      USP.prototype['delete'] = function (k) { k = String(k); this._list = this._list.filter(function (p) { return p[0] !== k; }); };
      USP.prototype.get = function (k) { k = String(k); for (var i = 0; i < this._list.length; i++) { if (this._list[i][0] === k) { return this._list[i][1]; } } return null; };
      USP.prototype.getAll = function (k) { k = String(k); return this._list.filter(function (p) { return p[0] === k; }).map(function (p) { return p[1]; }); };
      USP.prototype.has = function (k) { return this.get(k) !== null; };
      USP.prototype.set = function (k, v) {
        k = String(k); v = String(v);
        var done = false, out = [];
        for (var i = 0; i < this._list.length; i++) {
          if (this._list[i][0] === k) { if (!done) { out.push([k, v]); done = true; } } else { out.push(this._list[i]); }
        }
        if (!done) { out.push([k, v]); }
        this._list = out;
      };
      USP.prototype.sort = function () { this._list.sort(function (a, b) { return a[0] < b[0] ? -1 : (a[0] > b[0] ? 1 : 0); }); };
      USP.prototype.forEach = function (cb, thisArg) { for (var i = 0; i < this._list.length; i++) { cb.call(thisArg, this._list[i][1], this._list[i][0], this); } };
      USP.prototype.keys = function () { return this._list.map(function (p) { return p[0]; }); };
      USP.prototype.values = function () { return this._list.map(function (p) { return p[1]; }); };
      USP.prototype.entries = function () { return this._list.map(function (p) { return p.slice(); }); };
      USP.prototype.toString = function () {
        return this._list.map(function (p) { return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]); }).join('&');
      };
      globalThis.URLSearchParams = USP;
    }

    if (typeof globalThis.URL !== 'function') {
      var resolveURL = function (input, base) {
        if (/^[a-zA-Z][a-zA-Z0-9+.\-]*:/.test(input)) { return input; }       // already absolute
        var bm = /^([a-zA-Z][a-zA-Z0-9+.\-]*:)(\/\/[^/?#]*)?([^?#]*)/.exec(base) || [];
        var scheme = bm[1] || '', authority = bm[2] || '', basePath = bm[3] || '';
        if (input.indexOf('//') === 0) { return scheme + input; }
        if (input.charAt(0) === '/') { return scheme + authority + input; }
        if (input.charAt(0) === '?' || input.charAt(0) === '#') { return scheme + authority + basePath + input; }
        var dir = basePath.slice(0, basePath.lastIndexOf('/') + 1) || '/';
        var segments = (dir + input).split('/');
        var resolved = [];
        for (var i = 0; i < segments.length; i++) {
          if (segments[i] === '..') { resolved.pop(); }
          else if (segments[i] !== '.') { resolved.push(segments[i]); }
        }
        return scheme + authority + resolved.join('/');
      };
      var URLImpl = function (url, base) {
        var input = String(url);
        if (base !== undefined && base !== null) { input = resolveURL(input, String(base)); }
        var m = /^([a-zA-Z][a-zA-Z0-9+.\-]*:)(\/\/(([^/?#@]*)@)?([^/?#:]*)(:(\d+))?)?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(input);
        if (!m || !m[1]) { throw new TypeError('Invalid URL: ' + url); }
        this.protocol = m[1];
        this.hostname = m[5] || '';
        this.port = m[7] || '';
        this.host = this.hostname + (this.port ? ':' + this.port : '');
        this.pathname = m[8] || (this.host ? '/' : '');
        this.hash = m[10] || '';
        var hier = ['http:', 'https:', 'ws:', 'wss:', 'ftp:'].indexOf(this.protocol) >= 0;
        this.origin = (hier && this.host) ? (this.protocol + '//' + this.host) : 'null';
        this._search = m[9] || '';
        this.searchParams = new globalThis.URLSearchParams(this._search);
      };
      Object.defineProperty(URLImpl.prototype, 'search', {
        get: function () {
          var s = this.searchParams.toString();
          return s ? '?' + s : '';
        },
        set: function (v) {
          this._search = v;
          this.searchParams = new globalThis.URLSearchParams(v);
        }
      });
      Object.defineProperty(URLImpl.prototype, 'href', {
        get: function () {
          var auth = this.host ? '//' + this.host : (this.protocol.indexOf('file') === 0 ? '//' : '');
          return this.protocol + auth + this.pathname + this.search + this.hash;
        },
        set: function (v) { URLImpl.call(this, v); }
      });
      URLImpl.prototype.toString = function () { return this.href; };
      URLImpl.prototype.toJSON = function () { return this.href; };
      globalThis.URL = URLImpl;
    }

    // The service worker's own location (its script's URL). Extensions read location.origin/href.
    if (typeof globalThis.location === 'undefined') {
      try { globalThis.location = new globalThis.URL(baseURL || 'chrome-extension://invalid/'); } catch (e) { /* leave undefined */ }
    }

    // performance.now() — high-res-ish via Date (JSC has Date). timeOrigin anchors at boot.
    if (typeof globalThis.performance === 'undefined') {
      var _timeOrigin = Date.now();
      globalThis.performance = {
        timeOrigin: _timeOrigin,
        now: function () { return Date.now() - _timeOrigin; },
        mark: function () {}, measure: function () {},
        clearMarks: function () {}, clearMeasures: function () {},
        getEntries: function () { return []; },
        getEntriesByName: function () { return []; },
        getEntriesByType: function () { return []; }
      };
    }
  })();

  function makeEvent(list) {
    return {
      addListener: function (fn) { if (typeof fn === 'function' && list.indexOf(fn) < 0) { list.push(fn); } },
      removeListener: function (fn) { var i = list.indexOf(fn); if (i >= 0) { list.splice(i, 1); } },
      hasListener: function (fn) { return list.indexOf(fn) >= 0; },
      hasListeners: function () { return list.length > 0; }
    };
  }

  // ---------------------------------------------------------------- chrome.storage

  function storageArea(areaName) {
    return {
      get: function (keys, cb) {
        var defaults = null;
        var keyList = null;
        if (typeof keys === 'function') { cb = keys; keyList = null; }
        else if (keys === null || keys === undefined) { keyList = null; }
        else if (typeof keys === 'string') { keyList = [keys]; }
        else if (Array.isArray(keys)) { keyList = keys.slice(); }
        else if (typeof keys === 'object') { defaults = keys; keyList = Object.keys(keys); }
        __bb_storage_get(areaName, keyList === null ? 'null' : JSON.stringify(keyList), function (resJSON) {
          var raw = parseJSON(resJSON) || {};      // key -> JSON-encoded value
          var out = {};
          if (defaults) { for (var dk in defaults) { if (Object.prototype.hasOwnProperty.call(defaults, dk)) { out[dk] = deepClone(defaults[dk]); } } }
          for (var k in raw) { if (Object.prototype.hasOwnProperty.call(raw, k)) { out[k] = parseJSON(raw[k]); } }
          if (typeof cb === 'function') { cb(out); }
        });
      },
      set: function (items, cb) {
        var enc = {};
        for (var k in items) { if (Object.prototype.hasOwnProperty.call(items, k)) { enc[k] = JSON.stringify(items[k]); } }
        __bb_storage_set(areaName, JSON.stringify(enc), function () { if (typeof cb === 'function') { cb(); } });
      },
      remove: function (keys, cb) {
        var list = Array.isArray(keys) ? keys : [keys];
        __bb_storage_remove(areaName, JSON.stringify(list), function () { if (typeof cb === 'function') { cb(); } });
      },
      clear: function (cb) {
        __bb_storage_clear(areaName, function () { if (typeof cb === 'function') { cb(); } });
      },
      // chrome.storage.session.setAccessLevel: controls content-script visibility of session storage.
      // BrownBear doesn't expose a separate untrusted tier, so this is a no-op that resolves — its
      // absence threw "setAccessLevel is not a function" for extensions that call it on boot.
      setAccessLevel: function (_opts, cb) {
        if (typeof cb === 'function') { cb(); return undefined; }
        return Promise.resolve();
      }
    };
  }

  var storageChangedListeners = [];
  var storage = {
    local: storageArea('local'),
    sync: storageArea('sync'),
    session: storageArea('session'),
    managed: storageArea('managed'),
    onChanged: makeEvent(storageChangedListeners)
  };

  // ---------------------------------------------------------------- chrome.alarms

  var alarmListeners = [];
  var alarms = {
    create: function (name, info) {
      if (typeof name === 'object' && name !== null) { info = name; name = ''; }
      info = info || {};
      var when = 0;
      var period = 0;
      if (typeof info.when === 'number') { when = info.when; }
      else if (typeof info.delayInMinutes === 'number') { when = Date.now() + info.delayInMinutes * 60000; }
      if (typeof info.periodInMinutes === 'number') { period = info.periodInMinutes; }
      __bb_alarm_create(String(name || ''), when, period);
    },
    clear: function (name, cb) {
      __bb_alarm_clear(String(name || ''), function (res) { if (typeof cb === 'function') { cb(parseJSON(res) === true); } });
    },
    clearAll: function (cb) {
      __bb_alarm_clear_all(function (res) { if (typeof cb === 'function') { cb(parseJSON(res) === true); } });
    },
    get: function (name, cb) {
      __bb_alarm_get(String(name || ''), function (res) { if (typeof cb === 'function') { cb(parseJSON(res) || undefined); } });
    },
    getAll: function (cb) {
      __bb_alarm_get_all(function (res) { if (typeof cb === 'function') { cb(parseJSON(res) || []); } });
    },
    onAlarm: makeEvent(alarmListeners)
  };

  // ---------------------------------------------------------------- chrome.i18n

  function getMessage(key, substitutions) {
    var message = messages[key];
    if (message === null || message === undefined) { return ''; }
    if (substitutions !== null && substitutions !== undefined) {
      var subs = Array.isArray(substitutions) ? substitutions : [substitutions];
      message = message.replace(/\$(\d+)/g, function (_, digits) {
        var index = parseInt(digits, 10) - 1;
        return (index >= 0 && index < subs.length) ? subs[index] : '';
      });
    }
    return message;
  }

  // ---------------------------------------------------------------- chrome.runtime

  var messageListeners = [];
  var installedListeners = [];
  var startupListeners = [];

  function getURL(path) {
    path = path || '';
    return baseURL + (path.charAt(0) === '/' ? path.slice(1) : path);
  }

  var runtime = {
    id: extId,
    // Chrome exposes these enums on chrome.runtime; extensions read them directly (e.g. an onInstalled
    // listener comparing details.reason === chrome.runtime.OnInstalledReason.INSTALL). Missing them
    // throws "undefined is not an object (evaluating 'chrome.runtime.OnInstalledReason.INSTALL')".
    OnInstalledReason: { INSTALL: 'install', UPDATE: 'update', CHROME_UPDATE: 'chrome_update', SHARED_MODULE_UPDATE: 'shared_module_update' },
    OnRestartRequiredReason: { APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic' },
    PlatformOs: { MAC: 'mac', WIN: 'win', ANDROID: 'android', CROS: 'cros', LINUX: 'linux', OPENBSD: 'openbsd', FUCHSIA: 'fuchsia' },
    PlatformArch: { ARM: 'arm', ARM64: 'arm64', X86_32: 'x86-32', X86_64: 'x86-64', MIPS: 'mips', MIPS64: 'mips64' },
    PlatformNaclArch: { ARM: 'arm', X86_32: 'x86-32', X86_64: 'x86-64', MIPS: 'mips', MIPS64: 'mips64' },
    RequestUpdateCheckStatus: { THROTTLED: 'throttled', NO_UPDATE: 'no_update', UPDATE_AVAILABLE: 'update_available' },
    ContextType: { TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', SIDE_PANEL: 'SIDE_PANEL' },
    getManifest: function () { return deepClone(manifest); },
    getURL: getURL,
    onMessage: makeEvent(messageListeners),
    onInstalled: makeEvent(installedListeners),
    onStartup: makeEvent(startupListeners),
    onConnect: makeEvent([]),
    onSuspend: makeEvent([]),
    sendMessage: function () {
      // Accept (extensionId?, message, options?, callback?) — Chrome's overloaded shape.
      var args = Array.prototype.slice.call(arguments);
      var cb = (args.length && typeof args[args.length - 1] === 'function') ? args.pop() : null;
      var message = (typeof args[0] === 'string' && args.length > 1) ? args[1] : args[0];
      __bb_send_message(JSON.stringify({ message: (message === undefined ? null : message) }), function (resJSON) {
        var r = parseJSON(resJSON);
        if (typeof cb === 'function') { cb(r ? r.value : undefined); }
      });
    },
    connect: function () { throw new Error('chrome.runtime.connect (long-lived ports) is not yet supported in BrownBear'); },
    openOptionsPage: function (cb) {
      __bb_runtime_open_options(function () { if (typeof cb === 'function') { cb(); } });
    },
    setUninstallURL: function (url, cb) {
      __bb_runtime_set_uninstall_url(String(url || ''), function () { if (typeof cb === 'function') { cb(); } });
    },
    getPlatformInfo: function (cb) {
      var info = { os: 'ios', arch: 'arm64', nacl_arch: 'arm64' };
      if (typeof cb === 'function') { cb(info); return undefined; }
      return Promise.resolve(info);
    },
    get lastError() { return undefined; }
  };

  // ---------------------------------------------------------------- assemble + expose

  // chrome.commands has no keyboard source on iOS — stubbed so a worker that touches it doesn't throw.
  var commands = {
    onCommand: makeEvent([]),
    getAll: function (cb) { if (typeof cb === 'function') { cb([]); } }
  };

  // ---------------------------------------------------------------- chrome.action / chrome.browserAction
  // Backed by native WebExtensionActionState via __bb_action; onClicked is delivered from the browser
  // (overflow-menu tap on an action with no popup) through __bbBg.dispatchActionClicked. setIcon
  // forwards only serializable path data (ImageData isn't bridgeable from JavaScriptCore).
  var actionClickedListeners = [];
  function actionCall(method, args) {
    return new Promise(function (resolve) {
      __bb_action(method, JSON.stringify(args || {}), function (resJSON) { resolve(parseJSON(resJSON)); });
    });
  }
  function actionSetter(method) {
    return function (details, cb) {
      details = details || {};
      var payload = {};
      for (var k in details) { if (Object.prototype.hasOwnProperty.call(details, k)) { payload[k] = details[k]; } }
      return settleBg(actionCall(method, payload).then(function () { return undefined; }), cb);
    };
  }
  function actionGetter(method) {
    return function (details, cb) {
      if (typeof details === 'function') { cb = details; details = {}; }
      return settleBg(actionCall(method, details || {}), cb);
    };
  }
  function actionToggle(method) {
    return function (tabId, cb) {
      if (typeof tabId === 'function') { cb = tabId; tabId = undefined; }
      return settleBg(actionCall(method, { tabId: tabId }).then(function () { return undefined; }), cb);
    };
  }
  function actionSetIcon(details, cb) {
    details = details || {};
    var payload = { tabId: details.tabId };
    if (typeof details.path === 'string') { payload.path = details.path; }
    else if (details.path && typeof details.path === 'object') {
      var map = {}; for (var k in details.path) { if (typeof details.path[k] === 'string') { map[k] = details.path[k]; } }
      payload.path = map;
    }
    return settleBg(actionCall('setIcon', payload).then(function () { return undefined; }), cb);
  }
  var action = {
    setBadgeText: actionSetter('setBadgeText'),
    setBadgeBackgroundColor: actionSetter('setBadgeBackgroundColor'),
    setTitle: actionSetter('setTitle'),
    setPopup: actionSetter('setPopup'),
    setIcon: actionSetIcon,
    enable: actionToggle('enable'),
    disable: actionToggle('disable'),
    getBadgeText: actionGetter('getBadgeText'),
    getTitle: actionGetter('getTitle'),
    getBadgeBackgroundColor: actionGetter('getBadgeBackgroundColor'),
    onClicked: makeEvent(actionClickedListeners)
  };

  // ---------------------------------------------------------------- chrome.tabs

  function settleBg(promise, cb) {
    if (typeof cb === 'function') { promise.then(function (v) { cb(v); }, function () { cb(undefined); }); return undefined; }
    return promise;
  }
  function tabsCall(method, args) {
    return new Promise(function (resolve) {
      __bb_tabs(method, JSON.stringify(args || {}), function (resJSON) { resolve(parseJSON(resJSON)); });
    });
  }
  // Named, reachable listener lists so __bbBg.dispatchExtEvent can route a browser-pushed event to
  // the right chrome.tabs.* / chrome.webNavigation.* listeners.
  var tabEventLists = {
    'tabs.onCreated': [], 'tabs.onUpdated': [], 'tabs.onActivated': [], 'tabs.onRemoved': []
  };
  var webNavLists = {
    'webNavigation.onBeforeNavigate': [], 'webNavigation.onCommitted': [],
    'webNavigation.onDOMContentLoaded': [], 'webNavigation.onCompleted': [],
    'webNavigation.onHistoryStateUpdated': [], 'webNavigation.onErrorOccurred': []
  };
  var tabs = {
    query: function (q, cb) { return settleBg(tabsCall('query', { query: q || {} }), cb); },
    get: function (id, cb) { return settleBg(tabsCall('get', { tabId: id }), cb); },
    getCurrent: function (cb) { return settleBg(tabsCall('getCurrent', {}), cb); },
    create: function (props, cb) { props = props || {}; return settleBg(tabsCall('create', { url: props.url, active: props.active !== false }), cb); },
    update: function (id, props, cb) {
      if (id !== null && typeof id === 'object') { cb = props; props = id; id = undefined; }
      props = props || {};
      return settleBg(tabsCall('update', { tabId: id, url: props.url, active: props.active }), cb);
    },
    remove: function (ids, cb) {
      var list = Array.isArray(ids) ? ids : [ids];
      return settleBg(tabsCall('remove', { tabIds: list }).then(function () { return undefined; }), cb);
    },
    reload: function (id, props, cb) {
      if (typeof id === 'function') { cb = id; id = undefined; props = {}; }
      else if (id !== null && typeof id === 'object') { cb = props; props = id; id = undefined; }
      props = props || {};
      return settleBg(tabsCall('reload', { tabId: id, bypassCache: !!props.bypassCache }).then(function () { return undefined; }), cb);
    },
    sendMessage: function () {
      // chrome.tabs.sendMessage(tabId, message, options?, callback?) — worker → a tab's content
      // scripts, via native, resolving with the first content listener's response.
      var a = Array.prototype.slice.call(arguments);
      var cb = (a.length && typeof a[a.length - 1] === 'function') ? a.pop() : null;
      var tabId = a[0];
      var message = a[1];
      return settleBg(new Promise(function (resolve) {
        __bb_tabs_send_message(JSON.stringify({ tabId: tabId, message: (message === undefined ? null : message) }), function (resJSON) {
          var r = parseJSON(resJSON);
          resolve(r ? r.value : undefined);
        });
      }), cb);
    },
    executeScript: function (id, details, cb) {
      if (id !== null && typeof id === 'object') { cb = details; details = id; id = undefined; }
      details = details || {};
      return settleBg(scriptingCall('executeScript', { tabId: id, code: details.code, files: details.file ? [details.file] : undefined, world: details.world }), cb);
    },
    insertCSS: function (id, details, cb) {
      if (id !== null && typeof id === 'object') { cb = details; details = id; id = undefined; }
      details = details || {};
      return settleBg(scriptingCall('insertCSS', { tabId: id, css: details.code, files: details.file ? [details.file] : undefined }).then(function () { return undefined; }), cb);
    },
    onCreated: makeEvent(tabEventLists['tabs.onCreated']),
    onUpdated: makeEvent(tabEventLists['tabs.onUpdated']),
    onActivated: makeEvent(tabEventLists['tabs.onActivated']),
    onRemoved: makeEvent(tabEventLists['tabs.onRemoved']),
    onReplaced: makeEvent([])
  };

  // ---------------------------------------------------------------- chrome.webNavigation
  var webNavigation = {
    onBeforeNavigate: makeEvent(webNavLists['webNavigation.onBeforeNavigate']),
    onCommitted: makeEvent(webNavLists['webNavigation.onCommitted']),
    onDOMContentLoaded: makeEvent(webNavLists['webNavigation.onDOMContentLoaded']),
    onCompleted: makeEvent(webNavLists['webNavigation.onCompleted']),
    onHistoryStateUpdated: makeEvent(webNavLists['webNavigation.onHistoryStateUpdated']),
    onErrorOccurred: makeEvent(webNavLists['webNavigation.onErrorOccurred']),
    getFrame: function (details, cb) { if (typeof cb === 'function') { cb(null); } return Promise.resolve(null); },
    getAllFrames: function (details, cb) { if (typeof cb === 'function') { cb([]); } return Promise.resolve([]); }
  };

  // ---------------------------------------------------------------- chrome.scripting
  function scriptingCall(method, args) {
    return new Promise(function (resolve) {
      __bb_scripting(method, JSON.stringify(args || {}), function (resJSON) { resolve(parseJSON(resJSON)); });
    });
  }
  function serializeInjection(injection) {
    var payload = { target: injection.target || {}, world: injection.world || 'ISOLATED' };
    if (injection.files) { payload.files = injection.files; }
    else if (typeof injection.func === 'function') {
      payload.code = '(' + injection.func.toString() + ').apply(null, ' + JSON.stringify(injection.args || []) + ')';
    } else if (typeof injection.code === 'string') { payload.code = injection.code; }
    return payload;
  }
  function cssInjection(injection) {
    var payload = { target: injection.target || {} };
    if (injection.files) { payload.files = injection.files; } else { payload.css = injection.css || ''; }
    return payload;
  }
  var scripting = {
    executeScript: function (injection, cb) { return settleBg(scriptingCall('executeScript', serializeInjection(injection)), cb); },
    insertCSS: function (injection, cb) { return settleBg(scriptingCall('insertCSS', cssInjection(injection)).then(function () { return undefined; }), cb); },
    removeCSS: function (injection, cb) { return settleBg(scriptingCall('removeCSS', cssInjection(injection)).then(function () { return undefined; }), cb); }
  };

  // ---------------------------------------------------------------- chrome.windows

  function windowsCall(method, args) {
    return new Promise(function (resolve) {
      __bb_windows(method, JSON.stringify(args || {}), function (resJSON) { resolve(parseJSON(resJSON)); });
    });
  }
  var windows = {
    WINDOW_ID_NONE: -1,
    WINDOW_ID_CURRENT: -2,
    get: function (id, getInfo, cb) {
      if (typeof id === 'object' && id !== null) { cb = getInfo; getInfo = id; }
      else if (typeof id === 'function') { cb = id; getInfo = null; }
      return settleBg(windowsCall('get', { populate: !!(getInfo && getInfo.populate) }), cb);
    },
    getCurrent: function (getInfo, cb) {
      if (typeof getInfo === 'function') { cb = getInfo; getInfo = null; }
      return settleBg(windowsCall('getCurrent', { populate: !!(getInfo && getInfo.populate) }), cb);
    },
    getLastFocused: function (getInfo, cb) {
      if (typeof getInfo === 'function') { cb = getInfo; getInfo = null; }
      return settleBg(windowsCall('getLastFocused', { populate: !!(getInfo && getInfo.populate) }), cb);
    },
    getAll: function (getInfo, cb) {
      if (typeof getInfo === 'function') { cb = getInfo; getInfo = null; }
      return settleBg(windowsCall('getAll', { populate: !!(getInfo && getInfo.populate) }), cb);
    },
    create: function (createData, cb) {
      createData = createData || {};
      var url = createData.url;
      if (Array.isArray(url)) { url = url[0]; }
      return settleBg(windowsCall('create', { url: url, focused: createData.focused !== false, populate: false }), cb);
    },
    update: function (id, updateInfo, cb) { return settleBg(windowsCall('update', { populate: false }), cb); },
    remove: function (id, cb) { return settleBg(windowsCall('remove', {}).then(function () { return undefined; }), cb); },
    onCreated: makeEvent([]), onRemoved: makeEvent([]), onFocusChanged: makeEvent([]), onBoundsChanged: makeEvent([])
  };

  // ---------------------------------------------------------------- chrome.management

  function managementCall(method, args) {
    return new Promise(function (resolve) {
      __bb_management(method, JSON.stringify(args || {}), function (resJSON) { resolve(parseJSON(resJSON)); });
    });
  }
  var management = {
    getSelf: function (cb) { return settleBg(managementCall('getSelf', {}), cb); },
    get: function (id, cb) { return settleBg(managementCall('get', { id: id }), cb); },
    getAll: function (cb) { return settleBg(managementCall('getAll', {}), cb); },
    onInstalled: makeEvent([]), onUninstalled: makeEvent([]), onEnabled: makeEvent([]), onDisabled: makeEvent([])
  };

  // ---------------------------------------------------------------- chrome.permissions

  function permissionsCall(method, args) {
    return new Promise(function (resolve) {
      __bb_permissions(method, JSON.stringify(args || {}), function (resJSON) { resolve(parseJSON(resJSON)); });
    });
  }
  function permObj(p) { p = p || {}; return { permissions: p.permissions || [], origins: p.origins || [] }; }
  var permissions = {
    getAll: function (cb) { return settleBg(permissionsCall('getAll', {}), cb); },
    contains: function (p, cb) { return settleBg(permissionsCall('contains', permObj(p)), cb); },
    request: function (p, cb) { return settleBg(permissionsCall('request', permObj(p)), cb); },
    remove: function (p, cb) { return settleBg(permissionsCall('remove', permObj(p)), cb); },
    onAdded: makeEvent([]), onRemoved: makeEvent([])
  };

  // ---------------------------------------------------------------- chrome.declarativeNetRequest
  // Backed by __bb_dnr(method, argsJSON, cb). A native { error } result rejects the promise.
  function dnrCall(method, args) {
    return new Promise(function (resolve, reject) {
      __bb_dnr(method, JSON.stringify(args || {}), function (resJSON) {
        var r = parseJSON(resJSON);
        if (r && typeof r === 'object' && typeof r.error === 'string') { reject(new Error(r.error)); }
        else { resolve(r); }
      });
    });
  }
  var declarativeNetRequest = {
    updateDynamicRules: function (options, cb) { return settleBg(dnrCall('updateDynamicRules', options || {}).then(function () { return undefined; }), cb); },
    getDynamicRules: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(dnrCall('getDynamicRules', { ruleIds: (filter && filter.ruleIds) || null }), cb);
    },
    updateSessionRules: function (options, cb) { return settleBg(dnrCall('updateSessionRules', options || {}).then(function () { return undefined; }), cb); },
    getSessionRules: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(dnrCall('getSessionRules', { ruleIds: (filter && filter.ruleIds) || null }), cb);
    },
    updateEnabledRulesets: function (options, cb) { return settleBg(dnrCall('updateEnabledRulesets', options || {}).then(function () { return undefined; }), cb); },
    getEnabledRulesets: function (cb) { return settleBg(dnrCall('getEnabledRulesets', {}), cb); },
    getMatchedRules: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(Promise.resolve({ rulesMatchedInfo: [] }), cb);
    },
    setExtensionActionOptions: function (options, cb) { return settleBg(Promise.resolve(undefined), cb); },
    isRegexSupported: function (regexOptions, cb) { return settleBg(Promise.resolve({ isSupported: true }), cb); },
    onRuleMatchedDebug: makeEvent([]),
    MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000,
    MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
    DYNAMIC_RULESET_ID: '_dynamic',
    SESSION_RULESET_ID: '_session'
  };

  // ---------------------------------------------------------------- chrome.userScripts
  function userScriptsCall(method, args) {
    return new Promise(function (resolve, reject) {
      __bb_userscripts(method, JSON.stringify(args || {}), function (resJSON) {
        var r = parseJSON(resJSON);
        if (r && typeof r === 'object' && typeof r.error === 'string') { reject(new Error(r.error)); }
        else { resolve(r); }
      });
    });
  }
  var userScripts = {
    register: function (scripts, cb) { return settleBg(userScriptsCall('register', { scripts: scripts || [] }).then(function () { return undefined; }), cb); },
    update: function (scripts, cb) { return settleBg(userScriptsCall('update', { scripts: scripts || [] }).then(function () { return undefined; }), cb); },
    unregister: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(userScriptsCall('unregister', { filter: filter || null }).then(function () { return undefined; }), cb);
    },
    getScripts: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(userScriptsCall('getScripts', { filter: filter || null }), cb);
    },
    configureWorld: function (properties, cb) { return settleBg(userScriptsCall('configureWorld', { properties: properties || {} }).then(function () { return undefined; }), cb); }
  };

  // ---------------------------------------------------------------- chrome.cookies

  function cookiesCall(method, args) {
    return new Promise(function (resolve) {
      __bb_cookies(method, JSON.stringify(args || {}), function (resJSON) { resolve(parseJSON(resJSON)); });
    });
  }
  var cookieChangedListeners = [];
  var cookies = {
    get: function (details, cb) { return settleBg(cookiesCall('get', { details: details || {} }), cb); },
    getAll: function (details, cb) {
      if (typeof details === 'function') { cb = details; details = {}; }
      return settleBg(cookiesCall('getAll', { details: details || {} }), cb);
    },
    set: function (details, cb) { return settleBg(cookiesCall('set', { details: details || {} }), cb); },
    remove: function (details, cb) { return settleBg(cookiesCall('remove', { details: details || {} }), cb); },
    getAllCookieStores: function (cb) { return settleBg(cookiesCall('getAllCookieStores', {}), cb); },
    onChanged: makeEvent(cookieChangedListeners)
  };

  // ---------------------------------------------------------------- chrome.notifications

  var notificationClickedListeners = [];
  var notificationClosedListeners = [];
  var notificationButtonListeners = [];
  function notificationsCall(method, args) {
    return new Promise(function (resolve) {
      __bb_notifications(method, JSON.stringify(args || {}), function (resJSON) { resolve(parseJSON(resJSON)); });
    });
  }
  var notifications = {
    create: function (notificationId, options, cb) {
      if (notificationId !== null && typeof notificationId === 'object') { cb = options; options = notificationId; notificationId = undefined; }
      if (typeof options === 'function') { cb = options; options = {}; }
      options = options || {};
      return settleBg(notificationsCall('create', { notificationId: notificationId || null, options: options }), cb);
    },
    update: function (notificationId, options, cb) {
      if (typeof options === 'function') { cb = options; options = {}; }
      options = options || {};
      return settleBg(notificationsCall('update', { notificationId: notificationId, options: options }), cb);
    },
    clear: function (notificationId, cb) { return settleBg(notificationsCall('clear', { notificationId: notificationId }), cb); },
    getAll: function (cb) { return settleBg(notificationsCall('getAll', {}), cb); },
    getPermissionLevel: function (cb) { var level = 'granted'; if (typeof cb === 'function') { cb(level); return undefined; } return Promise.resolve(level); },
    onClicked: makeEvent(notificationClickedListeners),
    onClosed: makeEvent(notificationClosedListeners),
    onButtonClicked: makeEvent(notificationButtonListeners),
    onShowSettings: makeEvent([]),
    onPermissionLevelChanged: makeEvent([])
  };

  // ---------------------------------------------------------------- chrome.contextMenus
  // Backed by native __bb_context_menus(method, argsJSON, cb). create resolves { id }; a native
  // { error } result rejects the promise. onClicked is LIVE here — the browser delivers a long-press
  // tap via __bbBg.dispatchContextMenuClicked.
  var contextMenuClickedListeners = [];
  function contextMenusCall(method, args) {
    return new Promise(function (resolve, reject) {
      __bb_context_menus(method, JSON.stringify(args || {}), function (resJSON) {
        var r = parseJSON(resJSON);
        if (r && typeof r === 'object' && typeof r.error === 'string') { reject(new Error(r.error)); }
        else { resolve(r); }
      });
    });
  }
  var contextMenus = {
    create: function (createProperties, cb) {
      createProperties = createProperties || {};
      // Chrome: create() RETURNS the id synchronously (and accepts an optional callback). We can't
      // know a minted id synchronously across the bridge, so echo back the supplied id (the common
      // case) and resolve the real id via the callback.
      contextMenusCall('create', { properties: createProperties }).then(function () {
        if (typeof cb === 'function') { cb(); }
      }, function () { if (typeof cb === 'function') { cb(); } });
      return (createProperties.id !== undefined && createProperties.id !== null) ? createProperties.id : undefined;
    },
    update: function (id, updateProperties, cb) {
      return settleBg(contextMenusCall('update', { id: id, properties: updateProperties || {} }).then(function () { return undefined; }), cb);
    },
    remove: function (menuItemId, cb) {
      return settleBg(contextMenusCall('remove', { id: menuItemId }).then(function () { return undefined; }), cb);
    },
    removeAll: function (cb) {
      return settleBg(contextMenusCall('removeAll', {}).then(function () { return undefined; }), cb);
    },
    onClicked: makeEvent(contextMenuClickedListeners),
    ACTION_MENU_TOP_LEVEL_LIMIT: 6
  };

  var chrome = {
    runtime: runtime,
    storage: storage,
    cookies: cookies,
    notifications: notifications,
    windows: windows,
    management: management,
    permissions: permissions,
    declarativeNetRequest: declarativeNetRequest,
    userScripts: userScripts,
    webNavigation: webNavigation,
    alarms: alarms,
    commands: commands,
    contextMenus: contextMenus,
    menus: contextMenus,
    action: action,
    browserAction: action,
    tabs: tabs,
    scripting: scripting,
    i18n: { getMessage: getMessage, getUILanguage: function () { return 'en-US'; }, getAcceptLanguages: function (cb) { if (typeof cb === 'function') { cb(['en-US', 'en']); } } },
    extension: { getURL: getURL }
  };

  globalThis.chrome = chrome;
  globalThis.browser = chrome;

  // Native → JS dispatch surface. The Swift side invokes these on the context's own queue.
  globalThis.__bbBg = {
    dispatchMessage: function (messageJSON, senderJSON, responseId) {
      var message = parseJSON(messageJSON);
      var sender = parseJSON(senderJSON) || {};
      var responded = false;
      var willRespondAsync = false;

      function sendResponse(value) {
        if (responded) { return; }
        responded = true;
        __bb_message_response(responseId, JSON.stringify({ value: (value === undefined ? null : value) }));
      }

      for (var i = 0; i < messageListeners.length; i++) {
        var returned;
        try {
          returned = messageListeners[i](message, sender, sendResponse);
        } catch (e) {
          __bb_log('error', 'runtime.onMessage listener threw: ' + (e && e.message ? e.message : e));
          continue;
        }
        if (returned === true) {
          willRespondAsync = true;
        } else if (returned && typeof returned.then === 'function') {
          willRespondAsync = true;
          (function (promise) {
            promise.then(function (v) { sendResponse(v); }, function () { sendResponse(undefined); });
          })(returned);
        }
        if (responded) { break; }
      }

      if (responded) { return; }
      if (!willRespondAsync) { __bb_message_response(responseId, null); }
      // Otherwise the native side waits (with a timeout) for an async sendResponse.
    },

    dispatchAlarm: function (nameJSON) {
      var name = parseJSON(nameJSON);
      var alarm = { name: name || '', scheduledTime: Date.now() };
      for (var i = 0; i < alarmListeners.length; i++) {
        try { alarmListeners[i](alarm); } catch (e) { __bb_log('error', 'alarms.onAlarm listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    dispatchStorageChanged: function (areaName, changesJSON) {
      var raw = parseJSON(changesJSON) || {};   // key -> { oldValue?: json, newValue?: json }
      var changes = {};
      for (var k in raw) {
        if (!Object.prototype.hasOwnProperty.call(raw, k)) { continue; }
        var entry = {};
        if (raw[k].oldValue !== undefined && raw[k].oldValue !== null) { entry.oldValue = parseJSON(raw[k].oldValue); }
        if (raw[k].newValue !== undefined && raw[k].newValue !== null) { entry.newValue = parseJSON(raw[k].newValue); }
        changes[k] = entry;
      }
      for (var i = 0; i < storageChangedListeners.length; i++) {
        try { storageChangedListeners[i](changes, areaName); } catch (e) { __bb_log('error', 'storage.onChanged listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    dispatchCookieChanged: function (changeJSON) {
      var change = parseJSON(changeJSON);
      if (!change) { return; }
      for (var i = 0; i < cookieChangedListeners.length; i++) {
        try { cookieChangedListeners[i](change); }
        catch (e) { __bb_log('error', 'cookies.onChanged listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    dispatchNotificationClicked: function (notificationId) {
      for (var i = 0; i < notificationClickedListeners.length; i++) {
        try { notificationClickedListeners[i](notificationId); }
        catch (e) { __bb_log('error', 'notifications.onClicked listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },
    dispatchNotificationClosed: function (notificationId, byUser) {
      for (var i = 0; i < notificationClosedListeners.length; i++) {
        try { notificationClosedListeners[i](notificationId, !!byUser); }
        catch (e) { __bb_log('error', 'notifications.onClosed listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },
    dispatchNotificationButtonClicked: function (notificationId, buttonIndex) {
      for (var i = 0; i < notificationButtonListeners.length; i++) {
        try { notificationButtonListeners[i](notificationId, buttonIndex | 0); }
        catch (e) { __bb_log('error', 'notifications.onButtonClicked listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    dispatchActionClicked: function (tabJSON) {
      var tab = parseJSON(tabJSON);
      for (var i = 0; i < actionClickedListeners.length; i++) {
        try { actionClickedListeners[i](tab); }
        catch (e) { __bb_log('error', 'action.onClicked listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    dispatchContextMenuClicked: function (infoJSON, tabJSON) {
      var info = parseJSON(infoJSON);
      var tab = parseJSON(tabJSON);
      for (var i = 0; i < contextMenuClickedListeners.length; i++) {
        try { contextMenuClickedListeners[i](info, tab); }
        catch (e) { __bb_log('error', 'contextMenus.onClicked listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    dispatchExtEvent: function (name, argsJSON) {
      var args = parseJSON(argsJSON);
      if (!Array.isArray(args)) { args = []; }
      var list = tabEventLists[name] || webNavLists[name];
      if (!list) { return; }
      for (var i = 0; i < list.length; i++) {
        try { list[i].apply(null, args); }
        catch (e) { __bb_log('error', name + ' listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    fireInstalled: function (reason) {
      var details = { reason: reason || 'install' };
      for (var i = 0; i < installedListeners.length; i++) {
        try { installedListeners[i](details); } catch (e) { __bb_log('error', 'runtime.onInstalled listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    fireStartup: function () {
      for (var i = 0; i < startupListeners.length; i++) {
        try { startupListeners[i](); } catch (e) { __bb_log('error', 'runtime.onStartup listener threw: ' + (e && e.message ? e.message : e)); }
      }
    }
  };
})();
