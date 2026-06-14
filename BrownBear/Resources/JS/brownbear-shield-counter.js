"use strict";
//
//  brownbear-shield-counter.js
//  BrownBear
//
//  A PAGE-WORLD, document-start, all-frames observer that gives BrownBear a REAL "requests blocked"
//  count — the number WKContentRuleList (the only iOS network-blocking primitive) refuses to report.
//  WebKit cancels a blocked subresource silently: the app is never told, so BrownBear's Shields panel
//  (and a webRequest-based extension like uBlock Origin) can only ever show "0 blocked". We recover a
//  count at the one place it IS observable — the moment a page *initiates* a request. We wrap the
//  request-starting APIs (fetch / XMLHttpRequest / sendBeacon / EventSource / WebSocket and the
//  src/href setters of script/img/iframe/link/media elements), read the destination host, and report
//  it to native, which matches it against the active blocklist and tallies per tab. WebKit still does
//  the actual blocking; we only COUNT what the page tried to load.
//
//  Trust + safety (CLAUDE.md §5): this runs in the UNTRUSTED page world. It performs no privileged
//  action — it posts a {host: count} map to a dedicated message handler that only increments a display
//  counter. Every wrapper is a TRANSPARENT pass-through: it captures the original at document-start,
//  calls it with the original `this`/arguments, returns its exact result, and runs the (try/caught)
//  host-recording as a pure side effect, so a bug here can never change a request's behavior or break
//  the page. Wrappers preserve name/length and a native-looking toString so a site self-checking
//  `fetch.toString()` isn't tripped. Reporting is debounced + deduped (host→count map flushed on a
//  timer) and host-capped, so a request flood can't spam the bridge.
//
(function () {
  var W = window;
  // Capture EVERYTHING we touch at document-start, before any page script can replace it.
  var _postMessage = null;
  try {
    if (W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.brownbearShieldCounter) {
      var _h = W.webkit.messageHandlers.brownbearShieldCounter;
      _postMessage = function (msg) { try { _h.postMessage(msg); } catch (e) { /* handler gone */ } };
    }
  } catch (e) { /* no handler — nothing to do */ }
  if (!_postMessage) { return; }

  var _URL = W.URL;
  var _setTimeout = W.setTimeout ? W.setTimeout.bind(W) : null;
  var _ObjectDefineProperty = Object.defineProperty;
  var _ObjectGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
  var _FunctionToString = Function.prototype.toString;
  if (!_URL || !_setTimeout) { return; }

  var _location = W.location;
  var _baseHref = "";
  try { _baseHref = _location.href; } catch (e) { _baseHref = ""; }

  // --- reporting: host -> count, flushed on a debounce timer ----------------------------------------
  var MAX_HOSTS = 512;            // cap the per-flush map so a wildcard-domain flood can't grow it
  var FLUSH_MS = 1000;
  var pending = Object.create(null);
  var pendingHostCount = 0;
  var flushScheduled = false;

  function flush() {
    flushScheduled = false;
    var batch = pending;
    pending = Object.create(null);
    pendingHostCount = 0;
    var any = false;
    for (var k in batch) { if (Object.prototype.hasOwnProperty.call(batch, k)) { any = true; break; } }
    if (any) { _postMessage({ hosts: batch }); }
  }
  function scheduleFlush() {
    if (flushScheduled) { return; }
    flushScheduled = true;
    _setTimeout(flush, FLUSH_MS);
  }

  // Pull the host out of a request target (string URL, URL object, or Request-like with a .url),
  // resolved against the document base. Returns "" on anything unparseable.
  function hostOf(target) {
    try {
      var raw;
      if (target == null) { return ""; }
      if (typeof target === "string") { raw = target; }
      else if (typeof target === "object" && typeof target.url === "string") { raw = target.url; }  // Request
      else if (typeof target === "object" && typeof target.href === "string") { raw = target.href; } // URL/anchor
      else { raw = String(target); }
      if (!raw) { return ""; }
      // Ignore obvious non-network schemes cheaply before constructing a URL.
      if (raw.charCodeAt(0) === 35 /* # */) { return ""; }
      var lower = raw.slice(0, 12).toLowerCase();
      if (lower.indexOf("data:") === 0 || lower.indexOf("blob:") === 0 || lower.indexOf("about:") === 0
          || lower.indexOf("javascript:") === 0 || lower.indexOf("mailto:") === 0) { return ""; }
      var u = new _URL(raw, _baseHref || undefined);
      var scheme = (u.protocol || "").toLowerCase();
      if (scheme !== "http:" && scheme !== "https:" && scheme !== "ws:" && scheme !== "wss:") { return ""; }
      return (u.hostname || "").toLowerCase();
    } catch (e) { return ""; }
  }

  function record(target) {
    try {
      var host = hostOf(target);
      if (!host) { return; }
      if (Object.prototype.hasOwnProperty.call(pending, host)) { pending[host] += 1; }
      else {
        if (pendingHostCount >= MAX_HOSTS) { return; }   // bounded — drop new hosts past the cap
        pending[host] = 1; pendingHostCount += 1;
      }
      scheduleFlush();
    } catch (e) { /* recording must never affect the page */ }
  }

  // Make a wrapper look like the function it replaces: same name/length, native-shaped toString. A site
  // that fingerprints `fn.toString()` sees "[native code]" exactly as for the real builtin.
  function disguise(wrapper, original, name) {
    try { _ObjectDefineProperty(wrapper, "name", { value: name || (original && original.name) || "", configurable: true }); } catch (e) {}
    try { _ObjectDefineProperty(wrapper, "length", { value: (original && original.length) || 0, configurable: true }); } catch (e) {}
    try {
      var nativeStr = "function " + (name || (original && original.name) || "") + "() { [native code] }";
      _ObjectDefineProperty(wrapper, "toString", {
        value: function toString() { return nativeStr; }, writable: true, configurable: true
      });
    } catch (e) {}
    return wrapper;
  }

  // --- fetch ----------------------------------------------------------------------------------------
  try {
    if (typeof W.fetch === "function") {
      var _fetch = W.fetch;
      var fetchWrapper = function fetch(input) {
        try { record(input); } catch (e) {}
        return _fetch.apply(this, arguments);
      };
      W.fetch = disguise(fetchWrapper, _fetch, "fetch");
    }
  } catch (e) {}

  // --- XMLHttpRequest.open --------------------------------------------------------------------------
  try {
    if (W.XMLHttpRequest && W.XMLHttpRequest.prototype && typeof W.XMLHttpRequest.prototype.open === "function") {
      var _open = W.XMLHttpRequest.prototype.open;
      var openWrapper = function open(method, url) {
        try { record(url); } catch (e) {}
        return _open.apply(this, arguments);
      };
      W.XMLHttpRequest.prototype.open = disguise(openWrapper, _open, "open");
    }
  } catch (e) {}

  // --- navigator.sendBeacon -------------------------------------------------------------------------
  try {
    if (W.navigator && typeof W.navigator.sendBeacon === "function") {
      var _beacon = W.navigator.sendBeacon;
      var beaconWrapper = function sendBeacon(url) {
        try { record(url); } catch (e) {}
        return _beacon.apply(this, arguments);
      };
      W.navigator.sendBeacon = disguise(beaconWrapper, _beacon, "sendBeacon");
    }
  } catch (e) {}

  // --- EventSource / WebSocket (constructors take the URL first) ------------------------------------
  function wrapURLConstructor(ctorName) {
    try {
      var Ctor = W[ctorName];
      if (typeof Ctor !== "function") { return; }
      var Wrapped = function (url) {
        try { record(url); } catch (e) {}
        // `new Ctor(...arguments)` without spread (ES5 target): bind + apply through a constructor.
        var bound = Function.prototype.bind.apply(Ctor, [null].concat(Array.prototype.slice.call(arguments)));
        return new bound();
      };
      try { Wrapped.prototype = Ctor.prototype; } catch (e) {}
      // Copy static props (e.g. WebSocket.CONNECTING) so feature checks still pass.
      try {
        var keys = Object.getOwnPropertyNames(Ctor);
        for (var i = 0; i < keys.length; i++) {
          var key = keys[i];
          if (key === "prototype" || key === "name" || key === "length" || key === "arguments" || key === "caller") { continue; }
          try { Wrapped[key] = Ctor[key]; } catch (e2) {}
        }
      } catch (e3) {}
      W[ctorName] = disguise(Wrapped, Ctor, ctorName);
    } catch (e) {}
  }
  wrapURLConstructor("WebSocket");
  wrapURLConstructor("EventSource");

  // --- element src/href setters (script/img/iframe/link/audio/video/source/track) -------------------
  // Intercept the property setter on each prototype so assigning `el.src = adURL` is observed. The
  // getter/setter delegate to the captured originals, so the element behaves identically.
  function wrapURLAttr(proto, attr) {
    try {
      if (!proto) { return; }
      var desc = _ObjectGetOwnPropertyDescriptor(proto, attr);
      if (!desc || !desc.set || !desc.configurable) { return; }
      var origGet = desc.get, origSet = desc.set;
      _ObjectDefineProperty(proto, attr, {
        configurable: true, enumerable: desc.enumerable,
        get: function () { return origGet ? origGet.call(this) : undefined; },
        set: function (value) {
          try { record(value); } catch (e) {}
          return origSet.call(this, value);
        }
      });
    } catch (e) {}
  }
  try {
    var HE = W.HTMLElement;
    wrapURLAttr(W.HTMLScriptElement && W.HTMLScriptElement.prototype, "src");
    wrapURLAttr(W.HTMLImageElement && W.HTMLImageElement.prototype, "src");
    wrapURLAttr(W.HTMLIFrameElement && W.HTMLIFrameElement.prototype, "src");
    // NOTE: we deliberately DO NOT wrap HTMLMediaElement / HTMLSourceElement `src`. Redefining the media
    // element's `src` accessor (even as a transparent delegate) can break <video>/<audio> playback —
    // it stalls at 0s — for reasons internal to WebKit's resource-selection / media pipeline. The only
    // thing we'd gain is COUNTING media requests in the Shields tally; WebKit still BLOCKS them via the
    // content-rule list regardless, so the loss is just a stat. Never touch the media element here.
    wrapURLAttr(W.HTMLLinkElement && W.HTMLLinkElement.prototype, "href");    // stylesheets, preloads
  } catch (e) {}

  // setAttribute('src'|'href', url) bypasses the property setter — cover it too.
  try {
    var EP = W.Element && W.Element.prototype;
    if (EP && typeof EP.setAttribute === "function") {
      var _setAttribute = EP.setAttribute;
      var setAttrWrapper = function setAttribute(name, value) {
        try {
          if (typeof name === "string") {
            var n = name.toLowerCase();
            if (n === "src" || n === "href" || n === "data" || n === "poster") { record(value); }
          }
        } catch (e) {}
        return _setAttribute.apply(this, arguments);
      };
      EP.setAttribute = disguise(setAttrWrapper, _setAttribute, "setAttribute");
    }
  } catch (e) {}
})();
