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

  var extId = (typeof __bbBgExtId === 'string') ? __bbBgExtId : '';
  var baseURL = (typeof __bbBgBaseURL === 'string') ? __bbBgBaseURL : '';
  var messages = {};
  try { messages = typeof __bbBgMessages === 'string' ? JSON.parse(__bbBgMessages) : {}; } catch (e) {}
  // messageKey → { placeholderName(lowercased): content } for chrome.i18n named placeholders.
  var i18nPlaceholders = {};
  try { i18nPlaceholders = typeof __bbBgPlaceholders === 'string' ? JSON.parse(__bbBgPlaceholders) : {}; } catch (e) {}
  var manifest = {};
  try {
    // Match Chrome: getManifest() returns the manifest with __MSG_<key>__ substituted from the
    // default-locale messages (name, description, …), so getManifest().name is the localized name.
    var __bbManifestJSON = (typeof __bbBgManifest === 'string' ? __bbBgManifest : '{}')
      .replace(/__MSG_(@?\w+)__/g, function (token, key) {
        var value = messages[key];
        return (typeof value === 'string') ? value : token;
      });
    manifest = JSON.parse(__bbManifestJSON);
  } catch (e) {}

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

    // ---------------------------------------------------------------- background-worker watchdog (diagnostic)
    // A headless service worker that never finishes booting hangs EVERY popup/dashboard message: an
    // extension's onMessage commonly does `await isFullyInitialized` (= its start()), and if start()
    // awaits a native bridge call that never calls back, that await never settles — the page sits on
    // "waiting on the background worker" with NO error (the extension's own logs are usually muted on
    // store installs). This instruments the request/response natives so any call left outstanding past a
    // threshold is NAMED in the Background log, pinning the stuck API instead of a silent hang. Pure
    // passthrough: it only wraps the callback so the pending entry clears when the native replies.
    (function installNativeWatchdog() {
      if (typeof __bb_log !== 'function') { return; }
      // Track EVERY __bb_* request/response native (auto-detected), not a curated list — a boot can hang
      // on any of them. Denylist only the ones that would recurse or track the watchdog's own machinery.
      var DENY = { __bb_log: 1, __bb_set_timeout: 1, __bb_clear_timer: 1 };
      var names = [];
      try {
        var all = Object.getOwnPropertyNames(globalThis);
        for (var ai = 0; ai < all.length; ai++) {
          var nm = all[ai];
          if (nm.indexOf('__bb_') === 0 && !DENY[nm] && typeof globalThis[nm] === 'function') { names.push(nm); }
        }
      } catch (eNames) { /* fall through with whatever we have */ }
      var pending = Object.create(null), seq = 1, warned = Object.create(null), totalCalls = 0;
      function nowMs() { try { return Date.now(); } catch (e) { return 0; } }
      names.forEach(function (name) {
        var orig = globalThis[name];
        if (typeof orig !== 'function') { return; }
        globalThis[name] = function () {
          var args = Array.prototype.slice.call(arguments), cbIdx = -1;
          for (var i = args.length - 1; i >= 0; i--) { if (typeof args[i] === 'function') { cbIdx = i; break; } }
          if (cbIdx < 0) { return orig.apply(this, args); }   // a synchronous native — nothing to track
          totalCalls++;
          var id = seq++;
          pending[id] = { label: name + (typeof args[0] === 'string' ? '(' + args[0] + ')' : ''), t: nowMs() };
          var userCb = args[cbIdx];
          args[cbIdx] = function () { delete pending[id]; return userCb.apply(this, arguments); };
          return orig.apply(this, args);
        };
      });
      // Let the inbound message dispatcher register an in-flight onMessage so a popup/dashboard request
      // that the worker receives but never answers (start() stuck, handler never sendResponse-s) is
      // named here too — the most direct signal for "page waiting on the background worker". Returns a
      // clear fn; an unanswered entry surfaces in the same >6s sweep.
      globalThis.__bbTrackPending = function (label) {
        totalCalls++;
        var pid = seq++;
        pending[pid] = { label: label, t: nowMs() };
        return function () { delete pending[pid]; };
      };
      function sweep() {
        var now = nowMs(), stuck = [];
        for (var id in pending) {
          var age = now - pending[id].t;
          if (age > 6000 && !warned[id]) { warned[id] = 1; stuck.push(pending[id].label + ' [' + Math.round(age / 1000) + 's, no reply]'); }
        }
        if (stuck.length) { __bb_log('error', '[BrownBear] background worker boot stalled — native bridge call(s) not returning: ' + stuck.join('; ')); }
        try { setTimeout(sweep, 4000); } catch (e) { /* timer gone — stop */ }
      }
      try { setTimeout(sweep, 4000); } catch (e) { /* no timer yet */ }
      // One-shot classifier: a healthy worker fires MANY native calls during boot. If it made ZERO in 8s,
      // its background source never ran start() — a module-link failure or a top-level throw — so the
      // sweep has nothing to name. Logged ONLY in that broken case, so healthy workers stay silent.
      try {
        setTimeout(function () {
          if (totalCalls === 0) {
            __bb_log('error', '[BrownBear] background worker made NO native bridge calls in 8s — its '
              + 'background source likely failed to evaluate / never ran start() (module-link failure or a '
              + 'top-level throw). Any popup/dashboard message will hang waiting on it.');
          }
        }, 8000);
      } catch (eHeartbeat) { /* no timer */ }
    })();

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
      // --- crypto.subtle helpers (symmetric: HMAC / AES-GCM / PBKDF2 / HKDF, via __bb_subtle) -------
      var __subBytes = function (src) {
        if (src == null) { return new Uint8Array(0); }
        if (src instanceof ArrayBuffer) { return new Uint8Array(src); }
        if (src.buffer instanceof ArrayBuffer) { return new Uint8Array(src.buffer, src.byteOffset || 0, src.byteLength); }
        if (Array.isArray(src)) { return new Uint8Array(src); }
        throw new TypeError('expected a BufferSource');
      };
      var __subB64 = function (src) {
        var u8 = __subBytes(src), bin = '';
        for (var i = 0; i < u8.length; i++) { bin += String.fromCharCode(u8[i]); }
        return btoa(bin);
      };
      var __subFromB64 = function (b64) {
        var bin = atob(b64 || ''), u8 = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) { u8[i] = bin.charCodeAt(i) & 0xff; }
        return u8;
      };
      var __subAlgo = function (a) { return (typeof a === 'string') ? { name: a } : (a || {}); };
      var __subHash = function (a, key) {
        var h = a && a.hash; if (h && h.name) { h = h.name; }
        if (!h && key && key.algorithm && key.algorithm.hash) { h = key.algorithm.hash.name || key.algorithm.hash; }
        return h || 'SHA-256';
      };
      var __subCall = function (op, params) {
        var r; try { r = JSON.parse(__bb_subtle(op, JSON.stringify(params))); } catch (e) { throw new Error('subtle bridge failure'); }
        if (r && r.error) { var er = new Error(r.error); er.name = 'OperationError'; throw er; }
        return r;
      };
      var __subKey = function (raw, algorithm, extractable, usages) {
        return { type: 'secret', extractable: extractable !== false, algorithm: algorithm, usages: usages || [], __raw: raw };
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
          // Web Crypto quota: >65536 bytes must FAIL CLOSED (never silently zero-fill → weak randomness).
          if (byteLen > 65536) {
            var qErr = new Error("getRandomValues: quota (65536 bytes) exceeded");
            qErr.name = "QuotaExceededError";
            throw qErr;
          }
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
                var src = __subBytes(data);
                var input = [];
                for (var i = 0; i < src.length; i++) { input.push(src[i] & 0xff); }
                var out = __bb_crypto_digest(name, input);
                if (!out) { reject(new Error('Unsupported digest algorithm: ' + name)); return; }
                var result = new Uint8Array(out.length);
                for (var j = 0; j < out.length; j++) { result[j] = out[j] & 0xff; }
                resolve(result.buffer);
              } catch (e) { reject(e); }
            });
          },
          importKey: function (format, keyData, algorithm, extractable, usages) {
            return new Promise(function (resolve, reject) {
              try {
                var ia = __subAlgo(algorithm), iname = (ia.name || '').toUpperCase();
                if (iname === 'ECDSA') {
                  var curve = ia.namedCurve || (keyData && keyData.crv) || 'P-256';
                  if (format === 'jwk') {
                    var ir = __subCall('ecdsaImportJwk', { curve: keyData.crv || curve, x: keyData.x || '', y: keyData.y || '', d: keyData.d || '' });
                    resolve({ type: ir.type, extractable: extractable !== false, algorithm: { name: 'ECDSA', namedCurve: keyData.crv || curve }, usages: usages || [], __raw: ir.raw });
                    return;
                  }
                  if (format === 'raw') {   // a bare public key: the x||y point bytes
                    resolve({ type: 'public', extractable: extractable !== false, algorithm: { name: 'ECDSA', namedCurve: curve }, usages: usages || [], __raw: __subB64(keyData) });
                    return;
                  }
                  reject(new Error("importKey: ECDSA supports 'jwk' and 'raw' (spki/pkcs8 pending)")); return;
                }
                if (format !== 'raw') { reject(new Error("importKey: only 'raw' format is supported for symmetric keys")); return; }
                resolve(__subKey(__subB64(keyData), __subAlgo(algorithm), extractable, usages));
              } catch (e) { reject(e); }
            });
          },
          exportKey: function (format, key) {
            return new Promise(function (resolve, reject) {
              try {
                if (!key || !key.extractable) { reject(new Error('exportKey: key is not extractable')); return; }
                var ename = (key.algorithm && key.algorithm.name || '').toUpperCase();
                if (ename === 'ECDSA') {
                  if (format === 'jwk') {
                    var jr = __subCall('ecdsaExportJwk', { curve: key.algorithm.namedCurve || 'P-256', raw: key.__raw, type: key.type });
                    resolve(jr.jwk); return;
                  }
                  if (format === 'raw' && key.type === 'public') { resolve(__subFromB64(key.__raw).buffer); return; }
                  reject(new Error("exportKey: ECDSA supports 'jwk' and public 'raw' (spki/pkcs8 pending)")); return;
                }
                if (format !== 'raw') { reject(new Error("exportKey: only 'raw' format is supported for symmetric keys")); return; }
                resolve(__subFromB64(key.__raw).buffer);
              } catch (e) { reject(e); }
            });
          },
          generateKey: function (algorithm, extractable, usages) {
            return new Promise(function (resolve, reject) {
              try {
                var a = __subAlgo(algorithm), name = (a.name || '').toUpperCase();
                if (name === 'AES-GCM' || name === 'AES-CBC' || name === 'AES-KW') {
                  var r = __subCall('generateAesKey', { length: a.length || 256 });
                  resolve(__subKey(r.data, a, extractable, usages));
                } else if (name === 'HMAC') {
                  var bits = a.length || 256;
                  var rnd = __bb_crypto_random(Math.ceil(bits / 8)) || [];
                  var u8 = new Uint8Array(rnd.length);
                  for (var i = 0; i < rnd.length; i++) { u8[i] = rnd[i] & 0xff; }
                  resolve(__subKey(__subB64(u8), a, extractable, usages));
                } else if (name === 'ECDSA') {
                  var curve = a.namedCurve || 'P-256';
                  var ek = __subCall('ecdsaGenerate', { curve: curve });
                  var ealg = { name: 'ECDSA', namedCurve: curve };
                  resolve({
                    privateKey: { type: 'private', extractable: extractable !== false, algorithm: ealg, usages: usages || [], __raw: ek.privateRaw },
                    publicKey: { type: 'public', extractable: true, algorithm: ealg, usages: usages || [], __raw: ek.publicRaw }
                  });
                } else { reject(new Error('generateKey: unsupported algorithm ' + name + ' (RSA is not yet supported)')); }
              } catch (e) { reject(e); }
            });
          },
          sign: function (algorithm, key, data) {
            return new Promise(function (resolve, reject) {
              try {
                var name = (__subAlgo(algorithm).name || key.algorithm.name || '').toUpperCase();
                if (name === 'ECDSA') {
                  var er = __subCall('ecdsaSign', { curve: (key.algorithm.namedCurve || 'P-256'), privateRaw: key.__raw, hash: __subHash(algorithm, key), data: __subB64(data) });
                  resolve(__subFromB64(er.data).buffer); return;
                }
                if (name !== 'HMAC') { reject(new Error('sign: unsupported algorithm ' + name + ' (RSA pending)')); return; }
                var r = __subCall('hmacSign', { key: key.__raw, data: __subB64(data), hash: __subHash(algorithm, key) });
                resolve(__subFromB64(r.data).buffer);
              } catch (e) { reject(e); }
            });
          },
          verify: function (algorithm, key, signature, data) {
            return new Promise(function (resolve, reject) {
              try {
                var name = (__subAlgo(algorithm).name || key.algorithm.name || '').toUpperCase();
                if (name === 'ECDSA') {
                  var ev = __subCall('ecdsaVerify', { curve: (key.algorithm.namedCurve || 'P-256'), publicRaw: key.__raw, hash: __subHash(algorithm, key), data: __subB64(data), signature: __subB64(signature) });
                  resolve(!!ev.valid); return;
                }
                if (name !== 'HMAC') { reject(new Error('verify: unsupported algorithm ' + name + ' (RSA pending)')); return; }
                var r = __subCall('hmacVerify', { key: key.__raw, data: __subB64(data), signature: __subB64(signature), hash: __subHash(algorithm, key) });
                resolve(!!r.valid);
              } catch (e) { reject(e); }
            });
          },
          encrypt: function (algorithm, key, data) {
            return new Promise(function (resolve, reject) {
              try {
                var a = __subAlgo(algorithm), name = (a.name || '').toUpperCase(), r;
                if (name === 'AES-GCM') {
                  r = __subCall('aesGcmEncrypt', { key: key.__raw, data: __subB64(data), iv: __subB64(a.iv), additionalData: a.additionalData ? __subB64(a.additionalData) : '' });
                } else if (name === 'AES-CBC') {
                  r = __subCall('aesCbcEncrypt', { key: key.__raw, data: __subB64(data), iv: __subB64(a.iv) });
                } else { reject(new Error('encrypt: unsupported algorithm ' + name)); return; }
                resolve(__subFromB64(r.data).buffer);
              } catch (e) { reject(e); }
            });
          },
          decrypt: function (algorithm, key, data) {
            return new Promise(function (resolve, reject) {
              try {
                var a = __subAlgo(algorithm), name = (a.name || '').toUpperCase(), r;
                if (name === 'AES-GCM') {
                  r = __subCall('aesGcmDecrypt', { key: key.__raw, data: __subB64(data), iv: __subB64(a.iv), additionalData: a.additionalData ? __subB64(a.additionalData) : '' });
                } else if (name === 'AES-CBC') {
                  r = __subCall('aesCbcDecrypt', { key: key.__raw, data: __subB64(data), iv: __subB64(a.iv) });
                } else { reject(new Error('decrypt: unsupported algorithm ' + name)); return; }
                resolve(__subFromB64(r.data).buffer);
              } catch (e) { reject(e); }
            });
          },
          deriveBits: function (algorithm, baseKey, length) {
            return new Promise(function (resolve, reject) {
              try {
                var a = __subAlgo(algorithm), name = (a.name || '').toUpperCase(), r;
                if (name === 'PBKDF2') {
                  r = __subCall('pbkdf2', { password: baseKey.__raw, salt: __subB64(a.salt), iterations: a.iterations || 100000, hash: __subHash(a, null), length: length });
                } else if (name === 'HKDF') {
                  r = __subCall('hkdf', { ikm: baseKey.__raw, salt: __subB64(a.salt), info: a.info ? __subB64(a.info) : '', hash: __subHash(a, null), length: length });
                } else { reject(new Error('deriveBits: unsupported algorithm ' + name)); return; }
                resolve(__subFromB64(r.data).buffer);
              } catch (e) { reject(e); }
            });
          },
          deriveKey: function (algorithm, baseKey, derivedKeyAlgo, extractable, usages) {
            var self = this;
            var da = __subAlgo(derivedKeyAlgo);
            var bits = da.length || 256;
            return self.deriveBits(algorithm, baseKey, bits).then(function (raw) {
              return self.importKey('raw', raw, da, extractable, usages);
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
          if (typeof src !== 'string') {
            throw new Error("importScripts failed to load: " + spec);
          }
          // Evaluate in the worker's GLOBAL scope (shared lexical env) via native evaluateScript, NOT
          // indirect (0,eval): a real worker shares ONE global scope across importScripts'd scripts, so
          // a chunk's top-level let/const/class must be visible to other chunks. (0,eval) scoped those
          // to the eval, breaking bundles that split shared top-level symbols across chunks.
          var err = __bb_eval_global(src, spec);
          if (err) { throw new Error("importScripts error in " + spec + ": " + err); }
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

    // MV2 extensions run their background as a background PAGE — a real DOM window, so `window` IS the
    // global. MV3 service workers have NO window (libraries feature-detect `typeof window` to tell a
    // worker from a page), so we expose `window` ONLY for MV2. Violentmonkey's MV2 background bundle
    // ends with `window._bg = 1`; without this the final statement throws and the module aborts.
    if (typeof globalThis.window === 'undefined' && (manifest.manifest_version || 2) < 3) {
      globalThis.window = globalThis;
    }

    // MV2 background PAGES have a real `document`; our headless context does not, so an MV2 bundle that
    // touches `document` at init (Violentmonkey references it during its IndexedDB "Upgrade database…"
    // step) throws "Can't find variable: document" and the failure cascades into later promise chains.
    // We provide a minimal, non-rendering DOM document — enough for the common background-page idioms
    // (createElement, an <a> for URL parsing, fragments, event no-ops). MV3 service workers get NONE
    // (Chrome SWs have no document; libraries feature-detect it), so this is gated to MV2.
    if (typeof globalThis.document === 'undefined' && (manifest.manifest_version || 2) < 3) {
      var __bbMakeNode = function (tag) {
        tag = String(tag == null ? 'div' : tag).toLowerCase();
        var node = {
          tagName: tag.toUpperCase(), nodeName: tag.toUpperCase(), nodeType: 1, namespaceURI: 'http://www.w3.org/1999/xhtml',
          childNodes: [], children: [], style: {}, dataset: {}, _attrs: {},
          parentNode: null, firstChild: null, lastChild: null, nextSibling: null, previousSibling: null,
          textContent: '', innerHTML: '', outerHTML: '', innerText: '', value: '', id: '', className: '',
          classList: { add: function () {}, remove: function () {}, toggle: function () { return false; },
                       contains: function () { return false; }, replace: function () {} },
          setAttribute: function (k, v) { this._attrs[String(k)] = String(v); },
          getAttribute: function (k) { return Object.prototype.hasOwnProperty.call(this._attrs, String(k)) ? this._attrs[String(k)] : null; },
          removeAttribute: function (k) { delete this._attrs[String(k)]; },
          hasAttribute: function (k) { return Object.prototype.hasOwnProperty.call(this._attrs, String(k)); },
          setAttributeNS: function (ns, k, v) { this.setAttribute(k, v); },
          appendChild: function (c) { this.childNodes.push(c); if (c && c.nodeType === 1) { this.children.push(c); } if (c) { c.parentNode = this; } this.firstChild = this.childNodes[0]; this.lastChild = c; return c; },
          insertBefore: function (c) { this.childNodes.unshift(c); if (c && c.nodeType === 1) { this.children.unshift(c); } if (c) { c.parentNode = this; } this.firstChild = c; return c; },
          removeChild: function (c) { var i = this.childNodes.indexOf(c); if (i >= 0) { this.childNodes.splice(i, 1); } var j = this.children.indexOf(c); if (j >= 0) { this.children.splice(j, 1); } if (c) { c.parentNode = null; } return c; },
          replaceChild: function (n, o) { this.removeChild(o); this.appendChild(n); return o; },
          append: function () {}, prepend: function () {}, before: function () {}, after: function () {}, remove: function () {},
          cloneNode: function () { return __bbMakeNode(tag); },
          contains: function () { return false; },
          addEventListener: function () {}, removeEventListener: function () {}, dispatchEvent: function () { return true; },
          getElementsByTagName: function () { return []; }, getElementsByClassName: function () { return []; },
          querySelector: function () { return null; }, querySelectorAll: function () { return []; },
          getBoundingClientRect: function () { return { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0 }; },
          focus: function () {}, blur: function () {}, click: function () {}, scrollIntoView: function () {},
          insertAdjacentHTML: function () {}, insertAdjacentElement: function () {},
          setSelectionRange: function () {}, select: function () {}, getContext: function () { return null; }
        };
        // <a>/<area>: assigning .href (or setAttribute('href')) parses the URL and exposes its parts —
        // the canonical background-page URL-parsing idiom (`var a=document.createElement('a'); a.href=u`).
        if (tag === 'a' || tag === 'area') {
          var hrefVal = '';
          var applyHref = function (v) {
            try {
              var u = new globalThis.URL(String(v), (globalThis.location && globalThis.location.href) || baseURL || undefined);
              hrefVal = u.href; node.protocol = u.protocol; node.hostname = u.hostname; node.host = u.host;
              node.port = u.port; node.pathname = u.pathname; node.search = u.search; node.hash = u.hash; node.origin = u.origin;
            } catch (e) { hrefVal = String(v); node.protocol = ''; node.hostname = ''; node.host = ''; node.port = '';
              node.pathname = ''; node.search = ''; node.hash = ''; node.origin = 'null'; }
          };
          Object.defineProperty(node, 'href', { configurable: true, enumerable: true,
            get: function () { return hrefVal; }, set: applyHref });
          var baseSet = node.setAttribute;
          node.setAttribute = function (k, v) { baseSet.call(this, k, v); if (String(k).toLowerCase() === 'href') { applyHref(v); } };
        }
        // <canvas>: a non-throwing 2D context + toDataURL. A headless JSContext can't rasterize, but an
        // MV2 background page has a real canvas, and libraries use it (e.g. Violentmonkey's icon loader
        // does `new Image()` → `createElement('canvas')` → `getContext('2d').drawImage` → `toDataURL` on
        // EVERY popup/options open). Returning null from getContext made `ctx.drawImage` throw, which
        // rejected VM's GetData/InitPopup handler and broke the whole popup. Stub the surface so it no-ops
        // and returns a valid 1×1 transparent PNG instead of throwing.
        if (tag === 'canvas') {
          node.width = 300; node.height = 150;
          var __bbCtx2d = {
            canvas: node,
            drawImage: function (img) { if (img && img.__bbDataUrl) { node.__bbDrawn = img.__bbDataUrl; } },
            clearRect: function () {}, fillRect: function () {}, strokeRect: function () {},
            beginPath: function () {}, closePath: function () {}, moveTo: function () {}, lineTo: function () {},
            arc: function () {}, arcTo: function () {}, rect: function () {}, ellipse: function () {},
            fill: function () {}, stroke: function () {}, clip: function () {},
            save: function () {}, restore: function () {}, scale: function () {}, rotate: function () {},
            translate: function () {}, transform: function () {}, setTransform: function () {}, resetTransform: function () {},
            fillText: function () {}, strokeText: function () {}, measureText: function () { return { width: 0 }; },
            createLinearGradient: function () { return { addColorStop: function () {} }; },
            createRadialGradient: function () { return { addColorStop: function () {} }; },
            createPattern: function () { return null; },
            getImageData: function (x, y, w, h) {
              w = Math.max(1, w || node.width || 1); h = Math.max(1, h || node.height || 1);
              return { data: new Uint8ClampedArray(w * h * 4), width: w, height: h };
            },
            putImageData: function () {},
            createImageData: function (w, h) {
              w = Math.max(1, (typeof w === 'object' && w) ? w.width : (w || 1)); h = Math.max(1, h || 1);
              return { data: new Uint8ClampedArray(w * h * 4), width: w, height: h };
            },
            setLineDash: function () {}, getLineDash: function () { return []; }
          };
          node.getContext = function (t) { return (t === '2d') ? __bbCtx2d : null; };
          // The image drawn onto this canvas (fetched natively via Image.src) IS the real icon — return
          // it. Fallback: a valid 1×1 transparent PNG so callers never get a broken data-URI.
          node.toDataURL = function () {
            return node.__bbDrawn || 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
          };
          node.toBlob = function (cb) { if (typeof cb === 'function') { cb(null); } };
        }
        return node;
      };
      var __bbDocEl = __bbMakeNode('html'), __bbHead = __bbMakeNode('head'), __bbBody = __bbMakeNode('body');
      globalThis.document = {
        nodeType: 9, nodeName: '#document', readyState: 'complete', visibilityState: 'visible', hidden: false,
        documentElement: __bbDocEl, head: __bbHead, body: __bbBody, title: '', cookie: '',
        characterSet: 'UTF-8', charset: 'UTF-8', compatMode: 'CSS1Compat', contentType: 'text/html',
        location: globalThis.location, URL: (globalThis.location && globalThis.location.href) || baseURL || '',
        documentURI: (globalThis.location && globalThis.location.href) || baseURL || '',
        defaultView: globalThis,
        // document.currentScript — a classic background-page script reads its own URL from here at eval
        // time (uBO's lz4-block-codec-any.js does `document.currentScript.src` to locate its wasm
        // sibling). A script-element-shaped stub whose src points into the package; a wasm fetch derived
        // from it simply 404s and such loaders fall back to their pure-JS path.
        currentScript: { src: (baseURL || '') + 'background-prelude.js', type: 'text/javascript', async: false, defer: false },
        createElement: function (t) { return __bbMakeNode(t); },
        createElementNS: function (ns, t) { return __bbMakeNode(t); },
        createTextNode: function (txt) { return { nodeType: 3, nodeName: '#text', textContent: String(txt), nodeValue: String(txt), parentNode: null }; },
        createComment: function (txt) { return { nodeType: 8, nodeName: '#comment', textContent: String(txt), nodeValue: String(txt) }; },
        createDocumentFragment: function () { return __bbMakeNode('#document-fragment'); },
        createEvent: function () { return { initEvent: function () {}, initCustomEvent: function () {} }; },
        getElementById: function () { return null; },
        getElementsByTagName: function () { return []; },
        getElementsByClassName: function () { return []; },
        getElementsByName: function () { return []; },
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; },
        addEventListener: function () {}, removeEventListener: function () {}, dispatchEvent: function () { return true; },
        hasFocus: function () { return false; },
        write: function () {}, writeln: function () {}, open: function () { return globalThis.document; }, close: function () {},
        execCommand: function () { return false; },
        implementation: { createHTMLDocument: function () { return globalThis.document; },
                          createDocument: function () { return globalThis.document; }, hasFeature: function () { return true; } }
      };
      __bbDocEl.ownerDocument = globalThis.document; __bbHead.ownerDocument = globalThis.document; __bbBody.ownerDocument = globalThis.document;
      __bbDocEl.appendChild(__bbHead); __bbDocEl.appendChild(__bbBody);

      // Image: an MV2 background page has one; libraries `new Image()` then await onload/onerror. We can't
      // load pixels in a headless JSContext, so report load-failure on a later tick (so the awaiter
      // unblocks) — the caller then draws onto the stub canvas and gets the transparent-PNG toDataURL.
      // Without this, `new Image()` is a ReferenceError that aborts the caller (e.g. VM's icon loader).
      if (typeof globalThis.Image === 'undefined') {
        globalThis.Image = function (w, h) {
          this.width = w || 0; this.height = h || 0; this.naturalWidth = 0; this.naturalHeight = 0;
          this.complete = false; this.onload = null; this.onerror = null; this.crossOrigin = null;
          this.naturalWidth = 0; this.naturalHeight = 0; this.__bbDataUrl = null;
          var self = this, _src = '';
          Object.defineProperty(this, 'src', {
            configurable: true, enumerable: true,
            get: function () { return _src; },
            set: function (v) {
              _src = String(v); self.complete = false; self.__bbDataUrl = null;
              // Fetch the bytes natively → a data: URL the canvas stub returns from toDataURL (real icon).
              __bb_fetch_image(_src, function (resJSON) {
                var r = parseJSON(resJSON) || {};
                self.complete = true;
                if (r.dataUrl) {
                  self.__bbDataUrl = r.dataUrl; self.naturalWidth = r.width || 0; self.naturalHeight = r.height || 0;
                  if (typeof self.onload === 'function') { try { self.onload({ type: 'load' }); } catch (e) {} }
                } else if (typeof self.onerror === 'function') {
                  try { self.onerror({ type: 'error' }); } catch (e) {}
                }
              });
            }
          });
          this.addEventListener = function (t, fn) { if (t === 'load') { self.onload = fn; } else if (t === 'error') { self.onerror = fn; } };
          this.removeEventListener = function () {};
          this.setAttribute = function () {}; this.getAttribute = function () { return null; };
        };
      }
    }

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
    function base64FromBytes(bytes) {
      var bin = '';
      for (var i = 0; i < bytes.length; i++) { bin += String.fromCharCode(bytes[i]); }
      return btoa(bin);
    }
    // Response supports BOTH construction forms:
    //  - the spec `new Response(bodyInit, init)` — extensions build these directly (Tampermonkey's save
    //    pipeline does `new Response(blob).text()` to read a script's source back out of a Blob; with
    //    only the internal form below, that returned "" and the saved script registered EMPTY → it never
    //    appeared in the installed list);
    //  - the internal native-result shape `{ok, status, headers, bodyBase64}` our fetch/clone pass
    //    (recognized by its marker keys when no init is given, so existing callers are unchanged).
    function Response(result, init) {
      var native = (init === undefined) && result !== null && typeof result === 'object'
        && !(typeof globalThis.Blob === 'function' && result instanceof globalThis.Blob)
        && (result.bodyBase64 !== undefined || result.status !== undefined || result.ok !== undefined);
      if (native) {
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
        return;
      }
      // Spec form: (bodyInit?, {status?, statusText?, headers?})
      init = init || {};
      this.status = (init.status === undefined) ? 200 : (init.status | 0);
      this.ok = this.status >= 200 && this.status < 300;
      this.statusText = init.statusText || '';
      this.url = '';
      this.headers = new Headers(init.headers || {});
      this.redirected = false;
      this.type = 'basic';
      this.bodyUsed = false;
      var body = (result === undefined) ? null : result;
      if (body === null) { this._b64 = ''; }
      else if (typeof body === 'string') { this._b64 = base64FromBytes(new TextEncoder().encode(body)); }
      else if (typeof globalThis.Blob === 'function' && body instanceof globalThis.Blob && body._bbBytes) {
        this._b64 = base64FromBytes(body._bbBytes);
        if (!this.headers.has('content-type') && body.type) { this.headers.set('content-type', body.type); }
      } else if (Object.prototype.toString.call(body) === '[object ArrayBuffer]') {
        // Brand check, not instanceof — robust if the buffer was created in another realm.
        this._b64 = base64FromBytes(new Uint8Array(body));
      } else if (body && Object.prototype.toString.call(body.buffer) === '[object ArrayBuffer]'
                 && typeof body.byteLength === 'number') {
        this._b64 = base64FromBytes(new Uint8Array(body.buffer, body.byteOffset || 0, body.byteLength));
      } else if (typeof URLSearchParams === 'function' && body instanceof URLSearchParams) {
        this._b64 = base64FromBytes(new TextEncoder().encode(body.toString()));
        if (!this.headers.has('content-type')) { this.headers.set('content-type', 'application/x-www-form-urlencoded;charset=UTF-8'); }
      } else {
        // Spec stringifies other bodies; better a readable body than a silent empty one.
        this._b64 = base64FromBytes(new TextEncoder().encode(String(body)));
      }
    }
    Response.prototype.arrayBuffer = function () { this.bodyUsed = true; return Promise.resolve(bytesFromBase64(this._b64).buffer); };
    Response.prototype.text = function () { this.bodyUsed = true; return Promise.resolve(new TextDecoder('utf-8').decode(bytesFromBase64(this._b64))); };
    Response.prototype.json = function () { return this.text().then(function (t) { return JSON.parse(t); }); };
    Response.prototype.blob = function () {
      this.bodyUsed = true;
      var bytes = bytesFromBase64(this._b64);
      var ct = this.headers.get('content-type') || '';
      return Promise.resolve((typeof globalThis.Blob === 'function')
        ? new globalThis.Blob([bytes.buffer], { type: ct }) : bytes.buffer);
    };
    Response.prototype.clone = function () {
      return new Response({ ok: this.ok, status: this.status, statusText: this.statusText,
                            url: this.url, headers: this.headers._m, bodyBase64: this._b64 });
    };
    if (typeof globalThis.Headers !== 'function') { globalThis.Headers = Headers; }
    if (typeof globalThis.Response !== 'function') { globalThis.Response = Response; }

    // FormData — JSC has no DOM, but extensions (e.g. Grammarly) construct FormData for fetch/XHR
    // bodies; without it `new FormData()` throws "Can't find variable: FormData". __bbSerialize lets the
    // fetch shim above turn it into a real multipart/form-data body.
    if (typeof globalThis.FormData !== 'function') {
      var FormDataPoly = function () { this._e = []; };   // entries: [name, value, filename?]
      FormDataPoly.prototype.append = function (n, v, fn) { this._e.push([String(n), v, fn]); };
      FormDataPoly.prototype.set = function (n, v, fn) {
        n = String(n); var done = false, out = [];
        for (var i = 0; i < this._e.length; i++) {
          if (this._e[i][0] === n) { if (!done) { out.push([n, v, fn]); done = true; } } else { out.push(this._e[i]); }
        }
        if (!done) { out.push([n, v, fn]); }
        this._e = out;
      };
      FormDataPoly.prototype['delete'] = function (n) { n = String(n); this._e = this._e.filter(function (x) { return x[0] !== n; }); };
      FormDataPoly.prototype.get = function (n) { n = String(n); for (var i = 0; i < this._e.length; i++) { if (this._e[i][0] === n) { return this._e[i][1]; } } return null; };
      FormDataPoly.prototype.getAll = function (n) { n = String(n); return this._e.filter(function (x) { return x[0] === n; }).map(function (x) { return x[1]; }); };
      FormDataPoly.prototype.has = function (n) { return this.get(String(n)) !== null; };
      FormDataPoly.prototype.forEach = function (cb, t) { for (var i = 0; i < this._e.length; i++) { cb.call(t, this._e[i][1], this._e[i][0], this); } };
      FormDataPoly.prototype.keys = function () { return this._e.map(function (x) { return x[0]; }); };
      FormDataPoly.prototype.values = function () { return this._e.map(function (x) { return x[1]; }); };
      FormDataPoly.prototype.entries = function () { return this._e.map(function (x) { return [x[0], x[1]]; }); };
      FormDataPoly.prototype.__bbSerialize = function () {
        var boundary = '----BrownBearFormBoundary' + Math.random().toString(36).slice(2) + Date.now().toString(36);
        var parts = '';
        for (var i = 0; i < this._e.length; i++) {
          var name = this._e[i][0], value = this._e[i][1], filename = this._e[i][2];
          parts += '--' + boundary + '\r\n';
          if (value && typeof value === 'object' && (filename || typeof value.name === 'string')) {
            parts += 'Content-Disposition: form-data; name="' + name + '"; filename="' + (filename || value.name || 'blob') + '"\r\n';
            parts += 'Content-Type: ' + (value.type || 'application/octet-stream') + '\r\n\r\n';
            parts += (typeof value === 'string' ? value : (value._text || '')) + '\r\n';
          } else {
            parts += 'Content-Disposition: form-data; name="' + name + '"\r\n\r\n' + String(value) + '\r\n';
          }
        }
        return { body: parts + '--' + boundary + '--\r\n', contentType: 'multipart/form-data; boundary=' + boundary };
      };
      globalThis.FormData = FormDataPoly;
    }

    // AbortController / AbortSignal — extensions and fetch wrappers (uBO, ScriptCat, Grammarly) create
    // `new AbortController()` and pass `signal` to fetch; without these, that throws "Can't find variable:
    // AbortController" at init. A DOMException-shaped 'AbortError' is what callers branch on.
    function bbAbortError(reason, name, message) {
      if (reason !== undefined && reason !== null) { return reason; }
      if (typeof globalThis.DOMException === 'function') { return new globalThis.DOMException(message, name); }
      var e = new Error(message); e.name = name; return e;
    }
    if (typeof globalThis.AbortSignal !== 'function' || typeof globalThis.AbortController !== 'function') {
      var BBAbortSignal = function () { this.aborted = false; this.reason = undefined; this.onabort = null; this._lst = []; };
      BBAbortSignal.prototype.addEventListener = function (t, fn) { if (t === 'abort' && typeof fn === 'function') { this._lst.push(fn); } };
      BBAbortSignal.prototype.removeEventListener = function (t, fn) {
        if (t !== 'abort') { return; } var i = this._lst.indexOf(fn); if (i >= 0) { this._lst.splice(i, 1); }
      };
      BBAbortSignal.prototype.dispatchEvent = function () { return true; };
      BBAbortSignal.prototype.throwIfAborted = function () { if (this.aborted) { throw this.reason; } };
      BBAbortSignal.prototype._abort = function (reason) {
        if (this.aborted) { return; }
        this.aborted = true;
        this.reason = bbAbortError(reason, 'AbortError', 'signal is aborted without reason');
        var ev = { type: 'abort', target: this };
        if (typeof this.onabort === 'function') { try { this.onabort(ev); } catch (e) { /* listener error */ } }
        for (var i = 0; i < this._lst.length; i++) { try { this._lst[i].call(this, ev); } catch (e2) { /* listener error */ } }
      };
      BBAbortSignal.abort = function (reason) {
        var s = new BBAbortSignal(); s.aborted = true;
        s.reason = bbAbortError(reason, 'AbortError', 'signal is aborted without reason'); return s;
      };
      BBAbortSignal.timeout = function (ms) {
        var s = new BBAbortSignal();
        setTimeout(function () { s._abort(bbAbortError(null, 'TimeoutError', 'signal timed out')); }, ms || 0);
        return s;
      };
      var BBAbortController = function () { this.signal = new BBAbortSignal(); };
      BBAbortController.prototype.abort = function (reason) { this.signal._abort(reason); };
      globalThis.AbortSignal = BBAbortSignal;
      globalThis.AbortController = BBAbortController;
    }

    // Request — `new Request(input, init)` and `fetch(request)`. We store enough that fetch() below can
    // read url/method/headers/body/signal off it; the body is kept verbatim for fetch's encoder.
    if (typeof globalThis.Request !== 'function') {
      var BBRequest = function (input, init) {
        init = init || {};
        var base = (input && typeof input === 'object' && input.url !== undefined) ? input : null;
        this.url = base ? String(base.url) : String(input);
        this.method = String(init.method || (base && base.method) || 'GET').toUpperCase();
        this.headers = new Headers((init.headers !== undefined) ? init.headers : (base ? base.headers : {}));
        this.credentials = init.credentials || (base && base.credentials) || 'same-origin';
        this.mode = init.mode || (base && base.mode) || 'cors';
        this.cache = init.cache || (base && base.cache) || 'default';
        this.redirect = init.redirect || (base && base.redirect) || 'follow';
        this.referrer = (init.referrer !== undefined) ? init.referrer : (base ? base.referrer : 'about:client');
        this.integrity = init.integrity || (base && base.integrity) || '';
        this.signal = (init.signal !== undefined) ? init.signal : (base ? base.signal : null);
        this._bodyInit = (init.body !== undefined && init.body !== null) ? init.body
                       : (base ? base._bodyInit : null);
        this.bodyUsed = false;
      };
      BBRequest.prototype.clone = function () {
        return new BBRequest(this.url, {
          method: this.method, headers: this.headers, credentials: this.credentials, mode: this.mode,
          cache: this.cache, redirect: this.redirect, referrer: this.referrer, integrity: this.integrity,
          signal: this.signal, body: this._bodyInit
        });
      };
      Object.defineProperty(BBRequest.prototype, Symbol.toStringTag, { get: function () { return 'Request'; } });
      globalThis.Request = BBRequest;
    }

    function fetch(input, init) {
      init = init || {};
      // A Request (our shim, or anything carrying a `url`) supplies method/headers/body/signal unless
      // `init` overrides them — so `fetch(new Request(url, {...}))` and `fetch(req, {signal})` both work.
      var reqObj = (input && typeof input === 'object' && input.url !== undefined) ? input : null;
      var url, method = 'GET', headers = {}, body = null, bodyEncoding = 'utf8';
      url = reqObj ? String(reqObj.url) : String(input);
      if (reqObj && reqObj.method) { method = reqObj.method; }
      if (init.method) { method = init.method; }
      var signal = (init.signal !== undefined) ? init.signal : (reqObj ? reqObj.signal : null);
      // Resolve a relative URL ('/path' or 'path') against the worker's own origin, so fetching a
      // PACKAGED resource (e.g. ScriptCat's fetch('/src/content.js')) reaches the extension scheme
      // handler instead of an unparseable bare path. Absolute URLs pass through unchanged.
      try {
        var __fetchBase = (globalThis.location && globalThis.location.href) || globalThis.__bbBgBaseURL;
        if (__fetchBase) { url = new globalThis.URL(url, __fetchBase).href; }
      } catch (e) { /* leave url as written */ }
      // blob: object URLs minted by THIS context's URL.createObjectURL resolve synchronously from the
      // registry — they can never reach the native HTTP path (the bytes only exist in this JSContext).
      // Tampermonkey's save pipeline reads a script's source back via fetch(objUrl) → .blob() → text;
      // without this the fetch rejected, toBlob() swallowed it to undefined, and the saved script
      // registered EMPTY → it never appeared in the installed list. Unknown/revoked blob: URLs reject
      // with TypeError, matching Chrome.
      if (/^blob:/i.test(String(url))) {
        var __obj = globalThis.__bbObjectURLs && globalThis.__bbObjectURLs[String(url)];
        if (__obj && __obj._bbBytes) {
          var __objB64 = '', __objBytes = __obj._bbBytes;
          for (var __oi = 0; __oi < __objBytes.length; __oi++) { __objB64 += String.fromCharCode(__objBytes[__oi]); }
          return Promise.resolve(new Response({
            ok: true, status: 200, statusText: 'OK', url: String(url),
            headers: __obj.type ? { 'content-type': __obj.type } : {},
            bodyBase64: btoa(__objB64)
          }));
        }
        return Promise.reject(new TypeError('Failed to fetch'));
      }
      var headersInit = (init.headers !== undefined) ? init.headers : (reqObj ? reqObj.headers : null);
      if (headersInit) {
        if (headersInit._m) { headers = headersInit._m; }                         // our Headers instance
        else if (typeof headersInit.forEach === 'function') {                     // a Map
          headersInit.forEach(function (v, k) { headers[k] = v; });
        } else { headers = headersInit; }                                         // a plain object
      }
      var bodyInit = (init.body !== undefined && init.body !== null) ? init.body
                   : (reqObj ? reqObj._bodyInit : null);
      if (bodyInit != null) {
        var hasCT = false;
        for (var hk in headers) { if (hk.toLowerCase() === 'content-type') { hasCT = true; break; } }
        if (typeof bodyInit === 'string') { body = bodyInit; bodyEncoding = 'utf8'; }
        else if (typeof URLSearchParams === 'function' && bodyInit instanceof URLSearchParams) {
          // x-www-form-urlencoded — serialize via the params' own toString, not JSON.
          body = bodyInit.toString(); bodyEncoding = 'utf8';
          if (!hasCT) { headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8'; }
        } else if (typeof FormData === 'function' && bodyInit instanceof FormData
                   && typeof bodyInit.__bbSerialize === 'function') {
          var fd = bodyInit.__bbSerialize();   // multipart/form-data with a boundary
          body = fd.body; bodyEncoding = 'utf8';
          if (!hasCT) { headers['Content-Type'] = fd.contentType; }
        } else if (typeof globalThis.Blob === 'function' && bodyInit instanceof globalThis.Blob && bodyInit._bbBytes) {
          var bb = bodyInit._bbBytes, bbin = '';
          for (var bi = 0; bi < bb.length; bi++) { bbin += String.fromCharCode(bb[bi]); }
          body = btoa(bbin); bodyEncoding = 'base64';
          if (!hasCT && bodyInit.type) { headers['Content-Type'] = bodyInit.type; }
        } else if (bodyInit instanceof ArrayBuffer || (bodyInit.buffer instanceof ArrayBuffer)) {
          var u8 = bodyInit instanceof ArrayBuffer ? new Uint8Array(bodyInit)
                 : new Uint8Array(bodyInit.buffer, bodyInit.byteOffset || 0, bodyInit.byteLength);
          var bin = '';
          for (var i = 0; i < u8.length; i++) { bin += String.fromCharCode(u8[i]); }
          body = btoa(bin); bodyEncoding = 'base64';
        } else {
          try { body = JSON.stringify(bodyInit); } catch (e) { body = String(bodyInit); }
          bodyEncoding = 'utf8';
        }
      }
      var reqJSON = JSON.stringify({ url: url, method: method, headers: headers, body: body, bodyEncoding: bodyEncoding });
      return new Promise(function (resolve, reject) {
        // Honor an AbortSignal: reject immediately if already aborted, and on a later abort. The native
        // request can't be cancelled mid-flight, but the caller's promise settles as Chrome's does.
        if (signal && signal.aborted) { reject(bbAbortError(signal.reason, 'AbortError', 'The operation was aborted.')); return; }
        var settled = false;
        var onAbort = function () {
          if (settled) { return; } settled = true;
          reject(bbAbortError(signal && signal.reason, 'AbortError', 'The operation was aborted.'));
        };
        if (signal && typeof signal.addEventListener === 'function') { signal.addEventListener('abort', onAbort); }
        if (typeof __bb_fetch !== 'function') { settled = true; reject(new TypeError('fetch is unavailable')); return; }
        try {
          __bb_fetch(reqJSON, function (resJSON) {
            if (settled) { return; }
            settled = true;
            if (signal && typeof signal.removeEventListener === 'function') { signal.removeEventListener('abort', onAbort); }
            var r;
            try { r = JSON.parse(resJSON); } catch (e) { reject(new TypeError('Failed to fetch')); return; }
            // A null/absent reply must REJECT, not crash reading .error on null.
            if (!r || r.error) { reject(new TypeError('Failed to fetch' + (r && r.error ? ': ' + r.error : ''))); return; }
            resolve(new Response(r));
          });
        } catch (e) { settled = true; reject(e); }
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

    // Event / EventTarget / CustomEvent / ExtendableEvent — JavaScriptCore's headless global has NO DOM
    // event constructors, but extensions construct them in their handlers (e.g. `new Event('x')`,
    // `new CustomEvent('y', { detail })`). Best AdBlocker's tabs.onUpdated listener threw
    // "Can't find variable: Event". Provide spec-shaped minimal versions so those don't crash.
    if (typeof globalThis.Event !== 'function') {
      var BBEvent = function (type, init) {
        init = init || {};
        this.type = String(type == null ? '' : type);
        this.bubbles = !!init.bubbles; this.cancelable = !!init.cancelable; this.composed = !!init.composed;
        this.defaultPrevented = false; this.target = null; this.currentTarget = null; this.eventPhase = 0;
        this.timeStamp = (globalThis.performance && performance.now) ? performance.now() : Date.now();
        this.isTrusted = false; this._stop = false;
      };
      BBEvent.prototype.preventDefault = function () { if (this.cancelable) { this.defaultPrevented = true; } };
      BBEvent.prototype.stopPropagation = function () { this._stop = true; };
      BBEvent.prototype.stopImmediatePropagation = function () { this._stop = true; };
      BBEvent.NONE = 0; BBEvent.CAPTURING_PHASE = 1; BBEvent.AT_TARGET = 2; BBEvent.BUBBLING_PHASE = 3;
      globalThis.Event = BBEvent;
    }
    if (typeof globalThis.CustomEvent !== 'function') {
      var BBCustomEvent = function (type, init) {
        init = init || {}; globalThis.Event.call(this, type, init);
        this.detail = init.detail !== undefined ? init.detail : null;
      };
      BBCustomEvent.prototype = Object.create(globalThis.Event.prototype);
      BBCustomEvent.prototype.constructor = BBCustomEvent;
      globalThis.CustomEvent = BBCustomEvent;
    }
    if (typeof globalThis.ExtendableEvent !== 'function') {
      var BBExtendableEvent = function (type, init) { globalThis.Event.call(this, type, init); this._promises = []; };
      BBExtendableEvent.prototype = Object.create(globalThis.Event.prototype);
      BBExtendableEvent.prototype.constructor = BBExtendableEvent;
      BBExtendableEvent.prototype.waitUntil = function (p) { this._promises.push(Promise.resolve(p)); };
      globalThis.ExtendableEvent = BBExtendableEvent;
    }
    if (typeof globalThis.EventTarget !== 'function') {
      var BBEventTarget = function () { this.__lst = {}; };
      BBEventTarget.prototype.addEventListener = function (type, listener) {
        if (typeof listener !== 'function') { return; }
        (this.__lst[type] = this.__lst[type] || []).push(listener);
      };
      BBEventTarget.prototype.removeEventListener = function (type, listener) {
        var arr = this.__lst[type]; if (!arr) { return; }
        var i = arr.indexOf(listener); if (i >= 0) { arr.splice(i, 1); }
      };
      BBEventTarget.prototype.dispatchEvent = function (event) {
        var arr = this.__lst[event && event.type]; if (!arr) { return true; }
        if (event) { event.target = this; event.currentTarget = this; }
        arr.slice().forEach(function (l) { if (event && event._stop) { return; } try { l(event); } catch (e) {} });
        return !(event && event.defaultPrevented);
      };
      globalThis.EventTarget = BBEventTarget;
    }

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
      var __bbRegListeners = {};
      // A minimal ServiceWorker descriptor for self.registration.serviceWorker /
      // self.registration.active / self.registration.installing. Extensions like MetaMask check
      // `registration.serviceWorker.state === "activated"` during their init handshake. Represent
      // the running worker as already activated — the only honest state in a JSContext (we have
      // no install/activate lifecycle since the context is headless, not a real browser SW).
      var __bbSWDescriptor = { state: 'activated', scriptURL: baseURL + 'service-worker.js',
        addEventListener: function () {}, removeEventListener: function () {}, dispatchEvent: function () { return true; } };
      globalThis.registration = {
        scope: baseURL,
        // Report as activated — headless JSC has no pending installation lifecycle.
        active: __bbSWDescriptor, installing: null, waiting: null,
        // registration.serviceWorker — the controller descriptor (navigator.serviceWorker.controller
        // shape). MetaMask checks `registration.serviceWorker.state === 'activated'` at boot; without
        // this property it throws "Cannot read properties of undefined (reading 'state')".
        serviceWorker: __bbSWDescriptor,
        unregister: function () { return Promise.resolve(true); },
        update: function () { return Promise.resolve(); },
        showNotification: function () { return Promise.resolve(); },
        getNotifications: function () { return Promise.resolve([]); },
        // Service workers use self.registration.addEventListener('updatefound', ...) to track SW
        // lifecycle updates. JSC's ServiceWorkerRegistration has addEventListener/dispatchEvent;
        // our minimal stub was missing them and Momentum's serviceWorker.js crashed on it.
        addEventListener: function (type, listener) {
          if (typeof listener !== 'function') { return; }
          (__bbRegListeners[type] = __bbRegListeners[type] || []).push(listener);
        },
        removeEventListener: function (type, listener) {
          var arr = __bbRegListeners[type]; if (!arr) { return; }
          var i = arr.indexOf(listener); if (i >= 0) { arr.splice(i, 1); }
        },
        dispatchEvent: function (event) {
          var arr = __bbRegListeners[event && event.type];
          if (!arr) { return true; }
          arr.slice().forEach(function (l) { try { l(event); } catch (e) {} });
          return !(event && event.defaultPrevented);
        }
      };
      // MetaMask (and other SW bundles compiled via webpack) alias `var a = globalThis.self` and
      // then access `a.serviceWorker.state`. In a real extension service worker, `self` is the
      // ServiceWorkerGlobalScope itself (i.e. self === globalThis), and `self.serviceWorker` is
      // the ServiceWorker descriptor (same as registration.active). Mirror both so bundles that
      // do `globalThis.self.serviceWorker.state` don't crash with "reading 'state' of undefined".
      if (typeof globalThis.self === 'undefined') {
        globalThis.self = globalThis;
      }
      if (typeof globalThis.serviceWorker === 'undefined') {
        globalThis.serviceWorker = __bbSWDescriptor;
      }
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
        // Origin-bearing schemes. The URL spec gives only http/https/ws/wss/ftp/file a tuple origin and
        // makes every other scheme opaque ("null") — but Chrome registers chrome-extension (Firefox
        // moz-extension, Safari safari-web-extension) as a scheme WITH a tuple origin, so an extension
        // page's `location.origin` is "chrome-extension://<id>", not "null". Extensions rely on this:
        // Tampermonkey's background message gate rejects any sender whose `origin` doesn't equal the
        // worker's own `self.location.origin`, so a "null" origin here fails the gate and the popup's
        // loadTree returns empty → blank popup / "unable to load tree". Match Chrome: give the extension
        // schemes a real origin too. (`file:` keeps its spec origin behavior — left out deliberately.)
        var originScheme = ['http:', 'https:', 'ws:', 'wss:', 'ftp:',
          'chrome-extension:', 'moz-extension:', 'safari-web-extension:'].indexOf(this.protocol) >= 0;
        this.origin = (originScheme && this.host) ? (this.protocol + '//' + this.host) : 'null';
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

    // --- Blob / File / FileReader / object URLs --------------------------------------------------
    // JavaScriptCore's headless global ships none of these. The bundled IndexedDB engine
    // (brownbear-indexeddb.js) clones every stored value through typeson's structured-clone, whose
    // Blob/File handlers (a) read the bytes on write via `new XMLHttpRequest()` over
    // `URL.createObjectURL(blob)` and (b) reconstruct them on read via `new File([...])` / `new
    // Blob([...])`. Without these globals, putting a Blob into IndexedDB throws DataCloneError and the
    // engine SILENTLY DROPS the whole record — which is why a userscript manager (ScriptCat) reported
    // "no data found" after importing a script. We provide a minimal, spec-shaped, in-memory
    // implementation that holds bytes as a Uint8Array. This is NOT a network or filesystem surface:
    // XMLHttpRequest here resolves ONLY `blob:` URLs minted by createObjectURL in THIS JSContext, so
    // it opens no new trust boundary (CLAUDE.md §5) — an unknown scheme fails closed (status 0).

    // Flatten a BlobPart sequence (string | ArrayBuffer | ArrayBufferView | Blob) into one Uint8Array.
    var __bbFlattenBlobParts = function (parts) {
      var src = (parts == null) ? [] : parts;
      if (typeof src.length !== 'number') { src = [src]; }
      var chunks = [], total = 0, i;
      for (i = 0; i < src.length; i++) {
        var p = src[i], b;
        if (p == null) { b = new Uint8Array(0); }
        else if (globalThis.Blob && p instanceof globalThis.Blob) { b = p._bbBytes ? p._bbBytes.slice() : new Uint8Array(0); }
        else if (p instanceof ArrayBuffer) { b = new Uint8Array(p.slice(0)); }
        else if (ArrayBuffer.isView(p)) { b = new Uint8Array(p.buffer.slice(p.byteOffset, p.byteOffset + p.byteLength)); }
        else { b = (new globalThis.TextEncoder()).encode(String(p)); }   // strings → UTF-8, per the Blob spec
        chunks.push(b); total += b.length;
      }
      var out = new Uint8Array(total), off = 0;
      for (i = 0; i < chunks.length; i++) { out.set(chunks[i], off); off += chunks[i].length; }
      return out;
    };
    // bytes → a binary string (one char per byte, charCodeAt === byte); chunked to dodge arg-count limits.
    var __bbBytesToBinaryString = function (bytes) {
      var s = '', CHUNK = 0x8000;
      for (var i = 0; i < bytes.length; i += CHUNK) {
        s += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + CHUNK, bytes.length)));
      }
      return s;
    };

    // DOMException — a Web/DOM global JSC does NOT provide (it's not an ECMAScript builtin). The shim
    // already reaches for `globalThis.DOMException` in several places (AbortError, structuredClone's
    // DataCloneError) and falls back to Error, but bundles that REFERENCE the constructor directly —
    // core-js's web.dom-exception module does `DOMException.prototype` at install (Proton Pass) — throw
    // "Cannot read properties of undefined (reading 'prototype')" when it's absent. Provide a spec-ish
    // DOMException with the legacy error-code table so `e.code`/`e.name`/`instanceof Error` all hold.
    if (typeof globalThis.DOMException !== 'function') {
      var DOM_EXC_CODES = {
        IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4, InvalidCharacterError: 5,
        NoModificationAllowedError: 7, NotFoundError: 8, NotSupportedError: 9, InUseAttributeError: 10,
        InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13, NamespaceError: 14,
        InvalidAccessError: 15, SecurityError: 18, NetworkError: 19, AbortError: 20, URLMismatchError: 21,
        QuotaExceededError: 22, TimeoutError: 23, InvalidNodeTypeError: 24, DataCloneError: 25
      };
      var BBDOMException = function (message, name) {
        var err = Error.call(this, message === undefined ? '' : String(message));
        this.message = message === undefined ? '' : String(message);
        this.name = name === undefined ? 'Error' : String(name);
        this.code = DOM_EXC_CODES[this.name] || 0;
        if (err && err.stack) { this.stack = err.stack; }
      };
      BBDOMException.prototype = Object.create(Error.prototype);
      BBDOMException.prototype.constructor = BBDOMException;
      BBDOMException.prototype.name = 'Error';
      // Legacy numeric code constants live on both the constructor and its prototype (Chrome shape).
      Object.keys(DOM_EXC_CODES).forEach(function (k) {
        var constName = k.replace(/Error$/, '').replace(/([a-z])([A-Z])/g, '$1_$2').toUpperCase() + '_ERR';
        BBDOMException[constName] = DOM_EXC_CODES[k];
        BBDOMException.prototype[constName] = DOM_EXC_CODES[k];
      });
      try { Object.defineProperty(BBDOMException, 'name', { value: 'DOMException' }); } catch (e) { /* non-writable in some engines */ }
      globalThis.DOMException = BBDOMException;
    }

    if (typeof globalThis.Blob !== 'function') {
      var BBBlob = function (parts, options) {
        var opts = options || {};
        this._bbBytes = __bbFlattenBlobParts(parts);
        this.size = this._bbBytes.length;
        this.type = opts.type ? String(opts.type).toLowerCase() : '';
      };
      BBBlob.prototype.arrayBuffer = function () {
        var b = this._bbBytes;
        return Promise.resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
      };
      BBBlob.prototype.text = function () {
        return Promise.resolve((new globalThis.TextDecoder()).decode(this._bbBytes));
      };
      BBBlob.prototype.slice = function (start, end, contentType) {
        var len = this._bbBytes.length;
        var s = (start == null) ? 0 : (start < 0 ? Math.max(len + start, 0) : Math.min(start, len));
        var e = (end == null) ? len : (end < 0 ? Math.max(len + end, 0) : Math.min(end, len));
        var out = new BBBlob([], { type: contentType || '' });
        out._bbBytes = this._bbBytes.slice(s, Math.max(e, s));
        out.size = out._bbBytes.length;
        return out;
      };
      Object.defineProperty(BBBlob.prototype, Symbol.toStringTag, { get: function () { return 'Blob'; } });
      globalThis.Blob = BBBlob;
    }

    if (typeof globalThis.File !== 'function') {
      var BBFile = function (parts, name, options) {
        globalThis.Blob.call(this, parts, options);
        this.name = String(name == null ? '' : name);
        var opts = options || {};
        this.lastModified = (typeof opts.lastModified === 'number') ? opts.lastModified : Date.now();
      };
      BBFile.prototype = Object.create(globalThis.Blob.prototype);
      BBFile.prototype.constructor = BBFile;
      Object.defineProperty(BBFile.prototype, Symbol.toStringTag, { get: function () { return 'File'; } });
      globalThis.File = BBFile;
    }

    // Object-URL registry: createObjectURL mints an opaque blob: URL bound to the Blob's bytes; the
    // minimal XMLHttpRequest below resolves those (and only those) synchronously.
    if (!globalThis.__bbObjectURLs) { globalThis.__bbObjectURLs = {}; }
    var __bbObjURLSeq = 0;
    if (globalThis.URL && typeof globalThis.URL.createObjectURL !== 'function') {
      globalThis.URL.createObjectURL = function (blob) {
        var id = 'blob:' + (baseURL || 'null') + '__bbobj-' + (++__bbObjURLSeq);
        globalThis.__bbObjectURLs[id] = blob;
        return id;
      };
      globalThis.URL.revokeObjectURL = function (url) {
        if (url && Object.prototype.hasOwnProperty.call(globalThis.__bbObjectURLs, url)) {
          delete globalThis.__bbObjectURLs[url];
        }
      };
    }

    // XMLHttpRequest — enough for extensions' real network use (Violentmonkey's GM_xmlhttpRequest) AND
    // the IndexedDB structured-clone path. http(s) requests go through the native-backed, host-permission
    // gated `fetch` (ASYNC only — a service worker has no synchronous network primitive). `blob:` URLs
    // minted by URL.createObjectURL resolve synchronously from their bytes (fake-indexeddb's clone
    // handler relies on this with a synchronous open()). overrideMimeType('…charset=x-user-defined')
    // yields a byte-preserving responseText (that handler's contract); otherwise responseText is decoded
    // text. responseType '', 'text', 'json', 'arraybuffer', and 'blob' are honored.
    if (typeof globalThis.XMLHttpRequest !== 'function') {
      var BBXHR = function () {
        this.readyState = 0; this.status = 0; this.statusText = '';
        this.responseText = ''; this.response = null; this.responseType = '';
        this.responseURL = ''; this.timeout = 0; this.withCredentials = false;
        this.onreadystatechange = null; this.onload = null; this.onerror = null;
        this.onloadstart = null; this.onloadend = null; this.onprogress = null;
        this.onabort = null; this.ontimeout = null;
        this.upload = { onprogress: null, onload: null, onloadstart: null, onloadend: null, onerror: null,
                        onabort: null, addEventListener: function () {}, removeEventListener: function () {} };
        this._method = 'GET'; this._url = ''; this._async = true; this._mime = '';
        this._reqHeaders = {}; this._respHeaders = {}; this._lst = {};
        this._aborted = false; this._abortFetch = null;
      };
      BBXHR.UNSENT = 0; BBXHR.OPENED = 1; BBXHR.HEADERS_RECEIVED = 2; BBXHR.LOADING = 3; BBXHR.DONE = 4;
      ['UNSENT', 'OPENED', 'HEADERS_RECEIVED', 'LOADING', 'DONE'].forEach(function (k) { BBXHR.prototype[k] = BBXHR[k]; });
      BBXHR.prototype.overrideMimeType = function (m) { this._mime = String(m || '').toLowerCase(); };
      BBXHR.prototype.setRequestHeader = function (k, v) { if (k != null) { this._reqHeaders[String(k)] = String(v); } };
      BBXHR.prototype.getAllResponseHeaders = function () {
        var out = '';
        for (var k in this._respHeaders) {
          if (Object.prototype.hasOwnProperty.call(this._respHeaders, k)) { out += k.toLowerCase() + ': ' + this._respHeaders[k] + '\r\n'; }
        }
        return out;
      };
      BBXHR.prototype.getResponseHeader = function (n) {
        n = String(n).toLowerCase();
        for (var k in this._respHeaders) {
          if (Object.prototype.hasOwnProperty.call(this._respHeaders, k) && k.toLowerCase() === n) { return this._respHeaders[k]; }
        }
        return null;
      };
      BBXHR.prototype.addEventListener = function (type, fn) { if (typeof fn === 'function') { (this._lst[type] = this._lst[type] || []).push(fn); } };
      BBXHR.prototype.removeEventListener = function (type, fn) { var a = this._lst[type]; if (!a) { return; } var i = a.indexOf(fn); if (i >= 0) { a.splice(i, 1); } };
      BBXHR.prototype._emit = function (type, extra) {
        var ev = { type: type, target: this, currentTarget: this, lengthComputable: false, loaded: 0, total: 0 };
        if (extra) { for (var ek in extra) { ev[ek] = extra[ek]; } }
        var on = (type === 'readystatechange') ? this.onreadystatechange : this['on' + type];
        if (typeof on === 'function') { try { on.call(this, ev); } catch (e) { /* handler error */ } }
        var a = this._lst[type];
        if (a) { for (var i = 0; i < a.length; i++) { try { a[i].call(this, ev); } catch (e2) { /* listener error */ } } }
      };
      BBXHR.prototype.open = function (method, url, async) {
        this._method = String(method || 'GET').toUpperCase();
        this._url = String(url || '');
        this._async = (async === undefined) ? true : !!async;
        this._reqHeaders = {}; this._respHeaders = {}; this._aborted = false; this._abortFetch = null;
        this.status = 0; this.statusText = ''; this.responseText = ''; this.response = null; this.responseURL = '';
        this.readyState = 1; this._emit('readystatechange');
      };
      BBXHR.prototype.abort = function () {
        this._aborted = true;
        if (typeof this._abortFetch === 'function') { try { this._abortFetch(); } catch (e) { /* ignore */ } }
        if (this.readyState > 0 && this.readyState < 4) {
          this.status = 0; this.readyState = 4; this._emit('readystatechange'); this._emit('abort'); this._emit('loadend');
        }
        this.readyState = 0;
      };
      BBXHR.prototype._deliver = function (status, statusText, headersObj, bytes, finalURL) {
        if (this._aborted) { return; }
        this.status = status; this.statusText = statusText || '';
        this._respHeaders = headersObj || {};
        this.responseURL = finalURL || this._url;
        var rt = this.responseType || '';
        if (rt === '' || rt === 'text') {
          // x-user-defined → byte-preserving string (the fake-indexeddb clone contract); else decoded text.
          this.responseText = (this._mime.indexOf('x-user-defined') >= 0)
            ? __bbBytesToBinaryString(bytes) : (new globalThis.TextDecoder()).decode(bytes);
          this.response = this.responseText;
        } else if (rt === 'json') {
          try { this.response = JSON.parse((new globalThis.TextDecoder()).decode(bytes)); } catch (e) { this.response = null; }
        } else if (rt === 'arraybuffer') {
          this.response = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        } else if (rt === 'blob') {
          this.response = (typeof globalThis.Blob === 'function')
            ? new globalThis.Blob([bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)],
                                  { type: this.getResponseHeader('content-type') || '' })
            : null;
        } else {
          this.responseText = (new globalThis.TextDecoder()).decode(bytes); this.response = this.responseText;
        }
        this.readyState = 2; this._emit('readystatechange');
        this.readyState = 3; this._emit('readystatechange');
        this._emit('progress', { lengthComputable: false, loaded: bytes.length, total: 0 });
        this.readyState = 4; this._emit('readystatechange');
        this._emit('load'); this._emit('loadend');
      };
      BBXHR.prototype._fail = function () {
        if (this._aborted) { return; }
        this.status = 0; this.statusText = ''; this.readyState = 4;
        this._emit('readystatechange'); this._emit('error'); this._emit('loadend');
      };
      BBXHR.prototype.send = function (body) {
        var self = this;
        self._emit('loadstart');
        // blob: object URL — resolve synchronously from its bytes (the fake-indexeddb clone path opens it
        // synchronously; a userscript may XHR an object URL too).
        if (Object.prototype.hasOwnProperty.call(globalThis.__bbObjectURLs, self._url)) {
          var b = globalThis.__bbObjectURLs[self._url];
          var runBlob = function () {
            if (self._aborted) { return; }
            if (b && b._bbBytes) { self._deliver(200, 'OK', b.type ? { 'content-type': b.type } : {}, b._bbBytes, self._url); }
            else { self._fail(); }
          };
          if (self._async && typeof queueMicrotask === 'function') { queueMicrotask(runBlob); } else { runBlob(); }
          return;
        }
        // http(s) — ASYNC only, via the native-backed (host-permission gated) fetch.
        if (!self._async || typeof globalThis.fetch !== 'function') { self._fail(); return; }
        var controller = (typeof globalThis.AbortController === 'function') ? new globalThis.AbortController() : null;
        if (controller) { self._abortFetch = function () { controller.abort(); }; }
        var timer = null;
        if (self.timeout > 0 && typeof setTimeout === 'function') {
          timer = setTimeout(function () {
            if (self._aborted || self.readyState >= 4) { return; }
            self._aborted = true; if (controller) { controller.abort(); }
            self.status = 0; self.readyState = 4; self._emit('readystatechange'); self._emit('timeout'); self._emit('loadend');
          }, self.timeout);
        }
        var init = { method: self._method, headers: self._reqHeaders };
        if (body != null && self._method !== 'GET' && self._method !== 'HEAD') { init.body = body; }
        if (controller) { init.signal = controller.signal; }
        globalThis.fetch(self._url, init).then(function (resp) {
          if (timer) { clearTimeout(timer); }
          if (self._aborted) { return undefined; }
          var headersObj = {};
          if (resp.headers && typeof resp.headers.forEach === 'function') { resp.headers.forEach(function (v, k) { headersObj[k] = v; }); }
          return resp.arrayBuffer().then(function (ab) {
            if (self._aborted) { return; }
            self._deliver(resp.status, resp.statusText, headersObj, new Uint8Array(ab), resp.url);
          });
        }).catch(function () {
          if (timer) { clearTimeout(timer); }
          self._fail();
        });
      };
      globalThis.XMLHttpRequest = BBXHR;
    }

    if (typeof globalThis.FileReader !== 'function') {
      var BBFileReader = function () {
        this.readyState = 0; this.result = null; this.error = null;
        this.onloadstart = null; this.onprogress = null; this.onload = null;
        this.onloadend = null; this.onerror = null; this.onabort = null;
        this._lst = { loadstart: [], progress: [], load: [], loadend: [], error: [], abort: [] };
      };
      BBFileReader.EMPTY = 0; BBFileReader.LOADING = 1; BBFileReader.DONE = 2;
      BBFileReader.prototype.addEventListener = function (type, fn) {
        if (this._lst[type]) { this._lst[type].push(fn); }
      };
      BBFileReader.prototype.removeEventListener = function (type, fn) {
        var a = this._lst[type]; if (!a) { return; }
        var i = a.indexOf(fn); if (i >= 0) { a.splice(i, 1); }
      };
      BBFileReader.prototype._fire = function (type, ev) {
        // Spec progress events expose `target`/`currentTarget` = the FileReader. The canonical read
        // pattern is `reader.onload = e => e.target.result`; without `target` that yields undefined.
        // Tampermonkey's blob→text decoder does exactly `ev.target ? resolve(ev.target.result) : reject(...)`,
        // so a missing target made every blob decode REJECT → an imported .user.js parsed to an empty
        // source → "Unable to parse this!". Backfill here so all dispatches (load/error/loadend) carry it.
        if (ev && ev.target === undefined) { ev.target = this; ev.currentTarget = this; }
        if (typeof this['on' + type] === 'function') { this['on' + type](ev); }
        var a = this._lst[type] || [];
        for (var i = 0; i < a.length; i++) { try { a[i].call(this, ev); } catch (e) { /* listener error */ } }
      };
      // A ProgressEvent-shaped event whose target is the reader (so `e.target.result`, `e.loaded`,
      // `e.total` all read correctly).
      BBFileReader.prototype._event = function (type, total) {
        var n = total || 0;
        return { type: type, target: this, currentTarget: this, lengthComputable: true, loaded: n, total: n };
      };
      BBFileReader.prototype._read = function (blob, produce) {
        var self = this;
        self.readyState = 1;
        self._fire('loadstart', self._event('loadstart', blob && blob._bbBytes ? blob._bbBytes.length : 0));
        var go = function () {
          try {
            if (!blob || !blob._bbBytes) { throw new TypeError('FileReader: argument is not a Blob'); }
            self.result = produce(blob._bbBytes, blob.type);
            self.readyState = 2;
            self._fire('progress', self._event('progress', blob._bbBytes.length));
            self._fire('load', self._event('load', blob._bbBytes.length));
          } catch (e) {
            self.error = e; self.result = null; self.readyState = 2;
            self._fire('error', self._event('error', 0));
          }
          self._fire('loadend', self._event('loadend', self.error ? 0 : (blob && blob._bbBytes ? blob._bbBytes.length : 0)));
        };
        if (typeof queueMicrotask === 'function') { queueMicrotask(go); } else { go(); }
      };
      BBFileReader.prototype.readAsArrayBuffer = function (blob) {
        this._read(blob, function (b) { return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); });
      };
      BBFileReader.prototype.readAsBinaryString = function (blob) {
        this._read(blob, function (b) { return __bbBytesToBinaryString(b); });
      };
      BBFileReader.prototype.readAsText = function (blob) {
        this._read(blob, function (b) { return (new globalThis.TextDecoder()).decode(b); });
      };
      BBFileReader.prototype.readAsDataURL = function (blob) {
        this._read(blob, function (b, type) {
          return 'data:' + (type || 'application/octet-stream') + ';base64,' + globalThis.btoa(__bbBytesToBinaryString(b));
        });
      };
      BBFileReader.prototype.abort = function () {};
      globalThis.FileReader = BBFileReader;
    }

    // The service worker's own location IS its SCRIPT URL (e.g. .../background.js), NOT the bare origin.
    // Webpack-bundled SWs read `location.href.includes("background")` to tell SW-vs-page context and
    // branch (call a service directly vs sendMessage to "the background"); given only the origin, every
    // module thinks it is a page and messages itself → "Receiving end does not exist" (Browsec). Use the
    // manifest's background entry (MV3 service_worker, or an MV2 background page), default background.js.
    if (typeof globalThis.location === 'undefined') {
      var __bbBgEntry = (manifest && manifest.background
        && (manifest.background.service_worker || manifest.background.page)) || 'background.js';
      try {
        globalThis.location = new globalThis.URL((baseURL || 'chrome-extension://invalid/')
          + String(__bbBgEntry).replace(/^\//, ''));
      } catch (e) { /* leave undefined */ }
    }

    // WorkerGlobalScope.origin — a real service worker exposes `origin` as a bare global (=== the
    // tuple location.origin, e.g. "chrome-extension://<id>"), not only as location.origin. Bundled
    // libraries read `self.origin` directly (origin checks, URL construction); without it they see
    // `undefined` and either throw or compare against the literal "undefined". Mirror Chrome.
    if (typeof globalThis.origin === 'undefined' && globalThis.location
        && typeof globalThis.location.origin === 'string') {
      try { globalThis.origin = globalThis.location.origin; } catch (e) { /* leave undefined */ }
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

    // structuredClone — real service workers have it; a bare JSContext does not, so an MV3 worker
    // (or a bundled library it pulls in) that deep-clones with it throws "Can't find variable:
    // structuredClone". Spec-ish deep clone covering Date/RegExp/ArrayBuffer/TypedArray/Map/Set/Array/
    // plain object + circular refs; throws DataCloneError on functions/symbols.
    if (typeof globalThis.structuredClone !== 'function') {
      globalThis.structuredClone = function structuredClone(value) {
        var seen = (typeof Map === 'function') ? new Map() : null;
        function fail() {
          var C = globalThis.DOMException || Error;
          try { return new C("Failed to execute 'structuredClone': value could not be cloned.", 'DataCloneError'); }
          catch (e) { return new Error('DataCloneError'); }
        }
        function clone(v) {
          if (v === null || typeof v !== 'object') {
            if (typeof v === 'function' || typeof v === 'symbol') { throw fail(); }
            return v;
          }
          if (seen && seen.has(v)) { return seen.get(v); }
          if (v instanceof Date) { return new Date(v.getTime()); }
          if (v instanceof RegExp) { return new RegExp(v.source, v.flags); }
          if (typeof ArrayBuffer === 'function' && v instanceof ArrayBuffer) {
            var b = v.slice(0); if (seen) { seen.set(v, b); } return b;
          }
          if (typeof ArrayBuffer === 'function' && ArrayBuffer.isView(v)) {
            var buf = clone(v.buffer);
            var view = (typeof DataView === 'function' && v instanceof DataView)
              ? new DataView(buf, v.byteOffset, v.byteLength)
              : new v.constructor(buf, v.byteOffset, v.length);
            if (seen) { seen.set(v, view); } return view;
          }
          if (Array.isArray(v)) {
            var arr = []; if (seen) { seen.set(v, arr); }
            for (var i = 0; i < v.length; i++) { arr[i] = clone(v[i]); }
            return arr;
          }
          if (typeof Map === 'function' && v instanceof Map) {
            var m = new Map(); if (seen) { seen.set(v, m); }
            v.forEach(function (val, key) { m.set(clone(key), clone(val)); });
            return m;
          }
          if (typeof Set === 'function' && v instanceof Set) {
            var s = new Set(); if (seen) { seen.set(v, s); }
            v.forEach(function (val) { s.add(clone(val)); });
            return s;
          }
          var o = {}; if (seen) { seen.set(v, o); }
          for (var k in v) { if (Object.prototype.hasOwnProperty.call(v, k)) { o[k] = clone(v[k]); } }
          return o;
        }
        return clone(value);
      };
    }

    // navigator — a (reduced) navigator exists in real service workers; extensions read
    // userAgent/language/onLine/hardwareConcurrency. JSC provides none, so a bare reference throws
    // "Can't find variable: navigator". Honest values come from native (__bbUserAgent/__bbLanguage)
    // with a static Mobile-Safari fallback.
    if (typeof globalThis.navigator === 'undefined') {
      var _ua = (typeof globalThis.__bbUserAgent === 'string' && globalThis.__bbUserAgent)
        ? globalThis.__bbUserAgent
        : 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
          + '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      var _lang = (typeof globalThis.__bbLanguage === 'string' && globalThis.__bbLanguage)
        ? globalThis.__bbLanguage : 'en-US';
      var _platform = _ua.indexOf('iPad') >= 0 ? 'iPad' : (_ua.indexOf('iPhone') >= 0 ? 'iPhone' : 'MacIntel');
      var _langs = [_lang];
      var _langBase = _lang.split('-')[0];
      if (_langBase && _langBase !== _lang) { _langs.push(_langBase); }
      globalThis.navigator = {
        userAgent: _ua,
        appVersion: _ua.replace(/^Mozilla\//, ''),
        appName: 'Netscape', appCodeName: 'Mozilla',
        product: 'Gecko', productSub: '20030107',
        vendor: 'Apple Computer, Inc.', vendorSub: '',
        platform: _platform,
        language: _lang, languages: _langs,
        onLine: true, cookieEnabled: true,
        doNotTrack: null, webdriver: false,
        hardwareConcurrency: 4, maxTouchPoints: 5,
        pdfViewerEnabled: false,
        sendBeacon: function () { return false; },
        javaEnabled: function () { return false; }
      };
    }

    // BroadcastChannel — uBO's scriptlet-filtering.js does `new self.BroadcastChannel('uBO')` at module
    // eval; its absence ("undefined is not a constructor") aborts the module graph. Same-context
    // loopback: channels with one name reach each other inside THIS worker; cross-context fan-out
    // (worker ↔ extension pages) is not bridged — uBO uses the channel for diagnostics traffic, and a
    // silent channel degrades cleanly where a missing constructor kills boot.
    if (typeof globalThis.BroadcastChannel === 'undefined') {
      (function () {
        var channelsByName = Object.create(null);
        function BroadcastChannel(name) {
          this.name = String(name);
          this.onmessage = null;
          this.onmessageerror = null;
          this._listeners = [];
          this._closed = false;
          (channelsByName[this.name] = channelsByName[this.name] || []).push(this);
        }
        BroadcastChannel.prototype.postMessage = function (message) {
          var peers = channelsByName[this.name] || [];
          for (var i = 0; i < peers.length; i++) {
            var peer = peers[i];
            if (peer === this || peer._closed) { continue; }
            (function (p) {
              setTimeout(function () {
                var event = { data: message, type: 'message' };
                try { if (typeof p.onmessage === 'function') { p.onmessage(event); } } catch (e) {}
                for (var j = 0; j < p._listeners.length; j++) { try { p._listeners[j](event); } catch (e) {} }
              }, 0);
            })(peer);
          }
        };
        BroadcastChannel.prototype.addEventListener = function (type, fn) {
          if (type === 'message' && typeof fn === 'function') { this._listeners.push(fn); }
        };
        BroadcastChannel.prototype.removeEventListener = function (type, fn) {
          var i = this._listeners.indexOf(fn);
          if (i >= 0) { this._listeners.splice(i, 1); }
        };
        BroadcastChannel.prototype.close = function () {
          this._closed = true;
          var peers = channelsByName[this.name] || [];
          var i = peers.indexOf(this);
          if (i >= 0) { peers.splice(i, 1); }
        };
        globalThis.BroadcastChannel = BroadcastChannel;
      })();
    }

    // CSS.supports — uBO's vapi-common.js:179 calls CSS.supports('selector(a:has(b))') to detect
    // native :has() support at background startup. JSC's headless global has no CSS object, so a
    // bare `CSS.supports(...)` throws "Can't find variable: CSS" and aborts the entire module graph.
    // Returning false is correct: headless JSC has no CSS engine, so no native :has() support.
    if (typeof globalThis.CSS === 'undefined') {
      globalThis.CSS = {
        supports: function () { return false; },
        escape: function (v) { return String(v == null ? '' : v).replace(/[ ]/g, '�').replace(/[^a-zA-Z0-9_-￿]/g, function (c) { var code = c.charCodeAt(0); if (code === 0) { return '�'; } return '\\' + c; }); }
      };
    }

    // requestAnimationFrame / cancelAnimationFrame — vapi-common.js uses these in vAPI.defer.Client
    // (.onvsync, .offon with zero delay). JSC has no animation loop; stub as setTimeout(fn,16) so a
    // caller gets a real callback on a later tick without blocking (matches the 60fps intent closely
    // enough for extension background logic, which doesn't actually animate).
    if (typeof globalThis.requestAnimationFrame !== 'function') {
      globalThis.requestAnimationFrame = function (fn) { return setTimeout(function () { if (typeof fn === 'function') { fn(Date.now()); } }, 16); };
      globalThis.cancelAnimationFrame = function (id) { clearTimeout(id); };
    }

    // requestIdleCallback / cancelIdleCallback — vapi-common.js uses these in vAPI.defer.Client.onidle.
    // JSC has no idle-period scheduler; stub as a deferred setTimeout that delivers a synthetic
    // IdleDeadline (50ms budget, didTimeout based on elapsed vs options.timeout) so the callback
    // always fires and the deadline object is spec-shaped.
    if (typeof globalThis.requestIdleCallback !== 'function') {
      globalThis.requestIdleCallback = function (fn, opts) {
        var timeout = (opts && typeof opts.timeout === 'number') ? opts.timeout : 50;
        var start = Date.now();
        return setTimeout(function () {
          if (typeof fn !== 'function') { return; }
          var elapsed = Date.now() - start;
          fn({ timeRemaining: function () { return Math.max(0, 50 - elapsed); }, didTimeout: elapsed >= timeout });
        }, timeout);
      };
      globalThis.cancelIdleCallback = function (id) { clearTimeout(id); };
    }

    // HTMLDocument / XMLDocument / Element — vapi.js (the MV2 classic prelude loaded before the ESM
    // graph) checks `document instanceof HTMLDocument` to determine whether it is running in a content
    // page context. In Chrome's real background page, document IS an HTMLDocument, so the check
    // passes and vAPI = { uBO: true } is initialized — which vapi-common.js then requires on its
    // first line (`vAPI.T0 = Date.now()`). In JSC, document is our stub and these DOM constructors
    // don't exist, so the instanceof check returns false (if it doesn't throw first) and vAPI stays
    // undefined, causing "Cannot set properties of undefined" in vapi-common.js. Providing the
    // constructors (even as empty functions) lets the check succeed and vAPI be initialized.
    if (typeof globalThis.HTMLDocument !== 'function') { globalThis.HTMLDocument = function HTMLDocument() {}; }
    if (typeof globalThis.XMLDocument !== 'function') { globalThis.XMLDocument = function XMLDocument() {}; }
    if (typeof globalThis.Element !== 'function') { globalThis.Element = function Element() {}; }
    if (typeof globalThis.HTMLDivElement !== 'function') { globalThis.HTMLDivElement = function HTMLDivElement() {}; }
    // Set our stub document's prototype so `document instanceof HTMLDocument` returns true,
    // matching Chrome's background page semantics and allowing vAPI to initialize.
    if (globalThis.document && globalThis.HTMLDocument &&
        !(globalThis.document instanceof globalThis.HTMLDocument)) {
      try { Object.setPrototypeOf(globalThis.document, globalThis.HTMLDocument.prototype); } catch (e) {}
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
    // Every method supports BOTH the callback form and (MV3) the promise form — returning a Promise when
    // no callback is passed. Without this, `await chrome.storage.local.get(...)` resolved to undefined,
    // and timeout-wrapped reads (e.g. Grammarly's chrome.storage.managed.get) never settled.
    return {
      get: function (keys, cb) {
        var defaults = null;
        var keyList = null;
        if (typeof keys === 'function') { cb = keys; keyList = null; }
        else if (keys === null || keys === undefined) { keyList = null; }
        else if (typeof keys === 'string') { keyList = [keys]; }
        else if (Array.isArray(keys)) { keyList = keys.slice(); }
        else if (typeof keys === 'object') { defaults = keys; keyList = Object.keys(keys); }
        return new Promise(function (resolve) {
          __bb_storage_get(areaName, keyList === null ? 'null' : JSON.stringify(keyList), function (resJSON) {
            var raw = parseJSON(resJSON) || {};      // key -> JSON-encoded value
            var out = {};
            if (defaults) { for (var dk in defaults) { if (Object.prototype.hasOwnProperty.call(defaults, dk)) { out[dk] = deepClone(defaults[dk]); } } }
            for (var k in raw) { if (Object.prototype.hasOwnProperty.call(raw, k)) { out[k] = parseJSON(raw[k]); } }
            if (typeof cb === 'function') { cb(out); }
            resolve(out);
          });
        });
      },
      getBytesInUse: function (keys, cb) {
        if (typeof keys === 'function') { cb = keys; }
        // We don't track byte usage; report 0 (Chrome allows an approximate/zero value).
        if (typeof cb === 'function') { cb(0); return undefined; }
        return Promise.resolve(0);
      },
      set: function (items, cb) {
        var enc = {};
        var _keys = [];
        for (var k in items) {
          if (Object.prototype.hasOwnProperty.call(items, k)) {
            enc[k] = JSON.stringify(items[k]);
            // A value that can't round-trip JSON (undefined, a function, a Blob, a circular ref) silently
            // drops here, which would make a "successful" save persist nothing — flag it.
            if (enc[k] === undefined) { _keys.push(k + '=UNSERIALIZABLE'); } else { _keys.push(k); }
          }
        }
        // Diagnostic: name the keys a worker writes to persistent storage (local/sync), so a save that
        // reports success but never appears (Tampermonkey) can be told apart from one that never wrote.
        if ((areaName === 'local' || areaName === 'sync') && typeof __bb_log === 'function') {
          __bb_log('debug', '[bb-storage] ' + areaName + '.set [' + _keys.join(',').slice(0, 200) + ']');
        }
        return new Promise(function (resolve) {
          __bb_storage_set(areaName, JSON.stringify(enc), function () { if (typeof cb === 'function') { cb(); } resolve(); });
        });
      },
      remove: function (keys, cb) {
        var list = Array.isArray(keys) ? keys : [keys];
        return new Promise(function (resolve) {
          __bb_storage_remove(areaName, JSON.stringify(list), function () { if (typeof cb === 'function') { cb(); } resolve(); });
        });
      },
      clear: function (cb) {
        return new Promise(function (resolve) {
          __bb_storage_clear(areaName, function () { if (typeof cb === 'function') { cb(); } resolve(); });
        });
      },
      // chrome.storage.session.setAccessLevel: controls content-script visibility of session storage.
      // BrownBear doesn't expose a separate untrusted tier, so this is a no-op that resolves — its
      // absence threw "setAccessLevel is not a function" for extensions that call it on boot.
      setAccessLevel: function (_opts, cb) {
        if (typeof cb === 'function') { cb(); return undefined; }
        return Promise.resolve();
      },
      // Per-area StorageArea.onChanged (Chrome 73+): listener gets (changes) for THIS area only —
      // fanned from the same native push as the global storage.onChanged (see dispatchStorageChanged).
      // The content world has had this since #174; the worker needs it too (uBO Lite reads it).
      onChanged: makeEvent(areaStorageListeners[areaName] || (areaStorageListeners[areaName] = []))
    };
  }

  // Per-area StorageArea.onChanged listeners (local/sync/session/managed).
  var areaStorageListeners = {};
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
    // Named placeholders ($name$ → declared content, e.g. "$1") resolve BEFORE positional args; without
    // this a message like "$NAME$ $VERSION$ is available" leaks the literal tokens. Unknown left as-is.
    var ph = i18nPlaceholders[key];
    if (ph) {
      message = message.replace(/\$([A-Za-z0-9_@]+)\$/g, function (whole, name) {
        var content = ph[name.toLowerCase()];
        return (typeof content === 'string') ? content : whole;
      });
    }
    // Positional substitutions ($1..$9) + the $$ escape — only when args are supplied (a literal "$5"
    // with no substitutions stays intact, matching Chrome).
    if (substitutions !== null && substitutions !== undefined) {
      var subs = Array.isArray(substitutions) ? substitutions : [substitutions];
      message = message.replace(/\$([1-9])\$?|\$\$/g, function (m, d) {
        if (m === '$$') { return '$'; }
        var index = parseInt(d, 10) - 1;
        return (index >= 0 && index < subs.length && subs[index] != null) ? subs[index] : '';
      });
    }
    return message;
  }
  // The device UI language (BCP-47, e.g. "en-US"), from native. chrome.i18n.getUILanguage returns it;
  // getAcceptLanguages derives a short ordered list (["en-US","en"]) from it.
  function uiLanguage() {
    return (typeof globalThis.__bbLanguage === 'string' && globalThis.__bbLanguage) ? globalThis.__bbLanguage : 'en-US';
  }
  function acceptLanguages() {
    var lang = uiLanguage();
    var base = lang.indexOf('-') >= 0 ? lang.split('-')[0] : null;
    return base && base !== lang ? [lang, base] : [lang];
  }
  var i18n = {
    getMessage: getMessage,
    getUILanguage: function () { return uiLanguage(); },
    getAcceptLanguages: function (cb) {
      var langs = acceptLanguages();
      if (typeof cb === 'function') { cb(langs); return undefined; }
      return Promise.resolve(langs);   // MV3 Promise form
    },
    // chrome.i18n.detectLanguage — native NLLanguageRecognizer (returns the dominant languages of `text`
    // with confidence percentages, matching Chrome's CLD shape).
    detectLanguage: function (text, cb) {
      var p = new Promise(function (resolve) {
        __bb_i18n_detect(String(text == null ? '' : text), function (resJSON) {
          var r = parseJSON(resJSON);
          resolve(r && r.languages ? r : { isReliable: false, languages: [] });
        });
      });
      if (typeof cb === 'function') { p.then(function (v) { cb(v); }); return undefined; }
      return p;
    }
  };

  // ---------------------------------------------------------------- chrome.runtime

  var messageListeners = [];
  var installedListeners = [];
  var startupListeners = [];
  // chrome.runtime.onUserScriptMessage / onUserScriptConnect — the MV3 User Scripts messaging channel
  // (Chrome 120+). A USER_SCRIPT-world script (configureWorld({messaging:true})) talks to the worker over
  // THIS channel, kept separate from onMessage/onConnect so the worker can distinguish privileged content
  // scripts from user scripts. ScriptCat/Tampermonkey require these to run injected scripts.
  var userScriptMessageListeners = [];
  var userScriptConnectListeners = [];

  // chrome.runtime.connect / onConnect long-lived ports — RESPONDER side. A content script or page
  // connects; the hub fires dispatchPortConnect here; the worker replies via the __bb_port_* natives.
  // Ports are addressed by the unguessable id the hub minted, so the worker needs no token.
  var connectListeners = [];
  var ports = Object.create(null);   // portId -> port object
  function makeWorkerPort(portId, name, sender) {
    var msgListeners = [], discListeners = [];
    var disconnected = false;
    var port = {
      name: name || '',
      sender: sender || null,
      onMessage: makeEvent(msgListeners),
      onDisconnect: makeEvent(discListeners),
      postMessage: function (msg) {
        if (disconnected) { return; }
        try { __bb_port_post(portId, JSON.stringify(msg === undefined ? null : msg)); } catch (e) {}
      },
      disconnect: function () {
        if (disconnected) { return; }
        disconnected = true;
        try { __bb_port_disconnect(portId); } catch (e) {}
        delete ports[portId];
      }
    };
    port._fireMessage = function (m) {
      for (var i = 0; i < msgListeners.length; i++) {
        try { msgListeners[i](m, port); } catch (e) { __bb_log('error', 'port.onMessage threw: ' + (e && e.message ? e.message : e)); }
      }
    };
    port._fireDisconnect = function () {
      disconnected = true;
      for (var i = 0; i < discListeners.length; i++) { try { discListeners[i](port); } catch (e) {} }
    };
    return port;
  }

  function getURL(path) {
    path = path || '';
    return baseURL + (path.charAt(0) === '/' ? path.slice(1) : path);
  }

  // chrome.runtime.lastError slot for the worker. Settable so the messaging path can populate it before
  // invoking a callback (Chrome calls the callback with lastError set, then clears it), mirroring the
  // page/content runtimes. The Promise form rejects instead.
  var _bbLastError = null;
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
    // chrome.runtime.reload() — Chrome restarts the whole extension (re-evaluates the background).
    // uBO Lite calls it to apply a hard reset. iOS has no live worker-respawn primitive exposed here,
    // so route to the optional native re-boot bridge when present; otherwise it's a safe no-op (the
    // extension keeps running on its current state) rather than an undefined-method throw that aborts
    // whatever code path triggered the reset.
    reload: function () {
      try { if (typeof __bb_runtime_reload === 'function') { __bb_runtime_reload(); } } catch (e) {}
    },
    onMessage: makeEvent(messageListeners),
    onUserScriptMessage: makeEvent(userScriptMessageListeners),
    onUserScriptConnect: makeEvent(userScriptConnectListeners),
    onInstalled: makeEvent(installedListeners),
    onStartup: makeEvent(startupListeners),
    onConnect: makeEvent(connectListeners),
    // chrome.runtime.onConnectExternal / onMessageExternal — fired when a DIFFERENT extension
    // (or a website listed in externally_connectable) opens a port to or sends a message to this
    // extension. Tampermonkey and other script managers register listeners unconditionally at boot;
    // without these event objects the addListener call throws "Cannot read properties of undefined"
    // before any message handlers are installed, leaving the background unable to receive messages.
    onConnectExternal: makeEvent([]),
    onMessageExternal: makeEvent([]),
    // chrome.runtime.onUpdateAvailable — fires when an update to THIS extension is staged, letting a SW
    // delay the reload until idle. onBrowserUpdateAvailable/onRestartRequired are the browser-update
    // twins. No iOS analog (the app updates through the App Store, not a background process), so none of
    // these fire — but they must exist so a background that registers a handler unguarded (Speechify,
    // Mate Translate: runtime.onUpdateAvailable.addListener at boot; Tampermonkey's update watchdog)
    // doesn't throw "Cannot read properties of undefined (reading 'addListener')".
    onUpdateAvailable: makeEvent([]),
    onBrowserUpdateAvailable: makeEvent([]),
    onRestartRequired: makeEvent([]),
    onSuspend: makeEvent([]),
    sendMessage: function () {
      // Accept (extensionId?, message, options?, callback?) — Chrome's overloaded shape. Returns a
      // Promise when no callback is given (MV3), which is how a worker awaits its offscreen document's
      // reply: `const res = await chrome.runtime.sendMessage(...)`.
      var args = Array.prototype.slice.call(arguments);
      var cb = (args.length && typeof args[args.length - 1] === 'function') ? args.pop() : null;
      var message = (typeof args[0] === 'string' && args.length > 1) ? args[1] : args[0];
      var p = new Promise(function (resolve, reject) {
        __bb_send_message(JSON.stringify({ message: (message === undefined ? null : message) }), function (resJSON) {
          var r = parseJSON(resJSON);
          if (r && r.__bbNoReceiver) {
            // No context of this extension had an onMessage listener — Chrome rejects the Promise (and
            // sets lastError for the callback form). Tagged so the callback branch can surface it.
            var err = new Error('Could not establish connection. Receiving end does not exist.');
            err.__bbLastError = true;
            reject(err);
          } else {
            resolve(r ? r.value : undefined);
          }
        });
      });
      if (typeof cb === 'function') {
        p.then(function (v) { cb(v); }, function (e) {
          if (e && e.__bbLastError) { _bbLastError = { message: e.message }; }
          try { cb(undefined); } finally { _bbLastError = null; }
        });
        return undefined;
      }
      return p;
    },
    connect: function (connectInfo) {
      // iOS: the worker has no addressable content/page peer to open a port TOWARD (the hub is
      // client→worker only), so a worker-initiated connect() returns a well-formed but peerless Port
      // whose calls are no-ops — rather than throwing. The reverse direction (content/page → worker,
      // via onConnect above) is fully functional.
      var ci = connectInfo || {};
      return { name: ci.name || '', sender: null,
               onMessage: makeEvent([]), onDisconnect: makeEvent([]),
               postMessage: function () {}, disconnect: function () {} };
    },
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
    getContexts: function (filter, cb) {
      var p = new Promise(function (resolve) {
        __bb_get_contexts(JSON.stringify(filter || {}), function (resJSON) {
          var r = parseJSON(resJSON);
          resolve(Array.isArray(r) ? r : []);
        });
      });
      if (typeof cb === 'function') { p.then(function (v) { cb(v); }); return undefined; }
      return p;
    },
    // chrome.runtime.sendNativeMessage — native app messaging is not available on iOS (no native
    // messaging hosts). Reject clearly so extensions that try it get a diagnosable error instead of
    // a silent undefined call or a hang. The callback form sets lastError and calls back with undefined
    // (Chrome's error semantics); the Promise form rejects.
    sendNativeMessage: function (application, message, cb) {
      var err = { message: 'native messaging is not supported on iOS' };
      if (typeof cb === 'function') {
        _bbLastError = err;
        try { cb(undefined); } finally { _bbLastError = null; }
        return undefined;
      }
      var e = new Error(err.message);
      e.__bbLastError = true;
      return Promise.reject(e);
    },
    // chrome.runtime.connectNative — native messaging port; not available on iOS (no native messaging
    // hosts). Returns a stub port whose onDisconnect fires synchronously with lastError set, matching
    // Chrome's behaviour when the native host is not installed. Extensions (Chrome Remote Desktop) that
    // call connectNative get a non-null port and can add onDisconnect listeners without crashing; they
    // will receive the disconnect event and handle the "not available" condition gracefully.
    connectNative: function (application) {
      var disconnectListeners = [];
      var messageListeners = [];
      var port = {
        name: String(application || ''),
        onMessage: {
          addListener: function (fn) { if (typeof fn === 'function') messageListeners.push(fn); },
          removeListener: function (fn) { var i = messageListeners.indexOf(fn); if (i >= 0) messageListeners.splice(i, 1); },
          hasListener: function (fn) { return messageListeners.indexOf(fn) >= 0; }
        },
        onDisconnect: {
          addListener: function (fn) { if (typeof fn === 'function') disconnectListeners.push(fn); },
          removeListener: function (fn) { var i = disconnectListeners.indexOf(fn); if (i >= 0) disconnectListeners.splice(i, 1); },
          hasListener: function (fn) { return disconnectListeners.indexOf(fn) >= 0; }
        },
        postMessage: function () {},
        disconnect: function () {}
      };
      // Fire onDisconnect asynchronously (next tick) with lastError set — Chrome fires this when
      // the native host is absent. Use a 0ms timer so the caller's addListener runs first.
      __bb_set_timeout(function () {
        _bbLastError = { message: 'native messaging is not supported on iOS' };
        try {
          for (var i = 0; i < disconnectListeners.length; i++) {
            try { disconnectListeners[i](port); } catch (_) {}
          }
        } finally { _bbLastError = null; }
      }, 0, false);
      return port;
    },
    // chrome.runtime.getBrowserInfo — Firefox-originated API that some extensions probe. On Chrome it
    // does not exist; we return a Chrome-shaped no-op so extensions that guard with
    // `chrome.runtime.getBrowserInfo?.()` don't throw "not a function" on a direct call.
    getBrowserInfo: function (cb) {
      var info = { name: 'BrownBear', vendor: 'BrownBear', version: '1.0.0', buildID: '20240101' };
      if (typeof cb === 'function') { cb(info); return undefined; }
      return Promise.resolve(info);
    },
    get lastError() { return _bbLastError; }
  };

  // ---------------------------------------------------------------- assemble + expose

  // chrome.commands — iOS has no global keyboard-shortcut source, so onCommand never fires (an honest
  // platform limit, like chrome.idle's input gaps). But getAll returns the REAL commands declared in the
  // manifest (name/description/active shortcut) so an extension's shortcut UI lists them correctly
  // (Dark Reader's getCommands reads this) instead of seeing an empty set. Chrome resolves suggested_key
  // per platform + honors user rebinding; we have no rebinding, so the active shortcut is the manifest's
  // suggested default (with a platform fallback). update/reset can't rebind a global shortcut on iOS, so
  // they resolve as no-ops (Promise/callback shape preserved) rather than rejecting an extension's UI.
  function manifestCommands() {
    var defs = (manifest && manifest.commands) || {};
    var out = [];
    for (var name in defs) {
      if (!Object.prototype.hasOwnProperty.call(defs, name)) { continue; }
      var d = defs[name] || {};
      var sk = d.suggested_key || {};
      var shortcut = sk.default || sk.mac || sk.chromeos || sk.windows || sk.linux || '';
      out.push({ name: name, description: d.description || '', shortcut: shortcut });
    }
    return out;
  }
  var commands = {
    onCommand: makeEvent([]),
    getAll: function (cb) {
      var list = manifestCommands();
      if (typeof cb === 'function') { cb(list); return undefined; }
      return Promise.resolve(list);
    },
    update: function (details, cb) { if (typeof cb === 'function') { cb(); return undefined; } return Promise.resolve(); },
    reset: function (name, cb) { if (typeof cb === 'function') { cb(); return undefined; } return Promise.resolve(); }
  };

  // chrome.search.query — run a web search via the user's default search engine. Native opens the
  // results tab (honoring disposition CURRENT_TAB/NEW_TAB; NEW_WINDOW → NEW_TAB on single-window iOS).
  // No permission required (matches Chrome). Resolves once the tab op is dispatched.
  var search = {
    query: function (queryInfo, cb) {
      var info = queryInfo || {};
      var payload = {
        text: typeof info.text === 'string' ? info.text : '',
        disposition: typeof info.disposition === 'string' ? info.disposition : null,
        tabId: typeof info.tabId === 'number' ? info.tabId : null
      };
      var p = new Promise(function (resolve) {
        __bb_search(JSON.stringify(payload), function () { resolve(); });
      });
      if (typeof cb === 'function') { p.then(function () { cb(); }); return undefined; }
      return p;
    }
  };

  // chrome.bookmarks / chrome.history / chrome.sessions — read-only views of the user's own bookmarks,
  // visited URLs, and recently-closed tabs, backed natively by BrownBear's stores. Each method is gated
  // on the matching manifest permission natively; a `{__bbError}` reply (missing permission / unsupported)
  // rejects the promise. Vimium calls bookmarks.getTree / history.search / sessions.restore unguarded —
  // these return real Chrome shapes so its Vomnibar + 'u' tab-restore work instead of throwing.
  function browserDataCall(method, args) {
    return new Promise(function (resolve, reject) {
      __bb_browser_data(method, JSON.stringify(args || {}), function (resJSON) {
        var r = parseJSON(resJSON);
        if (r && typeof r === 'object' && typeof r.__bbError === 'string') { reject(new Error(r.__bbError)); }
        else { resolve(r); }
      });
    });
  }
  var bookmarks = {
    getTree: function (cb) { return settleBg(browserDataCall('bookmarks.getTree', {}), cb); },
    // BrownBear's bookmarks are flat; getSubTree returns the full tree (a faithful superset for walkers).
    getSubTree: function (id, cb) { return settleBg(browserDataCall('bookmarks.getTree', {}), cb); },
    search: function (query, cb) {
      var q = typeof query === 'string' ? query : ((query && query.query) || '');
      return settleBg(browserDataCall('bookmarks.search', { query: q }), cb);
    },
    create: function (bookmark, cb) {
      var b = bookmark || {};
      return settleBg(browserDataCall('bookmarks.create', { title: b.title || '', url: b.url || '' }), cb);
    },
    remove: function (id, cb) {
      return settleBg(browserDataCall('bookmarks.remove', { id: String(id) }).then(function () { return undefined; }), cb);
    }
  };
  var historyVisitedListeners = [], historyVisitRemovedListeners = [];
  var history = {
    search: function (query, cb) {
      var info = query || {};
      return settleBg(browserDataCall('history.search', {
        text: typeof info.text === 'string' ? info.text : '',
        maxResults: typeof info.maxResults === 'number' ? info.maxResults : 0
      }), cb);
    },
    addUrl: function (details, cb) {
      var d = details || {};
      return settleBg(browserDataCall('history.addUrl', { url: d.url || '', title: d.title }).then(function () { return undefined; }), cb);
    },
    deleteUrl: function (details, cb) {
      var d = details || {};
      return settleBg(browserDataCall('history.deleteUrl', { url: d.url || '' }).then(function () { return undefined; }), cb);
    },
    deleteRange: function (range, cb) {
      var r = range || {};
      return settleBg(browserDataCall('history.deleteRange', {
        startTime: typeof r.startTime === 'number' ? r.startTime : 0,
        endTime: typeof r.endTime === 'number' ? r.endTime : 0
      }).then(function () { return undefined; }), cb);
    },
    // Real event objects (addListener never throws). They do not fire yet — iOS doesn't push per-visit
    // history changes to the worker — so a consumer relying on incremental updates falls back to search.
    onVisited: makeEvent(historyVisitedListeners),
    onVisitRemoved: makeEvent(historyVisitRemovedListeners)
  };
  var sessions = {
    MAX_SESSION_RESULTS: 25,
    getRecentlyClosed: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(browserDataCall('sessions.getRecentlyClosed', {
        maxResults: (filter && typeof filter.maxResults === 'number') ? filter.maxResults : 0
      }), cb);
    },
    restore: function (sessionId, cb) {
      if (typeof sessionId === 'function') { cb = sessionId; sessionId = null; }
      return settleBg(browserDataCall('sessions.restore', {
        sessionId: typeof sessionId === 'string' ? sessionId : null
      }), cb);
    },
    onChanged: makeEvent([])
  };

  // chrome.idle — iOS can't observe global user input, so queryState maps app/device state via native
  // (locked when data-protected, active when the app is foreground-active, else idle). onStateChanged
  // fires on app foreground/background (and lock/unlock) transitions, pushed from native.
  var idleStateListeners = [];
  var idle = {
    IdleState: { ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked' },
    queryState: function (detectionIntervalInSeconds, cb) {
      var p = new Promise(function (resolve) {
        __bb_idle('queryState', JSON.stringify({ interval: detectionIntervalInSeconds }), function (resJSON) {
          var r = parseJSON(resJSON);
          resolve(typeof r === 'string' ? r : 'active');
        });
      });
      if (typeof cb === 'function') { p.then(function (v) { cb(v); }); return undefined; }
      return p;
    },
    setDetectionInterval: function (intervalInSeconds, cb) {
      __bb_idle('setDetectionInterval', JSON.stringify({ interval: intervalInSeconds }),
        function () { if (typeof cb === 'function') { cb(); } });
    },
    getAutoLockDelay: function (cb) {
      if (typeof cb === 'function') { cb(0); return undefined; }
      return Promise.resolve(0);
    },
    onStateChanged: makeEvent(idleStateListeners)
  };

  // chrome.downloads — native runs the transfer (URLSession) into the app's Downloads folder and fires
  // onCreated/onChanged/onErased back here. The "downloads" permission gate is enforced natively.
  var downloadCreatedListeners = [], downloadChangedListeners = [], downloadErasedListeners = [];
  function downloadsCall(method, args) {
    return new Promise(function (resolve, reject) {
      __bb_downloads(method, JSON.stringify(args || {}), function (resJSON) {
        var r = parseJSON(resJSON) || {};
        if (r.error) { var e = new Error(r.error); e.__bbLastError = true; reject(e); } else { resolve(r); }
      });
    });
  }
  function settleDownloads(promise, cb, pick) {
    var p = promise.then(pick);
    if (typeof cb === 'function') {
      p.then(function (v) { cb(v); }, function (e) {
        if (e && e.__bbLastError) { _bbLastError = { message: e.message }; }
        try { cb(undefined); } finally { _bbLastError = null; }
      });
      return undefined;
    }
    return p;
  }
  var downloads = {
    download: function (options, cb) {
      return settleDownloads(downloadsCall('download', options || {}), cb, function (r) { return r.downloadId; });
    },
    search: function (query, cb) {
      return settleDownloads(downloadsCall('search', query || {}), cb, function (r) { return r.items || []; });
    },
    cancel: function (id, cb) { return settleDownloads(downloadsCall('cancel', { id: id }), cb, function () { return undefined; }); },
    pause: function (id, cb) { return settleDownloads(downloadsCall('pause', { id: id }), cb, function () { return undefined; }); },
    resume: function (id, cb) { return settleDownloads(downloadsCall('resume', { id: id }), cb, function () { return undefined; }); },
    erase: function (query, cb) { return settleDownloads(downloadsCall('erase', query || {}), cb, function (r) { return r.erased || []; }); },
    removeFile: function (id, cb) { return settleDownloads(downloadsCall('removeFile', { id: id }), cb, function () { return undefined; }); },
    // No iOS file-manager surface to drive these — accept and no-op so callers don't throw.
    open: function () {}, show: function () {}, showDefaultFolder: function () {}, setShelfEnabled: function () {},
    acceptDanger: function (id, cb) { if (typeof cb === 'function') { cb(); return undefined; } return Promise.resolve(); },
    onCreated: makeEvent(downloadCreatedListeners),
    onChanged: makeEvent(downloadChangedListeners),
    onErased: makeEvent(downloadErasedListeners)
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
  // chrome.action methods iOS renders trivially: there's one non-per-tab toolbar item, so a distinct badge
  // TEXT color, popup-open state, etc. aren't drawn. These resolve sensible Chrome-shaped defaults locally
  // rather than round-trip to native — they exist so a manager (ScriptCat calls setBadgeTextColor on every
  // badge update) doesn't hit "chrome.action.<x> is not a function" and abort. Overload-tolerant
  // ((details?, cb?) / (cb)). White is Chrome's default badge text color.
  function actionLocalResolve(value) {
    return function (a1, cb) {
      if (typeof a1 === 'function') { cb = a1; }
      if (typeof cb === 'function') { cb(value); return undefined; }
      return Promise.resolve(value);
    };
  }
  // chrome.action color setters accept a CSS string OR a ColorArray [r,g,b,a]. Native stores a hex
  // string, so normalize an array to "#rrggbbaa" here; the badge (rendered in the Quick Look menu) then
  // honors both forms — managers like ScriptCat pass either.
  function cssFromColor(c) {
    if (typeof c === 'string') { return c; }
    if (Array.isArray(c) && c.length === 4) {
      var h = function (n) { var s = ((n | 0) & 255).toString(16); return s.length === 1 ? '0' + s : s; };
      return '#' + h(c[0]) + h(c[1]) + h(c[2]) + h(c[3]);
    }
    return undefined;
  }
  function actionColorSetter(method) {
    return function (details, cb) {
      details = details || {};
      return settleBg(actionCall(method, { tabId: details.tabId, color: cssFromColor(details.color) })
        .then(function () { return undefined; }), cb);
    };
  }
  var action = {
    setBadgeText: actionSetter('setBadgeText'),
    setBadgeBackgroundColor: actionColorSetter('setBadgeBackgroundColor'),
    setBadgeTextColor: actionColorSetter('setBadgeTextColor'),
    setTitle: actionSetter('setTitle'),
    setPopup: actionSetter('setPopup'),
    setIcon: actionSetIcon,
    enable: actionToggle('enable'),
    disable: actionToggle('disable'),
    getBadgeText: actionGetter('getBadgeText'),
    getTitle: actionGetter('getTitle'),
    getBadgeBackgroundColor: actionGetter('getBadgeBackgroundColor'),
    getBadgeTextColor: actionGetter('getBadgeTextColor'),
    getPopup: actionLocalResolve(''),
    isEnabled: actionLocalResolve(true),
    getUserSettings: actionLocalResolve({ isOnToolbar: true }),
    // chrome.action.openPopup([options], cb) — actually present the extension's popup over the page (the
    // toolbar-anchored glassy popover), via the native action bridge, instead of the old silent no-op.
    // Extensions like Grammarly call this to surface their UI programmatically.
    openPopup: function (options, cb) {
      if (typeof options === 'function') { cb = options; options = undefined; }
      var args = (options && typeof options === 'object') ? options : {};
      return settleBg(actionCall('openPopup', args).then(function () { return undefined; }), cb);
    },
    onClicked: makeEvent(actionClickedListeners)
  };

  // chrome.pageAction (MV2): iOS has no per-tab page-action button, so show/hide/isShown are no-ops, but
  // the title/icon/popup setters and onClicked alias chrome.action so an MV2 extension that drives a page
  // action still configures its toolbar item and receives clicks (an extension uses pageAction OR action,
  // not both, so sharing the click listeners is safe).
  var pageAction = {
    show: function (_tabId, cb) { if (typeof cb === 'function') { cb(); return undefined; } return Promise.resolve(); },
    hide: function (_tabId, cb) { if (typeof cb === 'function') { cb(); return undefined; } return Promise.resolve(); },
    isShown: function (_details, cb) { if (typeof cb === 'function') { cb(false); return undefined; } return Promise.resolve(false); },
    setTitle: actionSetter('setTitle'),
    getTitle: actionGetter('getTitle'),
    setIcon: actionSetIcon,
    setPopup: actionSetter('setPopup'),
    getPopup: function (_details, cb) { if (typeof cb === 'function') { cb(''); return undefined; } return Promise.resolve(''); },
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
  // chrome.permissions.onAdded/onRemoved — fired by native (dispatchExtEvent) after a runtime
  // permissions.request grant or permissions.remove, with one {permissions, origins} arg, so an
  // extension can react to optional-permission changes exactly as in Chrome (uBO Lite / Dark Reader).
  var permissionsEventLists = { 'permissions.onAdded': [], 'permissions.onRemoved': [] };
  var tabs = {
    // chrome.tabs.TAB_ID_NONE — the sentinel (-1) for "no tab" (e.g. a SW event not tied to a tab).
    // ScriptCat and others compare against it directly; its absence reads as undefined and a
    // `tabId === chrome.tabs.TAB_ID_NONE` guard silently never matches.
    TAB_ID_NONE: -1,
    query: function (q, cb) { return settleBg(tabsCall('query', { query: q || {} }), cb); },
    // chrome.tabs.detectLanguage([tabId], cb) — Chrome returns the ISO code of the tab's content. iOS has
    // no native page-language detector, so grab a sample of the tab's text via scripting.executeScript and
    // run it through the same NLLanguageRecognizer that backs i18n.detectLanguage, returning the top code
    // ('und' when undetectable). Google Translate calls this; an unguarded call must not throw.
    detectLanguage: function (tabId, cb) {
      if (typeof tabId === 'function') { cb = tabId; tabId = undefined; }
      var p = new Promise(function (resolve) {
        function detect(text) {
          __bb_i18n_detect(String(text || ''), function (resJSON) {
            var r = parseJSON(resJSON);
            var langs = (r && r.languages) || [];
            resolve(langs.length && langs[0].language ? langs[0].language : 'und');
          });
        }
        if (tabId == null) { detect(''); return; }
        try {
          scripting.executeScript({
            target: { tabId: tabId },
            func: function () {
              try { return (document.body && document.body.innerText || '').slice(0, 4000); } catch (e) { return ''; }
            }
          }, function (results) {
            var text = (results && results[0] && typeof results[0].result === 'string') ? results[0].result : '';
            detect(text);
          });
        } catch (e) { detect(''); }
      });
      if (typeof cb === 'function') { p.then(function (v) { cb(v); }); return undefined; }
      return p;
    },
    // chrome.tabs.discard([tabId], cb) — Chrome frees a background tab's memory. iOS/WKWebView has no
    // per-tab suspend, so resolve as a graceful no-op (returning the tab record when we have its id) so
    // tab-managers like OneTab don't throw on an unguarded call.
    discard: function (tabId, cb) {
      if (typeof tabId === 'function') { cb = tabId; tabId = undefined; }
      return settleBg(Promise.resolve(undefined), cb);
    },
    captureVisibleTab: function () {
      // (windowId?, options?, callback?) — windowId is ignored (single window on iOS). Returns a data URL.
      var args = Array.prototype.slice.call(arguments);
      var cb = (args.length && typeof args[args.length - 1] === 'function') ? args.pop() : null;
      var options = null;
      for (var i = 0; i < args.length; i++) { if (args[i] && typeof args[i] === 'object') { options = args[i]; } }
      options = options || {};
      var p = new Promise(function (resolve, reject) {
        __bb_capture_visible_tab(JSON.stringify({
          format: options.format || 'png',
          quality: typeof options.quality === 'number' ? options.quality : 92
        }), function (resJSON) {
          var r = parseJSON(resJSON);
          if (r && r.dataUrl) { resolve(r.dataUrl); }
          else { var e = new Error((r && r.error) || 'captureVisibleTab failed'); e.__bbLastError = true; reject(e); }
        });
      });
      if (typeof cb === 'function') {
        p.then(function (v) { cb(v); }, function (e) {
          if (e && e.__bbLastError) { _bbLastError = { message: e.message }; }
          try { cb(undefined); } finally { _bbLastError = null; }
        });
        return undefined;
      }
      return p;
    },
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
    move: function (tabIds, moveProps, cb) {
      if (typeof moveProps === 'function') { cb = moveProps; moveProps = {}; }
      moveProps = moveProps || {};
      var single = !Array.isArray(tabIds);
      var ids = single ? [tabIds] : tabIds;
      return settleBg(tabsCall('move', { tabIds: ids, index: typeof moveProps.index === 'number' ? moveProps.index : -1 })
        .then(function (moved) { return (single && Array.isArray(moved)) ? moved[0] : moved; }), cb);
    },
    duplicate: function (tabId, cb) { return settleBg(tabsCall('duplicate', { tabId: tabId }), cb); },
    getZoom: function (a, b) {
      // (tabId?, callback?) — tabId may be omitted.
      var tabId = (typeof a === 'number') ? a : null;
      var cb = (typeof a === 'function') ? a : (typeof b === 'function' ? b : null);
      return settleBg(tabsCall('getZoom', { tabId: tabId }), cb);
    },
    setZoom: function (a, b, c) {
      // (tabId, zoomFactor, cb?) or (zoomFactor, cb?) — disambiguate by whether the 2nd arg is a number.
      var tabId = null, zoomFactor, cb = null;
      if (typeof b === 'number') { tabId = a; zoomFactor = b; cb = (typeof c === 'function') ? c : null; }
      else { zoomFactor = a; cb = (typeof b === 'function') ? b : null; }
      return settleBg(tabsCall('setZoom', { tabId: typeof tabId === 'number' ? tabId : null, zoomFactor: zoomFactor })
        .then(function () { return undefined; }), cb);
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
      // MV2 tabs.executeScript resolves to an array of RAW per-frame result values ([1]) — NOT the
      // MV3 [{ result, frameId }] shape that scripting.executeScript returns. Unwrap so MV2 managers
      // work: Violentmonkey's isInjectable() probe injects `code:'1'` and treats the page as runnable
      // only when the result array is [1]. A denied page yields [] here, which correctly reads as
      // not-injectable. (scripting.executeScript above keeps the MV3 shape — different code path.)
      var p = scriptingCall('executeScript', {
        tabId: id, code: details.code,
        files: details.file ? [details.file] : undefined,
        world: details.world,
        allFrames: details.allFrames === true,
        frameId: (typeof details.frameId === 'number') ? details.frameId : undefined
      }).then(function (r) {
        if (!Array.isArray(r)) { return r; }
        return r.map(function (x) {
          return (x && typeof x === 'object' && 'result' in x) ? x.result : x;
        });
      });
      return settleBg(p, cb);
    },
    insertCSS: function (id, details, cb) {
      if (id !== null && typeof id === 'object') { cb = details; details = id; id = undefined; }
      details = details || {};
      return settleBg(scriptingCall('insertCSS', { tabId: id, css: details.code, files: details.file ? [details.file] : undefined }).then(function () { return undefined; }), cb);
    },
    // chrome.tabs.highlight — focuses a window and selects specified tabs. iOS has a single window
    // with no multi-tab selection concept, so we resolve as a graceful no-op (Chrome Remote Desktop
    // uses this to focus the CRD tab after connecting). Returns the window info shape.
    highlight: function (highlightInfo, cb) {
      return settleBg(Promise.resolve({ id: 1, focused: true, type: 'normal', tabs: [] }), cb);
    },
    // Tab groups don't exist on iOS (single, ungrouped tab list). These resolve as graceful no-ops
    // (group → TAB_GROUP_ID_NONE = "not grouped") rather than being absent — Surfingkeys/Vimium C call
    // tabs.group/ungroup + chrome.tabGroups.* UNGUARDED, so an absent member would throw a TypeError.
    group: function (options, cb) { return settleBg(Promise.resolve(-1), cb); },
    ungroup: function (tabIds, cb) { return settleBg(Promise.resolve(undefined), cb); },
    onCreated: makeEvent(tabEventLists['tabs.onCreated']),
    onUpdated: makeEvent(tabEventLists['tabs.onUpdated']),
    onActivated: makeEvent(tabEventLists['tabs.onActivated']),
    onRemoved: makeEvent(tabEventLists['tabs.onRemoved']),
    onReplaced: makeEvent([]),
    // Tab "highlighting" is multi-select, which iOS's single-tab model has no concept of — no native
    // source ever fires these, but they must EXIST so a background that registers a listener unguarded
    // (Speechify's tabs.onHighlighted.addListener at boot) doesn't throw on undefined.onHighlighted.
    // onHighlightChanged is Chrome's deprecated alias for onHighlighted; some older bundles still use it.
    onHighlighted: makeEvent([]),
    onHighlightChanged: makeEvent([]),
    onZoomChange: makeEvent([]),
    // Tabs moving between windows / reordering. iOS's single-window model rarely fires these, but a
    // background that registers them at boot (OneTab's onMoved/onAttached/onDetached listeners) must
    // find the event objects or `undefined.addListener` throws before its handlers are installed.
    onAttached: makeEvent([]),
    onDetached: makeEvent([]),
    onMoved: makeEvent([])
  };

  // chrome.tabGroups — iOS has no tab groups, so this is a non-throwing shim (query → [], get → null,
  // update/move resolve). Present so extensions that read chrome.tabGroups.* unguarded don't crash.
  var tabGroups = {
    TAB_GROUP_ID_NONE: -1,
    query: function (queryInfo, cb) { return settleBg(Promise.resolve([]), cb); },
    get: function (groupId, cb) { return settleBg(Promise.resolve(null), cb); },
    update: function (groupId, props, cb) { return settleBg(Promise.resolve(null), cb); },
    move: function (groupId, props, cb) { return settleBg(Promise.resolve(null), cb); },
    onCreated: makeEvent([]), onUpdated: makeEvent([]), onMoved: makeEvent([]), onRemoved: makeEvent([])
  };

  // ---------------------------------------------------------------- chrome.webNavigation
  var webNavigation = {
    onBeforeNavigate: makeEvent(webNavLists['webNavigation.onBeforeNavigate']),
    onCommitted: makeEvent(webNavLists['webNavigation.onCommitted']),
    onDOMContentLoaded: makeEvent(webNavLists['webNavigation.onDOMContentLoaded']),
    onCompleted: makeEvent(webNavLists['webNavigation.onCompleted']),
    onHistoryStateUpdated: makeEvent(webNavLists['webNavigation.onHistoryStateUpdated']),
    onReferenceFragmentUpdated: makeEvent(webNavLists['webNavigation.onReferenceFragmentUpdated'] || []),
    onErrorOccurred: makeEvent(webNavLists['webNavigation.onErrorOccurred']),
    // onTabReplaced — Chrome fires this when a tab is replaced (e.g. an instant/prerendered page swap).
    // WKWebView has no equivalent so it never fires, but iCloud Passwords' background reads
    // `chrome.webNavigation.onTabReplaced.addListener` UNGUARDED at boot — an undefined event threw
    // "undefined is not an object" and aborted the whole service worker. Inert, but must exist.
    onTabReplaced: makeEvent([]),
    // onCreatedNavigationTarget — fired when a navigation creates a new window/tab (target=_blank etc.).
    // BrownBear can't intercept the target selection on WKWebView, so this event never fires; the
    // listener object must exist or vAPI.Tabs constructor (vapi-background.js:282) throws.
    onCreatedNavigationTarget: makeEvent([]),
    getFrame: function (details, cb) { if (typeof cb === 'function') { cb(null); } return Promise.resolve(null); },
    getAllFrames: function (details, cb) { if (typeof cb === 'function') { cb([]); } return Promise.resolve([]); }
  };

  // ---------------------------------------------------------------- chrome.privacy
  // browser.privacy.network / browser.privacy.websites — accessed by uBO's webext.js to build
  // the webext.privacy entries that vAPI.browserSettings uses to control prefetching, WebRTC IP
  // handling, and hyperlink auditing. webext.js iterates a settings list and reads
  // `chrome.privacy[category][setting]` at module-eval time (before any try/catch). Without this
  // the module fails immediately with "Cannot read properties of undefined".
  //
  // On iOS, WKWebView already disables prefetching and doesn't expose WebRTC IP control — so these
  // "set" calls are benign no-ops. The get/set/clear shape is preserved so webext.js and
  // vAPI.browserSettings don't crash when they call them.
  function makePrivacySetting() {
    var _value;
    return {
      get: function (details, cb) { var r = { value: _value, levelOfControl: 'controllable_by_this_extension' }; if (typeof cb === 'function') { cb(r); return undefined; } return Promise.resolve(r); },
      set: function (details, cb) { if (details && 'value' in details) { _value = details.value; } if (typeof cb === 'function') { cb(); return undefined; } return Promise.resolve(); },
      clear: function (details, cb) { _value = undefined; if (typeof cb === 'function') { cb(); return undefined; } return Promise.resolve(); },
      // Every Chrome ChromeSetting (privacy.*, proxy.settings) exposes onChange. Extensions that wrap a
      // privacy setting in a class call `setting.onChange.addListener` unconditionally at init — VeePN
      // (which locks WebRTC) crashed module-eval on `this.setting.onChange.addListener` without it.
      onChange: makeEvent([])
    };
  }
  var privacy = {
    network: {
      networkPredictionEnabled: makePrivacySetting(),
      webRTCIPHandlingPolicy: makePrivacySetting()
    },
    websites: {
      hyperlinkAuditingEnabled: makePrivacySetting()
    },
    // chrome.privacy.services — not in the official Chrome extension API docs but accessed by
    // Bitwarden and LastPass to read/write autofill-related browser-level settings. On iOS these
    // are no-ops (WKWebView has no autofill-address or credential-save toggle that extensions can
    // control), but the shape must exist or those extensions throw "Cannot read properties of
    // undefined" at init time and their content scripts never attach. We provide the same
    // {get/set/clear} PrivacySetting shape as the rest of chrome.privacy.
    services: {
      autofillAddressEnabled:    makePrivacySetting(),
      autofillCreditCardEnabled: makePrivacySetting(),
      passwordSavingEnabled:     makePrivacySetting()
    }
  };

  // ---------------------------------------------------------------- chrome.proxy
  // Browsec VPN and VeePN (and any extension that modifies the system proxy) call chrome.proxy.settings
  // get/set/clear to route traffic through their server. On iOS, direct per-dataStore proxy control
  // is available from iOS 17 via WKWebsiteDataStore.proxyConfigurations; we route through a NEW
  // __bb_proxy(method, argsJSON, cb) native when it exists (iOS 17+ WKWebView).
  //
  // Critical VeePN fix: `this.setting.onChange.addListener` is called unconditionally at init time.
  // The onChange event MUST exist or VeePN throws "Cannot read properties of undefined (reading
  // 'addListener')" before its message handlers are installed, leaving the background silent.
  //
  // Browsec fix: its handler awaits a reply to its proxy-get request; without a shim the promise
  // never settles and onMessage never fires (the "onMessage:date no-reply" hang). Returning a
  // valid get result unblocks the loop.
  (function () {
    var _proxyValue = { mode: 'system' };
    var _proxyLOC    = 'controllable_by_this_extension';
    var _proxyChangeListeners = [];
    var proxyOnChange = makeEvent(_proxyChangeListeners);

    function _fireProxyChange(value) {
      var detail = { value: value, levelOfControl: _proxyLOC };
      for (var i = 0; i < _proxyChangeListeners.length; i++) {
        try { _proxyChangeListeners[i](detail); } catch (e) {}
      }
    }

    function proxySettingsGet(details, cb) {
      var r = { value: _proxyValue, levelOfControl: _proxyLOC };
      if (typeof cb === 'function') { cb(r); return undefined; }
      return Promise.resolve(r);
    }

    function proxySettingsSet(details, cb) {
      var value = (details && details.value) ? details.value : { mode: 'system' };
      if (typeof __bb_proxy === 'function') {
        return new Promise(function (resolve) {
          __bb_proxy('set', JSON.stringify(value), function (errJSON) {
            var err = errJSON ? JSON.parse(errJSON) : null;
            if (!err) { _proxyValue = value; _fireProxyChange(value); }
            if (typeof cb === 'function') { cb(); }
            resolve();
          });
        });
      }
      // Native not available yet (pre-iOS-17 shim path): record locally and fire onChange.
      _proxyValue = value;
      _fireProxyChange(value);
      if (typeof cb === 'function') { cb(); return undefined; }
      return Promise.resolve();
    }

    function proxySettingsClear(details, cb) {
      var clearedValue = { mode: 'system' };
      if (typeof __bb_proxy === 'function') {
        return new Promise(function (resolve) {
          __bb_proxy('clear', '{}', function () {
            _proxyValue = clearedValue;
            _fireProxyChange(clearedValue);
            if (typeof cb === 'function') { cb(); }
            resolve();
          });
        });
      }
      _proxyValue = clearedValue;
      _fireProxyChange(clearedValue);
      if (typeof cb === 'function') { cb(); return undefined; }
      return Promise.resolve();
    }

    var proxy = {
      settings: {
        get:      proxySettingsGet,
        set:      proxySettingsSet,
        clear:    proxySettingsClear,
        onChange: proxyOnChange
      },
      onProxyError: makeEvent([])
    };
    // Expose on globalThis so the chrome/browser object literal below can reference it.
    globalThis.__bbProxyNS = proxy;
  })();

  // ---------------------------------------------------------------- chrome.webRequest (observe-only no-op)
  // WebKit can't intercept network requests, so these listeners never fire — but the event objects must
  // EXIST so extensions that register handlers (ScriptCat, ad blockers) don't throw "undefined is not an
  // object" on access. Blocking/redirect is handled via declarativeNetRequest where expressible.
  //
  // EXCEPTION — userscript install: a Manifest V2 manager (Violentmonkey) claims `.user.js` navigations
  // with a blocking onBeforeRequest listener filtered to `*://*/*.user.js`. We record that listener WITH
  // its url/type filter so the native navigation delegate can dispatch a synthetic onBeforeRequest for a
  // `.user.js` URL into the worker (`__bbDispatchWebRequestUserScript`), letting the manager's own confirm
  // flow run — the webRequest analog of the declarativeNetRequest hand-off used for MV3 managers.
  var __bbWebRequestOnBeforeRequest = [];   // [{ fn, urls:[pattern], types:[type]|null }]
  // Warn ONCE per worker when an extension registers a BLOCKING webRequest listener against general
  // traffic. WebKit gives no synchronous request-interception hook, so such a listener never fires —
  // the extension silently does nothing (uBlock Origin, Privacy Badger, Decentraleyes, ClearURLs all
  // hit this). Surfacing it turns an invisible dead feature into a diagnosable Logs line that points at
  // declarativeNetRequest. We do NOT warn for the legitimate `*.user.js` install handoff (which a V2
  // manager registers as a blocking onBeforeRequest and which DOES work via the synthetic dispatch).
  var __bbWarnedBlockingWebRequest = false;
  function __bbNoteBlockingWebRequest(filter, extraInfoSpec) {
    if (__bbWarnedBlockingWebRequest) { return; }
    if (!Array.isArray(extraInfoSpec) || extraInfoSpec.indexOf('blocking') < 0) { return; }
    var urls = (filter && filter.urls) || [];
    // The userscript-install listener targets only `*.user.js` and is genuinely honored — don't warn for it.
    var userScriptOnly = urls.length > 0 && urls.every(function (u) { return /\.user\.js(\b|$)/i.test(String(u)); });
    if (userScriptOnly) { return; }
    __bbWarnedBlockingWebRequest = true;
    __bb_log('warn', 'chrome.webRequest blocking/redirect listeners cannot intercept requests on ' +
      'WKWebView (iOS) — this listener will never fire, so request blocking/modification here is inert. ' +
      'Use declarativeNetRequest for network blocking.');
  }
  function makeWebRequestEvent(store) {
    return {
      addListener: function (fn, filter, _extraInfoSpec) {
        if (typeof fn !== 'function') { return; }
        store.push({ fn: fn, urls: (filter && filter.urls) || [], types: (filter && filter.types) || null });
        __bbNoteBlockingWebRequest(filter, _extraInfoSpec);
      },
      removeListener: function (fn) { for (var i = store.length - 1; i >= 0; i--) { if (store[i].fn === fn) { store.splice(i, 1); } } },
      hasListener: function (fn) { for (var i = 0; i < store.length; i++) { if (store[i].fn === fn) { return true; } } return false; },
      hasListeners: function () { return store.length > 0; }
    };
  }
  // Match-pattern (<scheme>://<host><path>) matcher for the webRequest url filter. Cached per pattern.
  //
  // SECURITY (ReDoS): an installed manager fully controls these filter patterns. The scheme+host are
  // compiled to a bounded prefix RegExp (a single `[^/]+`/`(?:[^/]+\.)?` quantifier — no catastrophic
  // backtracking), but the PATH is matched with a LINEAR glob (split on `*`, sequential indexOf), NOT a
  // `^...a.*a.*a...$` regex. The naive `.*`-join is polynomial: against a long not-quite-matching URL the
  // engine backtracks across every wildcard boundary and hangs the extension's serial worker queue. The
  // glob is O(url.length × segments). We also cap pattern/URL length symmetrically with the DNR matcher
  // (UserScriptInstallRouter: regexFilter ≤ 1000). Treat every stored filter pattern as hostile.
  var __bbMatchPatternCache = {};
  var __BB_MP_MAX_PATTERN = 1000;   // symmetric with UserScriptInstallRouter's regexFilter cap
  var __BB_MP_MAX_URL = 4096;
  function __bbCompileMatchPattern(pattern) {
    function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
    if (typeof pattern !== 'string' || pattern.length > __BB_MP_MAX_PATTERN) { return null; }
    // `<all_urls>`: any supported scheme, any host, any path. segs:null ⇒ glob matches every path.
    if (pattern === '<all_urls>') { return { prefixRe: /^(?:https?|file|ftp|ws|wss):\/\/[^/]*/i, segs: null }; }
    var m = /^(\*|[a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/]*)(\/.*)$/.exec(pattern);
    if (!m) { return null; }
    var scheme = m[1].toLowerCase(), host = m[2], path = m[3];
    var schemeRe = scheme === '*' ? '(?:https?)' : esc(scheme);
    var hostRe;
    if (host === '*') { hostRe = '[^/]+'; }
    else if (host.indexOf('*.') === 0) { hostRe = '(?:[^/]+\\.)?' + esc(host.slice(2)); }
    else if (host === '') { hostRe = ''; }
    else { hostRe = esc(host); }
    // prefixRe matches `scheme://host` only (no `$`); the remaining URL tail is the path, glob-matched
    // below. `[^/]+`/`(?:[^/]+\.)?` are the only quantifiers ⇒ no super-linear backtracking on the prefix.
    var prefixRe;
    try { prefixRe = new RegExp('^' + schemeRe + '://' + hostRe, 'i'); } catch (e) { return null; }
    return { prefixRe: prefixRe, segs: path.split('*') };
  }
  // Linear glob: do the literal `segs` (split of the path on `*`) appear in order in `s`, with the first
  // anchored at the start and the last at the end? No backtracking — left-to-right indexOf scan.
  function __bbGlobMatch(segs, s) {
    if (!segs) { return true; }                          // <all_urls>: any path
    if (segs.length === 1) { return s === segs[0]; }     // no wildcard ⇒ exact path
    if (s.lastIndexOf(segs[0], 0) !== 0) { return false; }   // must start with the leading literal
    var idx = segs[0].length;
    for (var i = 1; i < segs.length - 1; i++) {
      var found = s.indexOf(segs[i], idx);
      if (found < 0) { return false; }
      idx = found + segs[i].length;
    }
    var last = segs[segs.length - 1];
    if (last === '') { return true; }                    // trailing `*` ⇒ anything remaining is fine
    var at = s.length - last.length;
    return at >= idx && s.indexOf(last, at) === at;       // must end with the trailing literal
  }
  function __bbMatchPattern(pattern, url) {
    if (typeof url !== 'string' || !url || url.length > __BB_MP_MAX_URL) { return false; }
    if (!(pattern in __bbMatchPatternCache)) { __bbMatchPatternCache[pattern] = __bbCompileMatchPattern(pattern); }
    var c = __bbMatchPatternCache[pattern];
    if (!c) { return false; }
    var m = c.prefixRe.exec(url);
    if (!m || m.index !== 0) { return false; }
    return __bbGlobMatch(c.segs, url.slice(m[0].length));
  }
  var __bbWebRequestSeq = 0;
  // Called from native when a main-frame `.user.js` navigation should be offered to a webRequest-based
  // manager. Invokes every onBeforeRequest listener whose filter matches; returns true if any ran (so the
  // browser knows a manager took it and need not show the native install card).
  globalThis.__bbDispatchWebRequestUserScript = function (url, tabId) {
    if (typeof url !== 'string' || !url || !__bbWebRequestOnBeforeRequest.length) { return false; }
    var details = {
      requestId: String(++__bbWebRequestSeq), url: url, method: 'GET',
      frameId: 0, parentFrameId: -1, tabId: (typeof tabId === 'number' ? tabId : -1),
      type: 'main_frame', timeStamp: Date.now()
    };
    var handled = false;
    for (var i = 0; i < __bbWebRequestOnBeforeRequest.length; i++) {
      var entry = __bbWebRequestOnBeforeRequest[i];
      if (entry.types && entry.types.indexOf('main_frame') < 0) { continue; }
      var matches = !entry.urls || entry.urls.length === 0;
      for (var j = 0; !matches && j < entry.urls.length; j++) { if (__bbMatchPattern(entry.urls[j], url)) { matches = true; } }
      if (!matches) { continue; }
      try { entry.fn(details); handled = true; }
      catch (e) { __bb_log('error', 'webRequest.onBeforeRequest dispatch threw: ' + (e && e.message ? e.message : e)); }
    }
    return handled;
  };
  // Detection-only twin of the dispatcher: does this worker have a main-frame onBeforeRequest listener
  // whose filter matches `url`? Used to list this extension as an install TARGET without invoking the
  // listener (which would start the install). No side effects.
  globalThis.__bbHasWebRequestUserScriptListener = function (url) {
    if (typeof url !== 'string' || !url) { return false; }
    for (var i = 0; i < __bbWebRequestOnBeforeRequest.length; i++) {
      var entry = __bbWebRequestOnBeforeRequest[i];
      if (entry.types && entry.types.indexOf('main_frame') < 0) { continue; }
      if (!entry.urls || entry.urls.length === 0) { return true; }
      for (var j = 0; j < entry.urls.length; j++) { if (__bbMatchPattern(entry.urls[j], url)) { return true; } }
    }
    return false;
  };

  var webRequest = {
    onBeforeRequest: makeWebRequestEvent(__bbWebRequestOnBeforeRequest), onBeforeSendHeaders: makeEvent([]), onSendHeaders: makeEvent([]),
    onHeadersReceived: makeEvent([]), onBeforeRedirect: makeEvent([]), onAuthRequired: makeEvent([]),
    onResponseStarted: makeEvent([]), onCompleted: makeEvent([]), onErrorOccurred: makeEvent([]),
    onActionIgnored: makeEvent([]),
    // Chrome exposes ResourceType on chrome.webRequest — MV2 extensions (notably uBlock Origin)
    // read `browser.webRequest.ResourceType instanceof Object` and `.ResourceType.WEBSOCKET` at
    // module-eval time (vapi-background.js:35-36) to determine vAPI.cantWebsocket. Without this
    // object the check throws and vAPI.Net is constructed incorrectly. Same shape as
    // declarativeNetRequest.ResourceType but on the webRequest namespace as Chrome ships it.
    ResourceType: {
      MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script',
      IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping',
      CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport',
      WEBBUNDLE: 'webbundle', OTHER: 'other'
    },
    // Chrome exposes the addListener `extraInfoSpec` enums on chrome.webRequest. Extensions read them
    // at top level — Violentmonkey's background does `webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS`
    // and `OnHeadersReceivedOptions.EXTRA_HEADERS` during init, so the enum objects MUST exist or that
    // access throws "undefined is not an object" and aborts the whole background bundle.
    OnBeforeSendHeadersOptions: { REQUEST_HEADERS: 'requestHeaders', BLOCKING: 'blocking', EXTRA_HEADERS: 'extraHeaders' },
    OnSendHeadersOptions: { REQUEST_HEADERS: 'requestHeaders', EXTRA_HEADERS: 'extraHeaders' },
    OnHeadersReceivedOptions: { BLOCKING: 'blocking', RESPONSE_HEADERS: 'responseHeaders', EXTRA_HEADERS: 'extraHeaders' },
    OnAuthRequiredOptions: { RESPONSE_HEADERS: 'responseHeaders', BLOCKING: 'blocking', ASYNC_BLOCKING: 'asyncBlocking', EXTRA_HEADERS: 'extraHeaders' },
    OnResponseStartedOptions: { RESPONSE_HEADERS: 'responseHeaders', EXTRA_HEADERS: 'extraHeaders' },
    OnBeforeRedirectOptions: { RESPONSE_HEADERS: 'responseHeaders', EXTRA_HEADERS: 'extraHeaders' },
    OnCompletedOptions: { RESPONSE_HEADERS: 'responseHeaders', EXTRA_HEADERS: 'extraHeaders' },
    handlerBehaviorChanged: function (cb) { if (typeof cb === 'function') { cb(); } return Promise.resolve(); },
    MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20
  };

  // ---------------------------------------------------------------- chrome.offscreen
  // A real offscreen document: the native side hosts the extension page in a hidden WKWebView (a true
  // DOM), since an MV3 service worker has none. createDocument resolves once the document has loaded;
  // the worker then talks to it via chrome.runtime messaging (background → page is wired). Chrome allows
  // a SINGLE offscreen document per extension — a second createDocument rejects.
  function __bbOffscreenCall(method, args) {
    return new Promise(function (resolve, reject) {
      __bb_offscreen(method, JSON.stringify(args || {}), function (resJSON) {
        var r = parseJSON(resJSON) || {};
        if (r && r.error) { reject(new Error(r.error)); } else { resolve(r); }
      });
    });
  }
  var offscreen = {
    Reason: { AUDIO_PLAYBACK: 'AUDIO_PLAYBACK', BLOBS: 'BLOBS', CLIPBOARD: 'CLIPBOARD',
              DISPLAY_MEDIA: 'DISPLAY_MEDIA', DOM_PARSER: 'DOM_PARSER', DOM_SCRAPING: 'DOM_SCRAPING',
              GEOLOCATION: 'GEOLOCATION', IFRAME_SCRIPTING: 'IFRAME_SCRIPTING', LOCAL_STORAGE: 'LOCAL_STORAGE',
              MATCH_MEDIA: 'MATCH_MEDIA', TESTING: 'TESTING', USER_MEDIA: 'USER_MEDIA', WORKERS: 'WORKERS' },
    createDocument: function (opts, cb) {
      var o = opts || {};
      var p = __bbOffscreenCall('createDocument', {
        url: o.url || '', reasons: o.reasons || [], justification: o.justification || ''
      }).then(function () { return undefined; });
      if (typeof cb === 'function') { p.then(function () { cb(); }, function () { cb(); }); return undefined; }
      return p;
    },
    closeDocument: function (cb) {
      var p = __bbOffscreenCall('closeDocument', {}).then(function () { return undefined; });
      if (typeof cb === 'function') { p.then(function () { cb(); }, function () { cb(); }); return undefined; }
      return p;
    },
    hasDocument: function (cb) {
      var p = __bbOffscreenCall('hasDocument', {}).then(function (r) { return !!(r && r.hasDocument); });
      if (typeof cb === 'function') { p.then(function (v) { cb(v); }, function () { cb(false); }); return undefined; }
      return p;
    }
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
  function scriptingVoid(method, args) {
    return scriptingCall(method, args).then(function (r) { if (r && r.error) { throw new Error(r.error); } return undefined; });
  }
  var scripting = {
    // chrome.scripting.ExecutionWorld — enum that extensions read by name (e.g.
    // `world: chrome.scripting.ExecutionWorld.MAIN`). React DevTools, Bitwarden, and several other
    // MV3 extensions reference it at the call-site rather than as a string literal. Its absence
    // causes "Cannot read properties of undefined (reading 'MAIN')" and aborts script injection.
    ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT' },
    executeScript: function (injection, cb) { return settleBg(scriptingCall('executeScript', serializeInjection(injection)), cb); },
    insertCSS: function (injection, cb) { return settleBg(scriptingCall('insertCSS', cssInjection(injection)).then(function () { return undefined; }), cb); },
    removeCSS: function (injection, cb) { return settleBg(scriptingCall('removeCSS', cssInjection(injection)).then(function () { return undefined; }), cb); },
    // MV3 dynamic content scripts — registered scripts inject into matching pages exactly like
    // manifest content_scripts (ScriptCat registers its userscripts this way).
    registerContentScripts: function (scripts, cb) { return settleBg(scriptingVoid('registerContentScripts', { scripts: scripts || [] }), cb); },
    updateContentScripts: function (scripts, cb) { return settleBg(scriptingVoid('updateContentScripts', { scripts: scripts || [] }), cb); },
    getRegisteredContentScripts: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(scriptingCall('getRegisteredContentScripts', { filter: filter || null }).then(function (r) { return (r && r.error) ? [] : r; }), cb);
    },
    unregisterContentScripts: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(scriptingVoid('unregisterContentScripts', { filter: filter || null }), cb);
    }
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
    // chrome.management.uninstallSelf([options], cb) — iOS has no programmatic self-uninstall (the user
    // removes an extension via long-press in BrownBear), so resolve as a graceful no-op rather than let an
    // unguarded call (e.g. Grammarly's "remove extension" flow) throw.
    uninstallSelf: function (options, cb) {
      if (typeof options === 'function') { cb = options; }
      return settleBg(Promise.resolve(undefined), cb);
    },
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
    onAdded: makeEvent(permissionsEventLists['permissions.onAdded']),
    onRemoved: makeEvent(permissionsEventLists['permissions.onRemoved'])
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
  // Warn ONCE per worker when an extension toggles individual static rules — iOS compiles packaged static
  // rulesets into a WKContentRuleList wholesale, so a per-rule disable isn't honored yet. Surfacing it
  // turns a silent divergence into a diagnosable Logs line (mirrors the blocking-webRequest note above).
  var __bbWarnedStaticRuleDegrade = false;
  function __bbNoteStaticRuleDegrade() {
    if (__bbWarnedStaticRuleDegrade) { return; }
    __bbWarnedStaticRuleDegrade = true;
    __bb_log('warn', 'chrome.declarativeNetRequest.updateStaticRules (per-rule enable/disable within a ' +
      'packaged static ruleset) is not yet honored on iOS — static rulesets compile to a WKContentRuleList ' +
      'wholesale. Ruleset-level toggling (updateEnabledRulesets) and dynamic/session rules work normally.');
  }
  var declarativeNetRequest = {
    // Chrome exposes these enums + limits as constants on chrome.declarativeNetRequest; extensions read
    // them directly (e.g. ResourceType.MAIN_FRAME). Their absence throws "undefined is not an object".
    ResourceType: { MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other' },
    RuleActionType: { BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests' },
    HeaderOperation: { APPEND: 'append', SET: 'set', REMOVE: 'remove' },
    DomainType: { FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty' },
    UnsupportedRegexReason: { SYNTAX_ERROR: 'syntaxError', MEMORY_LIMIT_EXCEEDED: 'memoryLimitExceeded' },
    DYNAMIC_RULESET_ID: '_dynamic', SESSION_RULESET_ID: '_session',
    // Chrome 121+ split the combined dynamic/session cap into per-bucket limits, and adblockers
    // (uBO/uBO Lite, AdGuard, Ghostery) read these directly to chunk their rule writes. Keeping only
    // the legacy combined constant left `chrome.declarativeNetRequest.MAX_NUMBER_OF_DYNAMIC_RULES`
    // undefined, so a `rules.length < MAX_…` guard compared against undefined (NaN) and silently
    // mis-sized the batch. Values mirror Chrome's documented limits.
    MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000,
    MAX_NUMBER_OF_SESSION_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
    MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000,
    MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
    GUARANTEED_MINIMUM_STATIC_RULES: 30000,
    GETMATCHEDRULES_QUOTA_INTERVAL: 600, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20,
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
    // chrome 120+ static-ruleset management. Adblock Plus / AdBlock (MV3) drive their per-filter
    // allowlisting through these; the methods were absent, so the FIRST call threw "...is not a function"
    // inside the SW's async init and broke ruleset configuration. iOS enforces packaged static rulesets
    // wholesale via a compiled WKContentRuleList — ruleset-level toggling (updateEnabledRulesets) and
    // dynamic/session rules are honored natively; per-RULE enable/disable within a static ruleset would
    // require recompiling that list without the disabled IDs (a native follow-up).
    //
    // updateStaticRules routes to native (so it works automatically once native gains the method) and,
    // until then, degrades to a no-op with a single diagnostic rather than rejecting — boot and
    // ruleset-level blocking are unaffected. The two reads answer locally with Chrome-correct shapes:
    // nothing is per-rule-disabled yet, and the available static-rule budget is Chrome's guaranteed floor.
    updateStaticRules: function (options, cb) {
      return settleBg(dnrCall('updateStaticRules', options || {}).then(function () { return undefined; },
        function () { __bbNoteStaticRuleDegrade(); return undefined; }), cb);
    },
    getDisabledRuleIds: function (options, cb) {
      if (typeof options === 'function') { cb = options; options = null; }
      return settleBg(Promise.resolve([]), cb);
    },
    getAvailableStaticRuleCount: function (cb) {
      return settleBg(Promise.resolve(declarativeNetRequest.GUARANTEED_MINIMUM_STATIC_RULES), cb);
    },
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
    // register/unregister/getScripts are called by uBO Lite's registerSandboxFilters.register() without
    // a try/catch around each await. If any of them reject, register() throws uncaught, and
    // registerSandboxFilters.pendingOp (a module-level singleton in filter-manager.js) becomes a
    // permanently-rejected Promise. Every subsequent call to registerSandboxFilters() then returns an
    // immediately-rejected Promise via .then(() => register()) chained on the poisoned pendingOp, which
    // propagates through registerDeclarativeAssets() → the 'setFilteringMode' onMessage case →
    // onMessage() rejects → onMessage(req).then(callback) skips the callback → the popup/dashboard
    // message never gets a reply → infinite loading state on the filtering-mode slider.
    //
    // Fix: absorb errors at the shim boundary for the three methods called without try/catch in
    // registerSandboxFilters.register(). On native error they degrade to safe empty values (undefined
    // for void ops, [] for getScripts) and log the error for diagnosis instead of propagating a
    // rejection that permanently corrupts the pendingOp singleton.
    register: function (scripts, cb) {
      return settleBg(userScriptsCall('register', { scripts: scripts || [] }).then(function () { return undefined; }, function (e) {
        __bb_log('error', '[userScripts.register] native error (degrading gracefully): ' + (e && e.message ? e.message : e));
        return undefined;
      }), cb);
    },
    update: function (scripts, cb) { return settleBg(userScriptsCall('update', { scripts: scripts || [] }).then(function () { return undefined; }), cb); },
    unregister: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(userScriptsCall('unregister', { filter: filter || null }).then(function () { return undefined; }, function (e) {
        __bb_log('error', '[userScripts.unregister] native error (degrading gracefully): ' + (e && e.message ? e.message : e));
        return undefined;
      }), cb);
    },
    getScripts: function (filter, cb) {
      if (typeof filter === 'function') { cb = filter; filter = null; }
      return settleBg(userScriptsCall('getScripts', { filter: filter || null }).catch(function (e) {
        __bb_log('error', '[userScripts.getScripts] native error (degrading to []): ' + (e && e.message ? e.message : e));
        return [];
      }), cb);
    },
    configureWorld: function (properties, cb) { return settleBg(userScriptsCall('configureWorld', { properties: properties || {} }).then(function () { return undefined; }), cb); },
    resetWorldConfiguration: function (worldId, cb) {
      if (typeof worldId === 'function') { cb = worldId; worldId = null; }
      return settleBg(userScriptsCall('resetWorldConfiguration', { worldId: worldId || null }).then(function () { return undefined; }), cb);
    },
    // chrome.userScripts.getWorldConfigurations() → the stored per-world settings ([{worldId,csp,messaging}]).
    getWorldConfigurations: function (cb) { return settleBg(userScriptsCall('getWorldConfigurations', {}), cb); },
    // chrome.userScripts.execute(injection) → run JS in a user-script world of the target tab NOW, returning
    // one InjectionResult ({frameId,result|error}) per frame. Mirrors scripting.executeScript but in the
    // USER_SCRIPT world by default (Chrome 135+).
    execute: function (injection, cb) { return settleBg(userScriptsCall('execute', { injection: injection || {} }), cb); }
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
    return new Promise(function (resolve, reject) {
      __bb_notifications(method, JSON.stringify(args || {}), function (resJSON) {
        var r = parseJSON(resJSON);
        if (r && typeof r === 'object' && typeof r.__bbError === 'string') {
          // Native failed (was a silent phantom-success null id) — log + reject so it's diagnosable.
          __bb_log('warn', 'chrome.notifications.' + method + ' failed: ' + r.__bbError);
          reject(new Error(r.__bbError));
        } else { resolve(r); }
      });
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

  // chrome.identity. getRedirectURL is the real Chrome value (https://<id>.chromiumapp.org/<path>) an
  // extension registers as its OAuth redirect URI. launchWebAuthFlow's interactive auth UI lands in a
  // follow-up (it needs a presented web view); until then it rejects clearly rather than hanging or
  // throwing on an undefined namespace. getProfileUserInfo/getAccounts report empty (no iOS account).
  var identity = {
    getRedirectURL: function (path) {
      var p = (path == null) ? '' : String(path);
      if (p.charAt(0) === '/') { p = p.slice(1); }
      return 'https://' + extId + '.chromiumapp.org/' + p;
    },
    launchWebAuthFlow: function (details, cb) {
      return settleBg(Promise.reject(new Error('identity.launchWebAuthFlow is not yet available')), cb);
    },
    getAuthToken: function (details, cb) {
      if (typeof details === 'function') { cb = details; }
      return settleBg(Promise.reject(new Error('identity.getAuthToken is not supported; use launchWebAuthFlow')), cb);
    },
    removeCachedAuthToken: function (details, cb) { return settleBg(Promise.resolve(), cb); },
    clearAllCachedAuthTokens: function (cb) { return settleBg(Promise.resolve(), cb); },
    getProfileUserInfo: function (details, cb) {
      if (typeof details === 'function') { cb = details; }
      return settleBg(Promise.resolve({ email: '', id: '' }), cb);
    },
    getAccounts: function (cb) { return settleBg(Promise.resolve([]), cb); },
    // chrome.identity.AccountStatus enum — Google Keep reads chrome.identity.AccountStatus.ANY in a
    // getProfileUserInfo({ accountStatus }) call at boot; a missing enum threw "Cannot read properties of
    // undefined (reading 'ANY')" and aborted the worker.
    AccountStatus: { SYNC: 'SYNC', ANY: 'ANY' },
    onSignInChanged: makeEvent([])
  };

  // chrome.omnibox — address-bar keyword API. Toby and JSON Viewer register omnibox.onInputChanged/
  // onInputEntered at boot; an undefined namespace threw "Cannot read properties of undefined (reading
  // 'onInputEntered')" and aborted the worker. BrownBear's omnibox doesn't route a registered keyword's
  // input to extensions yet, so the events are inert (never fire) and setDefaultSuggestion is a no-op —
  // but the surface must exist so registration at boot doesn't crash.
  var omnibox = {
    setDefaultSuggestion: function () {},
    onInputStarted: makeEvent([]),
    onInputChanged: makeEvent([]),
    onInputEntered: makeEvent([]),
    onInputCancelled: makeEvent([]),
    onDeleteSuggestion: makeEvent([])
  };

  // chrome.system.{cpu,memory,display,storage} — system-info APIs. Screen recorders / monitors (Loom
  // reads system.cpu.getInfo) call these; an undefined namespace throws "chrome.system is undefined" the
  // moment the feature runs. A JSContext can't read true device CPU/RAM, so report PLAUSIBLE, spec-shaped
  // values (processor count from navigator.hardwareConcurrency; screen size when a screen is present) so
  // consumers proceed instead of crashing. This is information-only — no capability is granted or faked.
  var systemNS = {
    cpu: {
      getInfo: function (cb) {
        var n = (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) || 4;
        var info = { numOfProcessors: n, archName: 'arm64', modelName: 'Apple silicon', features: [], processors: [] };
        for (var i = 0; i < n; i++) { info.processors.push({ usage: { user: 0, kernel: 0, idle: 0, total: 0 } }); }
        return settleBg(Promise.resolve(info), cb);
      }
    },
    memory: {
      getInfo: function (cb) {
        // Device RAM is unreadable from a JSContext; report a plausible capacity (consumers gate on it).
        return settleBg(Promise.resolve({ capacity: 4 * 1024 * 1024 * 1024, availableCapacity: 2 * 1024 * 1024 * 1024 }), cb);
      }
    },
    display: {
      getInfo: function (options, cb) {
        if (typeof options === 'function') { cb = options; options = null; }
        var w = (typeof screen !== 'undefined' && screen.width) || 390;
        var h = (typeof screen !== 'undefined' && screen.height) || 844;
        var bounds = { left: 0, top: 0, width: w, height: h };
        var d = { id: '0', name: 'BrownBear Display', isPrimary: true, isEnabled: true, isInternal: true,
                  bounds: bounds, workArea: bounds, dpiX: 96, dpiY: 96, rotation: 0,
                  overscan: { left: 0, top: 0, right: 0, bottom: 0 } };
        return settleBg(Promise.resolve([d]), cb);
      },
      getDisplayLayout: function (cb) { return settleBg(Promise.resolve([]), cb); },
      onDisplayChanged: makeEvent([])
    },
    storage: {
      getInfo: function (cb) { return settleBg(Promise.resolve([]), cb); },
      onAttached: makeEvent([]), onDetached: makeEvent([])
    }
  };

  // Warn ONCE when an extension attempts tab/desktop capture — WKWebView exposes NO media-capture path
  // to extensions (no tabCapture stream, no getDisplayMedia for chrome-extension://). The surface must
  // exist (Loom registers it at boot) but capture genuinely can't happen on iOS — fail closed, not crash.
  var __bbWarnedCaptureUnavailable = false;
  function __bbNoteCaptureUnavailable(which) {
    if (__bbWarnedCaptureUnavailable) { return; }
    __bbWarnedCaptureUnavailable = true;
    __bb_log('warn', 'chrome.' + which + ' — tab/desktop media capture is unavailable on WKWebView (iOS): ' +
      'the extension API exists but no capture stream can be produced, so this fails closed. Screen/tab ' +
      'recording features will not function.');
  }
  // chrome.tabCapture — capture a tab's MediaStream. No WKWebView equivalent for extensions.
  var tabCaptureNS = {
    capture: function (options, cb) {
      __bbNoteCaptureUnavailable('tabCapture.capture');
      if (typeof cb === 'function') { cb(null); return undefined; }   // Chrome hands back null + lastError on failure
      return undefined;
    },
    getCapturedTabs: function (cb) { return settleBg(Promise.resolve([]), cb); },
    getMediaStreamId: function (options, cb) {
      if (typeof options === 'function') { cb = options; options = null; }
      __bbNoteCaptureUnavailable('tabCapture.getMediaStreamId');
      return settleBg(Promise.reject(new Error('Tab capture is not supported on this platform')), cb);
    },
    onStatusChanged: makeEvent([])
  };
  // chrome.desktopCapture — pick a screen/window to capture. No WKWebView equivalent.
  var desktopCaptureNS = {
    chooseDesktopMedia: function (sources, targetTabOrCb, cb) {
      var callback = (typeof targetTabOrCb === 'function') ? targetTabOrCb : cb;
      __bbNoteCaptureUnavailable('desktopCapture.chooseDesktopMedia');
      // streamId '' = cancelled/unavailable; Chrome's callback shape is (streamId, options).
      if (typeof callback === 'function') { callback('', { canRequestAudioTrack: false }); }
      return 0;   // a request id; cancelChooseDesktopMedia(id) is a no-op here
    },
    cancelChooseDesktopMedia: function (id) { /* nothing in flight to cancel */ }
  };

  // Warn ONCE when an extension drives chrome.tts — the MV3 background is a JSContext with no Web Speech
  // API, so synthesizing audio from the worker would need native AVSpeechSynthesizer (a host follow-up).
  var __bbWarnedTtsUnavailable = false;
  function __bbNoteTtsUnavailable() {
    if (__bbWarnedTtsUnavailable) { return; }
    __bbWarnedTtsUnavailable = true;
    __bb_log('warn', 'chrome.tts.speak — the platform speech engine is not wired to the extension service ' +
      'worker on iOS (no Web Speech API in a JSContext). TTS via chrome.tts fails closed; an extension with ' +
      'other engines (cloud/in-tab speechSynthesis) falls back to those.');
  }
  // chrome.tts — text-to-speech CONSUMER surface (ReadAloud calls speak/stop/pause/resume/isSpeaking/
  // getVoices via its `brapi = chrome` wrapper). An undefined namespace throws the moment the extension
  // builds its engine list. getVoices reports none (the OS engine has no JS-enumerable voices here, so the
  // extension's other engines take over); speak fails closed via an 'error' tts event + one diagnostic.
  var ttsNS = {
    speak: function (utterance, options, cb) {
      if (typeof options === 'function') { cb = options; options = null; }
      __bbNoteTtsUnavailable();
      var onEvent = (options && typeof options.onEvent === 'function') ? options.onEvent : null;
      if (onEvent) {
        try { onEvent({ type: 'error', charIndex: 0, errorMessage: 'TTS engine unavailable on this platform' }); } catch (e) {}
      }
      if (typeof cb === 'function') { cb(); return undefined; }
      return Promise.resolve();
    },
    stop: function () {},
    pause: function () {},
    resume: function () {},
    isSpeaking: function (cb) { if (typeof cb === 'function') { cb(false); return undefined; } return Promise.resolve(false); },
    getVoices: function (cb) { if (typeof cb === 'function') { cb([]); return undefined; } return Promise.resolve([]); },
    onEvent: makeEvent([])
  };
  // chrome.ttsEngine — for extensions that PROVIDE voices to chrome.tts. We can't route the OS speech
  // engine to a JS provider, so the registration is inert (events never fire), but the surface must exist
  // so an engine-provider extension's addListener calls don't throw at boot. updateVoices is a no-op.
  var ttsEngineNS = {
    updateVoices: function () {},
    sendTtsEvent: function () {},
    sendTtsAudio: function () {},
    onSpeak: makeEvent([]),
    onSpeakWithAudioStream: makeEvent([]),
    onStop: makeEvent([]),
    onPause: makeEvent([]),
    onResume: makeEvent([]),
    onInstallLanguageRequest: makeEvent([]),
    onUninstallLanguageRequest: makeEvent([]),
    onLanguageStatusRequest: makeEvent([])
  };

  // chrome.readingList — Chrome's MV3 reading list. iOS has no reading-list store; an inert query→[] (and
  // no-op mutators) keeps optional callers — e.g. OneTab's "import from Reading List" source — from
  // throwing on `chrome.readingList is undefined` when the user picks that path.
  var readingList = {
    query: function (info, cb) { return settleBg(Promise.resolve([]), cb); },
    addEntry: function (entry, cb) { return settleBg(Promise.resolve(undefined), cb); },
    removeEntry: function (info, cb) { return settleBg(Promise.resolve(undefined), cb); },
    updateEntry: function (info, cb) { return settleBg(Promise.resolve(undefined), cb); },
    onEntryAdded: makeEvent([]), onEntryRemoved: makeEvent([]), onEntryUpdated: makeEvent([])
  };

  var chrome = {
    runtime: runtime,
    identity: identity,
    readingList: readingList,
    storage: storage,
    cookies: cookies,
    notifications: notifications,
    windows: windows,
    management: management,
    permissions: permissions,
    privacy: privacy,
    proxy: globalThis.__bbProxyNS,
    declarativeNetRequest: declarativeNetRequest,
    userScripts: userScripts,
    webNavigation: webNavigation,
    webRequest: webRequest,
    offscreen: offscreen,
    alarms: alarms,
    commands: commands,
    search: search,
    omnibox: omnibox,
    bookmarks: bookmarks,
    history: history,
    sessions: sessions,
    idle: idle,
    system: systemNS,
    tabCapture: tabCaptureNS,
    desktopCapture: desktopCaptureNS,
    tts: ttsNS,
    ttsEngine: ttsEngineNS,
    downloads: downloads,
    contextMenus: contextMenus,
    menus: contextMenus,
    action: action,
    browserAction: action,
    pageAction: pageAction,
    tabs: tabs,
    tabGroups: tabGroups,
    scripting: scripting,
    i18n: i18n,
    // chrome.extension is mostly legacy aliases of chrome.runtime, but real extensions still read it at
    // load (e.g. ScriptCat's checkUserScriptsAvailable reads inIncognitoContext). Provide the full shape
    // so a property access never returns undefined-then-throws. iOS has no private browsing for
    // extensions and no extension views, so the booleans are false and the view getters return empty.
    extension: {
      getURL: getURL,
      inIncognitoContext: false,
      getViews: function () { return []; },
      getBackgroundPage: function () { return globalThis; },
      isAllowedIncognitoAccess: function (cb) { if (typeof cb === 'function') { cb(false); return undefined; } return Promise.resolve(false); },
      isAllowedFileSchemeAccess: function (cb) { if (typeof cb === 'function') { cb(false); return undefined; } return Promise.resolve(false); },
      sendMessage: runtime.sendMessage,
      onMessage: runtime.onMessage,
      onRequest: runtime.onMessage
    },
    // chrome.dom — content-script utility that exposes openOrClosedShadowRoot(el), which reaches a
    // CLOSED shadow root (inaccessible via el.shadowRoot) from a privileged content-script world.
    // WebKit only exposes OPEN roots via shadowRoot; CLOSED ones are inaccessible to any script, so
    // we return shadowRoot (open) or null instead of throwing "chrome.dom is undefined". Present in
    // the content-script runtime (brownbear-webext-runtime.js) and needed here too — Bitwarden's
    // bootstrap content scripts are run from the background via scripting.executeScript and reach
    // chrome.dom through their bundled chrome reference.
    dom: {
      openOrClosedShadowRoot: function (element) {
        try { return (element && element.shadowRoot) || null; } catch (e) { return null; }
      }
    },
    // chrome.sidePanel — Chrome 114+ side-panel API. Grammarly, Bing, and several productivity
    // extensions register a side panel. iOS has no persistent side-panel surface, so these resolve
    // as graceful no-ops (open/setOptions resolve; getOptions returns {}) rather than throwing
    // "chrome.sidePanel is undefined" and killing the background worker's init flow.
    sidePanel: {
      open: function (options, cb) { return settleBg(Promise.resolve(undefined), cb); },
      setOptions: function (options, cb) { return settleBg(Promise.resolve(undefined), cb); },
      getOptions: function (options, cb) { return settleBg(Promise.resolve({}), cb); },
      setPanel: function (options, cb) { return settleBg(Promise.resolve(undefined), cb); },
      setPanelBehavior: function (behavior, cb) { return settleBg(Promise.resolve(undefined), cb); },
      getPanelBehavior: function (cb) { return settleBg(Promise.resolve({ openPanelOnActionClick: false }), cb); },
      onShown: makeEvent([]),
      onHidden: makeEvent([])
    },
    // chrome.devtools — the DevTools extension API. Only loaded when an extension's devtools page is
    // active; a background service worker that references it unguarded (e.g. React DevTools) gets
    // "chrome.devtools is undefined" and crashes. Provide an inert namespace: inspectedWindow.eval
    // and panels.create are no-ops (there is no embedded DevTools on iOS), and network is an empty
    // event surface. These never fire real events; they exist so registration doesn't throw.
    devtools: {
      inspectedWindow: {
        eval: function (expression, options, cb) {
          if (typeof options === 'function') { cb = options; }
          if (typeof cb === 'function') { cb(undefined, { isException: false }); return undefined; }
          return Promise.resolve([undefined, { isException: false }]);
        },
        reload: function () {},
        getResources: function (cb) { if (typeof cb === 'function') { cb([]); } },
        tabId: 0
      },
      panels: {
        create: function (title, iconPath, pagePath, cb) {
          if (typeof cb === 'function') { cb(null); }
          return Promise.resolve(null);
        },
        elements: { createSidebarPane: function (title, cb) { if (typeof cb === 'function') { cb(null); } } },
        sources: { createSidebarPane: function (title, cb) { if (typeof cb === 'function') { cb(null); } } },
        themeName: 'default',
        openResource: function () {}
      },
      network: {
        addRules: function () {},
        getHAR: function (cb) { if (typeof cb === 'function') { cb({ entries: [] }); } },
        onNavigated: makeEvent([]),
        onRequestFinished: makeEvent([])
      }
    }
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
      // Diagnostic: track this inbound message until it is answered or declined, so a popup/dashboard
      // request the worker RECEIVES but never answers (its onMessage stuck on `await isFullyInitialized`)
      // is named in the watchdog sweep — the smoking gun for "page waiting on the background worker".
      var _mwhat = (message && (message.method || message.what || message.cmd || message.type)) || '?';
      var _clearTrack = (typeof __bbTrackPending === 'function') ? __bbTrackPending('onMessage:' + _mwhat) : null;
      function _doneTrack() { if (_clearTrack) { _clearTrack(); _clearTrack = null; } }

      function sendResponse(value) {
        if (responded) { return; }
        responded = true;
        _doneTrack();
        var _payload = JSON.stringify({ value: (value === undefined ? null : value) });
        // Diagnostic: a worker reply that tells a page to close itself (Tampermonkey's install-confirmation
        // "ask" page does `please_close → window.close` when its askCom hits an error such as unknown_id —
        // i.e. the in-memory install-dialog state was lost). Surfacing it names WHY an install popup
        // "loads for a second then disappears" instead of leaving it invisible in the message stream.
        if (_payload.indexOf('please_close') >= 0 || _payload.indexOf('unknown_id') >= 0) {
          __bb_log('error', '[dispatchMessage] ' + _mwhat + ' reply asks page to close (please_close/unknown_id) — dialog/handshake state missing in this worker: ' + _payload.slice(0, 200));
        }
        __bb_message_response(responseId, _payload);
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
            promise.then(function (v) { sendResponse(v); }, function (e) { __bb_log('error', 'onMessage async listener rejected: ' + (e && e.message ? e.message : e)); sendResponse(undefined); });
          })(returned);
        }
        if (responded) { break; }
      }

      if (responded) { return; }
      if (willRespondAsync) {
        // An extension listener returned `true`, claiming it will call sendResponse asynchronously.
        // Chrome's pattern is `onMessage(req).then(cb)` — if onMessage's promise REJECTS, cb is never
        // called and the sender hangs forever (uBO Lite's popup showed infinite loading on the slider).
        // Belt-and-suspenders safety net: if sendResponse hasn't fired within 30s, force-send null so
        // the sender unblocks with a defined error state rather than hanging forever. 30s is intentionally
        // longer than the native watchdog (10s) — the watchdog will fire and name the stuck message first,
        // giving us a log entry; this timer just ensures eventual resolution.
        var _safetyTimer = setTimeout(function () {
          if (!responded) {
            __bb_log('error', '[dispatchMessage] onMessage:' + _mwhat + ' — listener returned true but sendResponse never called after 30s; force-responding null to unblock sender');
            sendResponse(null);
          }
        }, 30000);
        var _origSendResponse = sendResponse;
        sendResponse = function (value) { clearTimeout(_safetyTimer); _origSendResponse(value); };
        return;   // native waits (with a timeout) for an async sendResponse; the
                  // tracker stays until sendResponse fires (or the sweep names it)
      }
      _doneTrack();
      // Distinguish "no onMessage listener at all" (→ Chrome's "Could not establish connection.
      // Receiving end does not exist." on the sender) from a listener that declined (received but
      // returned nothing → the sender resolves undefined with no lastError).
      __bb_message_response(responseId,
        messageListeners.length === 0 ? JSON.stringify({ __bbNoListener: true }) : null);
    },

    // The MV3 User Scripts channel twin of dispatchMessage: a USER_SCRIPT-world script's
    // chrome.runtime.sendMessage lands on chrome.runtime.onUserScriptMessage (NOT onMessage). Same
    // request/response + async-sendResponse contract; uses the same __bb_message_response slot.
    dispatchUserScriptMessage: function (messageJSON, senderJSON, responseId) {
      var message = parseJSON(messageJSON);
      var sender = parseJSON(senderJSON) || {};
      var responded = false, willRespondAsync = false;
      function sendResponse(value) {
        if (responded) { return; }
        responded = true;
        __bb_message_response(responseId, JSON.stringify({ value: (value === undefined ? null : value) }));
      }
      for (var i = 0; i < userScriptMessageListeners.length; i++) {
        var returned;
        try { returned = userScriptMessageListeners[i](message, sender, sendResponse); }
        catch (e) { __bb_log('error', 'runtime.onUserScriptMessage listener threw: ' + (e && e.message ? e.message : e)); continue; }
        if (returned === true) { willRespondAsync = true; }
        else if (returned && typeof returned.then === 'function') {
          willRespondAsync = true;
          (function (promise) { promise.then(function (v) { sendResponse(v); }, function (e) { __bb_log('error', 'onMessage async listener rejected: ' + (e && e.message ? e.message : e)); sendResponse(undefined); }); })(returned);
        }
        if (responded) { break; }
      }
      if (responded || willRespondAsync) { return; }
      __bb_message_response(responseId,
        userScriptMessageListeners.length === 0 ? JSON.stringify({ __bbNoListener: true }) : null);
    },

    dispatchAlarm: function (alarmJSON) {
      // Native sends the real Alarm object (name + scheduledTime + periodInMinutes), not just a name —
      // so onAlarm reports the actual scheduled time and period, like Chrome.
      var alarm = parseJSON(alarmJSON);
      if (!alarm || typeof alarm !== 'object') { alarm = { name: '', scheduledTime: Date.now() }; }
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
      // Fan to the matching per-area StorageArea.onChanged listeners (signature: (changes) only).
      var areaLs = areaStorageListeners[areaName] || [];
      for (var j = 0; j < areaLs.length; j++) {
        try { areaLs[j](changes); } catch (e) { __bb_log('error', 'storage.' + areaName + '.onChanged listener threw: ' + (e && e.message ? e.message : e)); }
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

    dispatchIdleStateChanged: function (state) {
      for (var i = 0; i < idleStateListeners.length; i++) {
        try { idleStateListeners[i](state); }
        catch (e) { __bb_log('error', 'idle.onStateChanged listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    dispatchDownloadEvent: function (kind, payloadJSON) {
      var payload = parseJSON(payloadJSON);
      var list = kind === 'onCreated' ? downloadCreatedListeners
        : kind === 'onChanged' ? downloadChangedListeners
        : kind === 'onErased' ? downloadErasedListeners : null;
      if (!list) { return; }
      for (var i = 0; i < list.length; i++) {
        try { list[i](payload); }
        catch (e) { __bb_log('error', 'downloads.' + kind + ' listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    dispatchExtEvent: function (name, argsJSON) {
      var args = parseJSON(argsJSON);
      if (!Array.isArray(args)) { args = []; }
      var list = tabEventLists[name] || webNavLists[name] || permissionsEventLists[name];
      if (!list) { return; }
      for (var i = 0; i < list.length; i++) {
        try { list[i].apply(null, args); }
        catch (e) { __bb_log('error', name + ' listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },

    // chrome.runtime.onConnect: a content script / page opened a port to this worker. nameJSON and
    // senderJSON are JSON strings (the sender is the {id,url} object); build the port, register it by
    // id, and fire onConnect. dispatchPortMessage/Disconnect fan into that port's listener lists.
    dispatchPortConnect: function (portId, nameJSON, senderJSON) {
      var name = parseJSON(nameJSON);
      var sender = parseJSON(senderJSON);
      var port = makeWorkerPort(portId, typeof name === 'string' ? name : '', sender || null);
      ports[portId] = port;
      for (var i = 0; i < connectListeners.length; i++) {
        try { connectListeners[i](port); }
        catch (e) { __bb_log('error', 'runtime.onConnect listener threw: ' + (e && e.message ? e.message : e)); }
      }
    },
    dispatchPortMessage: function (portId, messageJSON) {
      var p = ports[portId];
      if (p) { p._fireMessage(parseJSON(messageJSON)); }
    },
    dispatchPortDisconnect: function (portId) {
      var p = ports[portId];
      if (p) { delete ports[portId]; p._fireDisconnect(); }
    },

    fireInstalled: function (reason, previousVersion) {
      // chrome.runtime.onInstalled details: reason is 'install' | 'update'; an 'update' carries the
      // previousVersion so extensions can run version-gated migrations (a no-op for a fresh install).
      var details = { reason: reason || 'install' };
      if (previousVersion) { details.previousVersion = previousVersion; }
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

  // Boot-instance marker: a fresh tag every time this worker source is (re)evaluated. Two different tags
  // for the same extension in the device log mean the background JSContext was TORN DOWN AND RESTARTED —
  // which wipes all in-memory state (e.g. Tampermonkey's install-dialog registry, keyed by an ask-id),
  // making an install-confirmation popup vanish ("unknown_id"). One stable tag across an install = the
  // worker survived and the bug is elsewhere.
  try {
    var __bbBootTag = ((typeof Date !== 'undefined' && Date.now) ? Date.now() : 0).toString(36).slice(-6);
    __bb_log('info', '[bb-bg] worker boot ' + __bbBootTag + ' ext=' + extId);
  } catch (e) { /* logging is best-effort */ }
})();
