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

    function fetch(input, init) {
      init = init || {};
      var url, method = 'GET', headers = {}, body = null, bodyEncoding = 'utf8';
      if (input && typeof input === 'object' && input.url) { url = String(input.url); method = input.method || method; }
      else { url = String(input); }
      if (init.method) { method = init.method; }
      // Resolve a relative URL ('/path' or 'path') against the worker's own origin, so fetching a
      // PACKAGED resource (e.g. ScriptCat's fetch('/src/content.js')) reaches the extension scheme
      // handler instead of an unparseable bare path. Absolute URLs pass through unchanged.
      try {
        var __fetchBase = (globalThis.location && globalThis.location.href) || globalThis.__bbBgBaseURL;
        if (__fetchBase) { url = new globalThis.URL(url, __fetchBase).href; }
      } catch (e) { /* leave url as written */ }
      if (init.headers) {
        if (init.headers._m) { headers = init.headers._m; }                       // our Headers instance
        else if (typeof init.headers.forEach === 'function') {                    // a Map
          init.headers.forEach(function (v, k) { headers[k] = v; });
        } else { headers = init.headers; }                                        // a plain object
      }
      if (init.body != null) {
        var hasCT = false;
        for (var hk in headers) { if (hk.toLowerCase() === 'content-type') { hasCT = true; break; } }
        if (typeof init.body === 'string') { body = init.body; bodyEncoding = 'utf8'; }
        else if (typeof URLSearchParams === 'function' && init.body instanceof URLSearchParams) {
          // x-www-form-urlencoded — serialize via the params' own toString, not JSON.
          body = init.body.toString(); bodyEncoding = 'utf8';
          if (!hasCT) { headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8'; }
        } else if (typeof FormData === 'function' && init.body instanceof FormData
                   && typeof init.body.__bbSerialize === 'function') {
          var fd = init.body.__bbSerialize();   // multipart/form-data with a boundary
          body = fd.body; bodyEncoding = 'utf8';
          if (!hasCT) { headers['Content-Type'] = fd.contentType; }
        } else if (init.body instanceof ArrayBuffer || (init.body.buffer instanceof ArrayBuffer)) {
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
        for (var k in items) { if (Object.prototype.hasOwnProperty.call(items, k)) { enc[k] = JSON.stringify(items[k]); } }
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
    onConnect: makeEvent(connectListeners),
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

  // ---------------------------------------------------------------- chrome.webRequest (observe-only no-op)
  // WebKit can't intercept network requests, so these listeners never fire — but the event objects must
  // EXIST so extensions that register handlers (ScriptCat, ad blockers) don't throw "undefined is not an
  // object" on access. Blocking/redirect is handled via declarativeNetRequest where expressible.
  var webRequest = {
    onBeforeRequest: makeEvent([]), onBeforeSendHeaders: makeEvent([]), onSendHeaders: makeEvent([]),
    onHeadersReceived: makeEvent([]), onBeforeRedirect: makeEvent([]), onAuthRequired: makeEvent([]),
    onResponseStarted: makeEvent([]), onCompleted: makeEvent([]), onErrorOccurred: makeEvent([]),
    onActionIgnored: makeEvent([]),
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

  // ---------------------------------------------------------------- chrome.offscreen (unsupported)
  // Offscreen documents need a hidden DOM host iOS/WebKit can't give a headless worker. Present the API
  // so an extension that calls chrome.offscreen.createDocument doesn't crash on it being undefined;
  // createDocument rejects (well-behaved callers fall back, as ScriptCat already does). hasDocument is
  // false and closeDocument is a no-op.
  var offscreen = {
    Reason: { AUDIO_PLAYBACK: 'AUDIO_PLAYBACK', BLOBS: 'BLOBS', CLIPBOARD: 'CLIPBOARD',
              DISPLAY_MEDIA: 'DISPLAY_MEDIA', DOM_PARSER: 'DOM_PARSER', DOM_SCRAPING: 'DOM_SCRAPING',
              GEOLOCATION: 'GEOLOCATION', IFRAME_SCRIPTING: 'IFRAME_SCRIPTING', LOCAL_STORAGE: 'LOCAL_STORAGE',
              MATCH_MEDIA: 'MATCH_MEDIA', TESTING: 'TESTING', USER_MEDIA: 'USER_MEDIA', WORKERS: 'WORKERS' },
    createDocument: function (_opts, cb) {
      var err = new Error('chrome.offscreen is not supported on this platform');
      if (typeof cb === 'function') { cb(); return undefined; }
      return Promise.reject(err);
    },
    closeDocument: function (cb) { if (typeof cb === 'function') { cb(); return undefined; } return Promise.resolve(); },
    hasDocument: function (cb) { if (typeof cb === 'function') { cb(false); return undefined; } return Promise.resolve(false); }
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
    // Chrome exposes these enums + limits as constants on chrome.declarativeNetRequest; extensions read
    // them directly (e.g. ResourceType.MAIN_FRAME). Their absence throws "undefined is not an object".
    ResourceType: { MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other' },
    RuleActionType: { BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests' },
    HeaderOperation: { APPEND: 'append', SET: 'set', REMOVE: 'remove' },
    DomainType: { FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty' },
    UnsupportedRegexReason: { SYNTAX_ERROR: 'syntaxError', MEMORY_LIMIT_EXCEEDED: 'memoryLimitExceeded' },
    DYNAMIC_RULESET_ID: '_dynamic', SESSION_RULESET_ID: '_session',
    MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000,
    MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
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
    configureWorld: function (properties, cb) { return settleBg(userScriptsCall('configureWorld', { properties: properties || {} }).then(function () { return undefined; }), cb); },
    resetWorldConfiguration: function (worldId, cb) {
      if (typeof worldId === 'function') { cb = worldId; worldId = null; }
      return settleBg(userScriptsCall('resetWorldConfiguration', { worldId: worldId || null }).then(function () { return undefined; }), cb);
    }
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
    onSignInChanged: makeEvent([])
  };

  var chrome = {
    runtime: runtime,
    identity: identity,
    storage: storage,
    cookies: cookies,
    notifications: notifications,
    windows: windows,
    management: management,
    permissions: permissions,
    declarativeNetRequest: declarativeNetRequest,
    userScripts: userScripts,
    webNavigation: webNavigation,
    webRequest: webRequest,
    offscreen: offscreen,
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
      if (willRespondAsync) { return; }   // native waits (with a timeout) for an async sendResponse
      // Distinguish "no onMessage listener at all" (→ Chrome's "Could not establish connection.
      // Receiving end does not exist." on the sender) from a listener that declined (received but
      // returned nothing → the sender resolves undefined with no lastError).
      __bb_message_response(responseId,
        messageListeners.length === 0 ? JSON.stringify({ __bbNoListener: true }) : null);
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
})();
