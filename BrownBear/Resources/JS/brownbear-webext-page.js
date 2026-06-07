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

  var manifest = {};
  try { manifest = _JSON.parse(data.manifestJSON || "{}"); } catch (e) { manifest = {}; }
  var messages = data.messages || {};

  function settle(promise, callback) {
    if (typeof callback === "function") { promise.then(function (v) { callback(v); }, function () { callback(undefined); }); return undefined; }
    return promise;
  }

  function makeEvent(list) {
    return {
      addListener: function (fn) { if (typeof fn === "function" && list.indexOf(fn) < 0) { list.push(fn); } },
      removeListener: function (fn) { var i = list.indexOf(fn); if (i >= 0) { list.splice(i, 1); } },
      hasListener: function (fn) { return list.indexOf(fn) >= 0; }
    };
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
      return settle(bridge("storage.set", { area: area, items: enc }).then(function () { return undefined; }), callback);
    }
    function remove(keys, callback) {
      var list = typeof keys === "string" ? [keys] : (keys || []);
      return settle(bridge("storage.remove", { area: area, keys: list }).then(function () { return undefined; }), callback);
    }
    function clear(callback) {
      return settle(bridge("storage.clear", { area: area }).then(function () { return undefined; }), callback);
    }
    return { get: get, set: set, remove: remove, clear: clear };
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
    var noop = { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } };
    return {
      query: query, get: get, getCurrent: getCurrent, create: create, update: update, remove: remove, reload: reload,
      onUpdated: noop, onActivated: noop, onCreated: noop, onRemoved: noop
    };
  }

  var storageListeners = [];
  var messageListeners = [];

  var chrome = {
    storage: {
      local: storageArea("local"),
      sync: storageArea("sync"),
      session: storageArea("session"),
      onChanged: makeEvent(storageListeners)
    },
    runtime: {
      id: data.extensionId,
      getManifest: function () { return manifest; },
      getURL: getURL,
      onMessage: makeEvent(messageListeners),
      onConnect: { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } },
      onInstalled: { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } },
      sendMessage: function () {
        var args = _Array.prototype.slice.call(arguments);
        var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
        var message = (typeof args[0] === "string" && args.length > 1) ? args[1] : args[0];
        var promise = bridge("runtime.sendMessage", { message: (message === undefined ? null : message), url: location.href })
          .then(function (resp) { return resp ? resp.value : undefined; });
        return settle(promise, cb);
      },
      connect: function () { return { name: "", onMessage: makeEvent([]), onDisconnect: makeEvent([]), postMessage: function () {}, disconnect: function () {} }; },
      openOptionsPage: function (cb) { bridge("runtime.openOptionsPage", {}).catch(function () {}); if (typeof cb === "function") { cb(); } },
      lastError: null,
      getPlatformInfo: function (cb) { var info = { os: "ios", arch: "arm64", nacl_arch: "arm64" }; if (typeof cb === "function") { cb(info); return undefined; } return _Promise.resolve(info); }
    },
    tabs: tabsApi(),
    i18n: {
      getMessage: i18nGetMessage,
      getUILanguage: function () { return (W.navigator && W.navigator.language) || "en"; }
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
    }
  };
  W.__brownbearExtPageReady = true;
})();
