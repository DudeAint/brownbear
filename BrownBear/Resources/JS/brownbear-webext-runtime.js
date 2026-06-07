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

    function tabsApi() {
      function query(queryInfo, callback) {
        return settle(bridge("tabs.query", { query: queryInfo || {} }, token), callback);
      }
      function get(tabId, callback) {
        return settle(bridge("tabs.get", { tabId: tabId }, token), callback);
      }
      function getCurrent(callback) {
        return settle(bridge("tabs.getCurrent", {}, token), callback);
      }
      function create(props, callback) {
        props = props || {};
        return settle(bridge("tabs.create", { url: props.url, active: props.active !== false }, token), callback);
      }
      function update(tabId, props, callback) {
        if (tabId !== null && typeof tabId === "object") { callback = props; props = tabId; tabId = undefined; }
        props = props || {};
        return settle(bridge("tabs.update", { tabId: tabId, url: props.url, active: props.active }, token), callback);
      }
      function remove(tabIds, callback) {
        var ids = _Array.isArray(tabIds) ? tabIds : [tabIds];
        return settle(bridge("tabs.remove", { tabIds: ids }, token).then(function () { return undefined; }), callback);
      }
      function reload(tabId, props, callback) {
        if (typeof tabId === "function") { callback = tabId; tabId = undefined; props = {}; }
        else if (tabId !== null && typeof tabId === "object") { callback = props; props = tabId; tabId = undefined; }
        props = props || {};
        return settle(bridge("tabs.reload", { tabId: tabId, bypassCache: !!props.bypassCache }, token).then(function () { return undefined; }), callback);
      }
      function sendMessage() {
        // Background↔content messaging (Phase 3) isn't wired yet; resolve undefined rather than hang.
        var args = _Array.prototype.slice.call(arguments);
        var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
        return settle(_Promise.resolve(undefined), cb);
      }
      function executeScript(tabId, details, callback) {
        if (tabId !== null && typeof tabId === "object") { callback = details; details = tabId; tabId = undefined; }
        details = details || {};
        return settle(bridge("tabs.executeScript", { tabId: tabId, code: details.code, file: details.file, world: details.world }, token), callback);
      }
      function insertCSS(tabId, details, callback) {
        if (tabId !== null && typeof tabId === "object") { callback = details; details = tabId; tabId = undefined; }
        details = details || {};
        return settle(bridge("tabs.insertCSS", { tabId: tabId, code: details.code, file: details.file }, token).then(function () { return undefined; }), callback);
      }
      return {
        query: query, get: get, getCurrent: getCurrent, create: create, update: update,
        remove: remove, reload: reload, sendMessage: sendMessage,
        executeScript: executeScript, insertCSS: insertCSS,
        onUpdated: noopEvent, onActivated: noopEvent, onCreated: noopEvent,
        onRemoved: noopEvent, onReplaced: noopEvent
      };
    }

    // chrome.scripting (MV3). func+args are serialized to a code string here; files/css go to native.
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
        executeScript: function (injection, callback) { return settle(bridge("scripting.executeScript", serialize(injection), token), callback); },
        insertCSS: function (injection, callback) { return settle(bridge("scripting.insertCSS", cssPayload(injection), token).then(function () { return undefined; }), callback); },
        removeCSS: function (injection, callback) { return settle(bridge("scripting.removeCSS", cssPayload(injection), token).then(function () { return undefined; }), callback); }
      };
    }

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
          // Overloaded like Chrome: (extensionId?, message, options?, callback?). We deliver to
          // this extension's own background worker and resolve with the listener's response value.
          var args = _Array.prototype.slice.call(arguments);
          var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
          var message = (typeof args[0] === "string" && args.length > 1) ? args[1] : args[0];
          var promise = bridge("runtime.sendMessage", { message: (message === undefined ? null : message), url: location.href }, token)
            .then(function (resp) { return resp ? resp.value : undefined; });
          return settle(promise, cb);
        },
        onMessage: noopEvent,
        onConnect: noopEvent,
        onInstalled: noopEvent,
        connect: function () { return { name: "", onMessage: noopEvent, onDisconnect: noopEvent, postMessage: function () {}, disconnect: function () {} }; },
        lastError: null,
        getPlatformInfo: function (cb) { var info = { os: "ios", arch: "arm64", nacl_arch: "arm64" }; if (typeof cb === "function") { cb(info); return undefined; } return _Promise.resolve(info); }
      },
      tabs: tabsApi(),
      scripting: scriptingApi(),
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

  W.__brownbearWebext = { version: 2 };
  loadAndRun();
})();
