//
//  brownbear-jscore-globals.js
//  BrownBear
//
//  Web globals JavaScriptCore does not provide, installed into a headless JSContext (the userscript
//  background runner). Pure JS, no DOM. Loaded by HeadlessScriptRunner's prelude so background
//  userscripts that reach for `URL`, `URLSearchParams`, or `performance` run instead of throwing
//  "Can't find variable: URL". Each is installed only if absent, so it never clobbers a real one.
//

(function () {
  'use strict';
  var g = (typeof globalThis !== 'undefined') ? globalThis : this;

  if (typeof g.URLSearchParams !== 'function') {
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
    g.URLSearchParams = USP;
  }

  if (typeof g.URL !== 'function') {
    var resolveURL = function (input, base) {
      if (/^[a-zA-Z][a-zA-Z0-9+.\-]*:/.test(input)) { return input; }
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
      this.searchParams = new g.URLSearchParams(m[9] || '');
    };
    Object.defineProperty(URLImpl.prototype, 'search', {
      get: function () { var s = this.searchParams.toString(); return s ? '?' + s : ''; },
      set: function (v) { this.searchParams = new g.URLSearchParams(v); }
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
    g.URL = URLImpl;
  }

  if (typeof g.performance === 'undefined') {
    var origin = Date.now();
    g.performance = {
      timeOrigin: origin,
      now: function () { return Date.now() - origin; },
      mark: function () {}, measure: function () {},
      clearMarks: function () {}, clearMeasures: function () {},
      getEntries: function () { return []; },
      getEntriesByName: function () { return []; },
      getEntriesByType: function () { return []; }
    };
  }

  // navigator — userscripts (Violentmonkey/ScriptCat sign-in helpers) routinely read
  // navigator.userAgent/.language/.platform to branch behaviour. JSC has no DOM, so a bare reference
  // throws "Can't find variable: navigator". Honest values come from native (__bbUserAgent /
  // __bbLanguage, device-derived) with a static Mobile-Safari fallback so this is never undefined.
  if (typeof g.navigator === 'undefined') {
    var ua = (typeof g.__bbUserAgent === 'string' && g.__bbUserAgent)
      ? g.__bbUserAgent
      : 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
        + '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    var lang = (typeof g.__bbLanguage === 'string' && g.__bbLanguage) ? g.__bbLanguage : 'en-US';
    var platform = ua.indexOf('iPad') >= 0 ? 'iPad' : (ua.indexOf('iPhone') >= 0 ? 'iPhone' : 'MacIntel');
    var langs = [lang];
    var langBase = lang.split('-')[0];
    if (langBase && langBase !== lang) { langs.push(langBase); }
    g.navigator = {
      userAgent: ua,
      appVersion: ua.replace(/^Mozilla\//, ''),
      appName: 'Netscape',
      appCodeName: 'Mozilla',
      product: 'Gecko',
      productSub: '20030107',
      vendor: 'Apple Computer, Inc.',
      vendorSub: '',
      platform: platform,
      language: lang,
      languages: langs,
      onLine: true,
      cookieEnabled: true,
      doNotTrack: null,
      webdriver: false,
      hardwareConcurrency: 4,
      maxTouchPoints: 5,
      pdfViewerEnabled: false,
      sendBeacon: function () { return false; },
      javaEnabled: function () { return false; },
      vibrate: function () { return false; },
      taintEnabled: function () { return false; }
    };
  }

  // location — a background userscript has no page, so this defaults to about:blank (native may pass a
  // different __bbHeadlessLocation). Scripts read location.href/.hostname/.origin; the navigation
  // methods (assign/replace/reload) are inert because there is nothing to navigate. Defined as a real
  // object (not the URL polyfill, which lacks those methods) so neither reads nor calls throw.
  if (typeof g.location === 'undefined') {
    var locHref = (typeof g.__bbHeadlessLocation === 'string' && g.__bbHeadlessLocation)
      ? g.__bbHeadlessLocation : 'about:blank';
    var locURL = null;
    try { locURL = new g.URL(locHref); } catch (e) { locURL = null; }
    g.location = {
      href: locHref,
      protocol: locURL ? locURL.protocol : 'about:',
      host: locURL ? locURL.host : '',
      hostname: locURL ? locURL.hostname : '',
      port: locURL ? locURL.port : '',
      pathname: locURL ? locURL.pathname : 'blank',
      search: locURL ? locURL.search : '',
      hash: locURL ? locURL.hash : '',
      origin: locURL ? locURL.origin : 'null',
      assign: function () {},
      replace: function () {},
      reload: function () {},
      toString: function () { return this.href; }
    };
  }
})();
