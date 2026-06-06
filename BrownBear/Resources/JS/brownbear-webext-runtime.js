//
// brownbear-webext-runtime.js
//
// The injected runtime for browser EXTENSIONS (Module 6). Like the userscript runtime, it lives in
// one isolated-world closure: the native bridge and loaded content scripts stay private, identity
// is native-bound via a per-injection token, and each content script gets a `chrome`/`browser`
// surface (storage, runtime, i18n, extension) namespaced to its extension.
//
// Supported here: content_scripts injection (js + css) at @run-at, chrome.storage.{local,sync,
// session}, chrome.runtime (id/getManifest/getURL/sendMessage stub/onMessage stub), chrome.i18n
// (preloaded default-locale messages), chrome.extension.getURL. See docs/WEB_EXTENSIONS.md.

(function () {
  "use strict";
  if (window.__brownbearWebext) { return; }

  var W = window;
  var _JSON = JSON;
  var _Object = Object;
  var _Array = Array;
  var _Promise = Promise;
  var _Function = Function;
  var _console = W.console || { log: function () {}, error: function () {} };
  var handler = (W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.brownbearWebext) || null;

  function bridge(api, payload, token) {
    if (!handler) { return _Promise.reject(new Error("BrownBear extension bridge unavailable")); }
    try { return handler.postMessage({ api: api, payload: payload || {}, token: token || null }); }
    catch (e) { return _Promise.reject(e); }
  }

  // --- chrome.* surface for one content script ------------------------------------------------
  function buildChrome(data) {
    var token = data.token;
    var manifest = {};
    try { manifest = _JSON.parse(data.manifestJSON || "{}"); } catch (e) { manifest = {}; }
    var messages = data.messages || {};

    function settle(promise, callback) {
      if (typeof callback === "function") { promise.then(function (v) { callback(v); }, function () { callback(undefined); }); return undefined; }
      return promise;
    }

    function storageArea(area) {
      function get(keys, callback) {
        if (typeof keys === "function") { callback = keys; keys = null; }
        var keyList = null, defaults = null;
        if (typeof keys === "string") { keyList = [keys]; }
        else if (_Array.isArray(keys)) { keyList = keys; }
        else if (keys && typeof keys === "object") { defaults = keys; keyList = _Object.keys(keys); }
        var promise = bridge("storage.get", { area: area, keys: keyList }, token).then(function (raw) {
          var out = {};
          if (defaults) { _Object.keys(defaults).forEach(function (k) { out[k] = defaults[k]; }); }
          var map = raw || {};
          _Object.keys(map).forEach(function (k) { try { out[k] = _JSON.parse(map[k]); } catch (e) { out[k] = map[k]; } });
          return out;
        });
        return settle(promise, callback);
      }
      function set(items, callback) {
        var enc = {};
        _Object.keys(items || {}).forEach(function (k) { enc[k] = _JSON.stringify(items[k]); });
        return settle(bridge("storage.set", { area: area, items: enc }, token).then(function () { return undefined; }), callback);
      }
      function remove(keys, callback) {
        var list = typeof keys === "string" ? [keys] : (keys || []);
        return settle(bridge("storage.remove", { area: area, keys: list }, token).then(function () { return undefined; }), callback);
      }
      function clear(callback) {
        return settle(bridge("storage.clear", { area: area }, token).then(function () { return undefined; }), callback);
      }
      return { get: get, set: set, remove: remove, clear: clear };
    }

    function getURL(path) {
      var p = String(path || "");
      return data.baseURL + (p.charAt(0) === "/" ? p.slice(1) : p);
    }

    function i18nGetMessage(key, substitutions) {
      var entry = messages[key];
      var text = entry ? entry : "";
      if (substitutions != null) {
        var subs = _Array.isArray(substitutions) ? substitutions : [substitutions];
        text = text.replace(/\$(\d+)\$?/g, function (_, n) { var i = parseInt(n, 10) - 1; return subs[i] != null ? subs[i] : ""; });
      }
      return text;
    }

    var noopEvent = { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } };

    var chrome = {
      storage: {
        local: storageArea("local"),
        sync: storageArea("sync"),
        session: storageArea("session"),
        onChanged: noopEvent
      },
      runtime: {
        id: data.extensionId,
        getManifest: function () { return manifest; },
        getURL: getURL,
        sendMessage: function () {
          var cb = arguments.length ? arguments[arguments.length - 1] : null;
          if (typeof cb === "function") { cb(undefined); return undefined; }
          return _Promise.resolve(undefined);
        },
        onMessage: noopEvent,
        onConnect: noopEvent,
        onInstalled: noopEvent,
        connect: function () { return { name: "", onMessage: noopEvent, onDisconnect: noopEvent, postMessage: function () {}, disconnect: function () {} }; },
        lastError: null,
        getPlatformInfo: function (cb) { var info = { os: "ios", arch: "arm64", nacl_arch: "arm64" }; if (typeof cb === "function") { cb(info); return undefined; } return _Promise.resolve(info); }
      },
      i18n: {
        getMessage: i18nGetMessage,
        getUILanguage: function () { return (W.navigator && W.navigator.language) || "en"; },
        getAcceptLanguages: function (cb) { var langs = [(W.navigator && W.navigator.language) || "en"]; if (typeof cb === "function") { cb(langs); return undefined; } return _Promise.resolve(langs); }
      },
      extension: {
        getURL: getURL,
        inIncognitoContext: false
      }
    };
    return chrome;
  }

  function runContentScript(data) {
    var chrome = buildChrome(data);
    if (data.css) {
      try {
        var style = document.createElement("style");
        style.textContent = data.css;
        (document.head || document.documentElement).appendChild(style);
      } catch (e) { /* ignore */ }
    }
    if (data.js) {
      var sourceURL = "//# sourceURL=chrome-extension://" + data.extensionId + "/content.js";
      try {
        var fn = _Function("chrome", "browser", "window", "self", "globalThis", data.js + "\n" + sourceURL);
        fn.call(W, chrome, chrome, W, W, W);
      } catch (e) {
        if (_console.error) { _console.error("[BrownBear ext] content script error:", e); }
      }
    }
  }

  // --- Loader (run-at gating, same readyState discipline as the userscript runtime) -----------
  function runAll(list) { for (var i = 0; i < list.length; i += 1) { runContentScript(list[i]); } }
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
    bridge("getContentScripts", { url: location.href, isSubframe: isSubframe }, null)
      .then(function (scripts) {
        if (!scripts || !scripts.length) { return; }
        var starts = [], ends = [], idles = [];
        for (var i = 0; i < scripts.length; i += 1) {
          var s = scripts[i];
          if (s.runAt === "document_start") { starts.push(s); }
          else if (s.runAt === "document_idle") { idles.push(s); }
          else { ends.push(s); }
        }
        if (starts.length) { runAll(starts); }
        if (ends.length) { whenDOMReady(function () { runAll(ends); }); }
        if (idles.length) { whenLoaded(function () { runAll(idles); }); }
      })
      .catch(function (e) { if (_console.error) { _console.error("[BrownBear ext] loader error:", e); } });
  }

  W.__brownbearWebext = { version: 1 };
  loadAndRun();
})();
