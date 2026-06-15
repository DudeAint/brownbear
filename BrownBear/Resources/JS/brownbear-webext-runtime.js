//
// brownbear-webext-runtime.js
//
// The injected runtime for browser EXTENSIONS (Module 6). Like the userscript runtime, it lives in
// one isolated-world closure: the native bridge and loaded content scripts stay private, identity
// is native-bound via a per-injection token, and each content script gets a `chrome`/`browser`
// surface (storage, runtime, i18n, extension) namespaced to its extension.
//
// Supported here: content_scripts injection (js + css) at @run-at, chrome.storage.{local,sync,
// session} with a live onChanged, chrome.runtime (id/getManifest/getURL/sendMessage to the worker +
// onMessage receiving tabs.sendMessage), chrome.tabs.sendMessage, chrome.i18n (preloaded
// default-locale messages), chrome.extension.getURL. See docs/WEB_EXTENSIONS.md.

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

  // Forward UNCAUGHT content-script errors (the isolated content world's failures are otherwise
  // invisible — the page console capture only sees the main world). We deliberately do NOT wrap
  // `console` here: in an isolated world it's the shared page console and wrapping it could disturb
  // the page. `__bbLogToken` is set to the first content script's token (best-effort attribution).
  var __bbLogToken = null;
  (function () {
    if (handler === null) { return; }
    function emit(message) {
      if (!__bbLogToken) { return; }
      var s = String(message);
      try { bridge("runtime.pageLog", { level: "error", message: "[content] " + (s.length > 4000 ? s.slice(0, 4000) + "…" : s) }, __bbLogToken).catch(function () {}); }
      catch (e) {}
    }
    W.addEventListener("error", function (e) {
      var msg = (e && e.message) ? e.message : "script error";
      if (e && e.filename) { msg += " (" + e.filename + ":" + (e.lineno || 0) + ")"; }
      if (e && e.error && e.error.stack) { msg += "\n" + e.error.stack; }
      emit(msg);
    });
    W.addEventListener("unhandledrejection", function (e) {
      var r = e && e.reason;
      emit("Unhandled promise rejection: " + ((r && r.message) ? r.message : String(r)));
    });
  })();

  // --- chrome.* surface for one content script ------------------------------------------------
  function buildChrome(data) {
    var token = data.token;
    if (__bbLogToken === null && token) { __bbLogToken = token; }   // attribute content-world errors
    var manifest = {};
    try { manifest = _JSON.parse(data.manifestJSON || "{}"); } catch (e) { manifest = {}; }
    var messages = data.messages || {};

    // chrome.runtime.lastError slot, per content script. Settable so the message/port paths can set
    // it before invoking a callback (Chrome semantics), then clear it.
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

    // Per-area change listeners (chrome.storage.<area>.onChanged, the StorageArea.onChanged added in
    // Chrome 73). Distinct from the global chrome.storage.onChanged: a manager like ScriptCat registers
    // chrome.storage.local.onChanged.addListener(...) at init, so the area MUST expose onChanged or that
    // access throws `undefined.addListener` and the whole content script dies. Keyed by area name; the
    // native storage push (onStorageChanged) fans each change to the matching area's listeners.
    var storageAreaListeners = { local: [], sync: [], session: [], managed: [] };
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
        var promise = bridge("storage.get", { area: area, keys: keyList }, token).then(function (raw) {
          var out = {};
          // Deep-clone each default so a caller mutating the get() result can't corrupt its own
          // defaults object (Chrome returns independent copies); a stored value overrides it below.
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
        return settle(bridge("storage.set", { area: area, items: enc }, token).then(function () { return undefined; }), callback);
      }
      function remove(keys, callback) {
        var list = typeof keys === "string" ? [keys] : (keys || []);
        return settle(bridge("storage.remove", { area: area, keys: list }, token).then(function () { return undefined; }), callback);
      }
      function clear(callback) {
        return settle(bridge("storage.clear", { area: area }, token).then(function () { return undefined; }), callback);
      }
      // chrome.storage.<area>.getBytesInUse — usage isn't tracked; report 0 (Chrome permits an
      // approximate/zero value), mirroring the background + page surfaces so the method exists.
      function getBytesInUse(keys, callback) {
        if (typeof keys === "function") { callback = keys; }
        if (typeof callback === "function") { callback(0); return undefined; }
        return _Promise.resolve(0);
      }
      // chrome.storage.session.setAccessLevel — no-op (no separate untrusted tier); resolves.
      function setAccessLevel(_opts, callback) {
        if (typeof callback === "function") { callback(); return undefined; }
        return _Promise.resolve();
      }
      return { get: get, set: set, remove: remove, clear: clear,
               getBytesInUse: getBytesInUse, setAccessLevel: setAccessLevel,
               onChanged: makeEvent(storageAreaListeners[area] || (storageAreaListeners[area] = [])) };
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

    // Real, per-content-script event lists. runtime.onMessage receives chrome.tabs.sendMessage pushes
    // from the background/popup/other content scripts; storage.onChanged receives chrome.storage
    // changes. Both are driven by native via window.__bbExtContent[token] (registered below).
    var messageListeners = [];
    var storageListeners = [];
    function makeEvent(list) {
      return {
        addListener: function (fn) { if (typeof fn === "function" && list.indexOf(fn) < 0) { list.push(fn); } },
        removeListener: function (fn) { var i = list.indexOf(fn); if (i >= 0) { list.splice(i, 1); } },
        hasListener: function (fn) { return list.indexOf(fn) >= 0; }
      };
    }

    // chrome.runtime.connect / onConnect long-lived ports. A content script is a CONNECTOR: it opens a
    // port to its worker via runtime.connect, and native pushes the worker's replies via
    // window.__bbExtContent[token].onPortMessage/onPortDisconnect. A synchronous Port is returned that
    // buffers postMessage() until the async native id-mint resolves, then flushes.
    var connectListeners = [];
    var ports = Object.create(null);   // portId -> port
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
          if (portId) { bridge("port.postMessage", { portId: portId, message: m }, token); }
          else { buffer.push(m); }
        },
        disconnect: function () {
          if (disconnected) { return; }
          disconnected = true;
          if (portId) { bridge("port.disconnect", { portId: portId }, token); delete ports[portId]; }
        }
      };
      port._bindId = function (id) {
        portId = id;
        if (!id) { return; }
        ports[id] = port;
        if (disconnected) { bridge("port.disconnect", { portId: id }, token); delete ports[id]; return; }
        for (var i = 0; i < buffer.length; i++) { bridge("port.postMessage", { portId: id, message: buffer[i] }, token); }
        buffer = [];
      };
      port._fireMessage = function (m) { for (var i = 0; i < msgListeners.length; i++) { try { msgListeners[i](m, port); } catch (e) { reportContentError(e, token); } } };
      port._fireDisconnect = function () { disconnected = true; for (var i = 0; i < discListeners.length; i++) { try { discListeners[i](port); } catch (e) { reportContentError(e, token); } } };
      return port;
    }
    function runtimeConnect(connectInfo) {
      var ci = connectInfo || {};
      var port = makePort(ci.name || "", null);
      // Include the page URL: Chrome's onConnect Port.sender carries the connecting context's url
      // (uBO's vAPI.messaging onConnect reads `sender.url` unconditionally — undefined threw).
      bridge("port.connect", { name: ci.name || "",
                               url: (W.location && W.location.href) || "" }, token).then(function (res) {
        port._bindId(res && res.portId ? res.portId : null);
      }, function () { port._bindId(null); });
      return port;
    }

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
        // chrome.tabs.sendMessage(tabId, message, options?, callback?) — content scripts can message
        // another tab's content scripts. Native delivers to that tab and resolves with the response.
        var args = _Array.prototype.slice.call(arguments);
        var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
        var tabId = args[0];
        var message = args[1];
        var promise = bridge("tabs.sendMessage",
          { tabId: tabId, message: (message === undefined ? null : message) }, token);
        return settle(promise, cb);
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
        // chrome.scripting.ExecutionWorld — enum for world: targets. Content scripts that build
        // injection payloads with `world: chrome.scripting.ExecutionWorld.MAIN` (React DevTools,
        // Bitwarden overlay content) would throw "Cannot read properties of undefined" without it.
        ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT' },
        executeScript: function (injection, callback) { return settle(bridge("scripting.executeScript", serialize(injection), token), callback); },
        insertCSS: function (injection, callback) { return settle(bridge("scripting.insertCSS", cssPayload(injection), token).then(function () { return undefined; }), callback); },
        removeCSS: function (injection, callback) { return settle(bridge("scripting.removeCSS", cssPayload(injection), token).then(function () { return undefined; }), callback); }
      };
    }

    // --- chrome.cookies ------------------------------------------------------------------------
    function cookiesApi() {
      function get(details, callback) {
        return settle(bridge("cookies.get", { details: details || {} }, token), callback);
      }
      function getAll(details, callback) {
        if (typeof details === "function") { callback = details; details = {}; }
        return settle(bridge("cookies.getAll", { details: details || {} }, token), callback);
      }
      function set(details, callback) {
        return settle(bridge("cookies.set", { details: details || {} }, token), callback);
      }
      function remove(details, callback) {
        return settle(bridge("cookies.remove", { details: details || {} }, token), callback);
      }
      function getAllCookieStores(callback) {
        return settle(bridge("cookies.getAllCookieStores", {}, token), callback);
      }
      // onChanged isn't pushed into content scripts (no per-frame native push channel here); it's a
      // no-op so a content script that subscribes doesn't throw. Background workers + pages get live
      // onChanged. (Content-script cookie listeners are rare; the read/write APIs are the point.)
      return {
        get: get, getAll: getAll, set: set, remove: remove,
        getAllCookieStores: getAllCookieStores, onChanged: noopEvent
      };
    }

    // --- chrome.notifications ------------------------------------------------------------------
    // Content scripts may create/update/clear/getAll, but in Chrome the notification EVENTS fire in
    // the background/event page, not the content script — so the on* listeners here are no-ops.
    function notificationsApi() {
      function create(notificationId, options, callback) {
        if (notificationId !== null && typeof notificationId === "object") { callback = options; options = notificationId; notificationId = undefined; }
        if (typeof options === "function") { callback = options; options = {}; }
        options = options || {};
        return settle(bridge("notifications.create", { notificationId: notificationId || null, options: options }, token), callback);
      }
      function update(notificationId, options, callback) {
        if (typeof options === "function") { callback = options; options = {}; }
        options = options || {};
        return settle(bridge("notifications.update", { notificationId: notificationId, options: options }, token), callback);
      }
      function clear(notificationId, callback) {
        return settle(bridge("notifications.clear", { notificationId: notificationId }, token), callback);
      }
      function getAll(callback) { return settle(bridge("notifications.getAll", {}, token), callback); }
      function getPermissionLevel(callback) {
        var level = "granted";
        if (typeof callback === "function") { callback(level); return undefined; }
        return _Promise.resolve(level);
      }
      return {
        create: create, update: update, clear: clear, getAll: getAll, getPermissionLevel: getPermissionLevel,
        onClicked: noopEvent, onClosed: noopEvent, onButtonClicked: noopEvent,
        onShowSettings: noopEvent, onPermissionLevelChanged: noopEvent
      };
    }

    // --- chrome.action / chrome.browserAction -------------------------------------------------
    // setIcon only forwards bridgeable strings (path / size→path map); ImageData can't cross the
    // bridge on iOS so it's dropped. onClicked is a no-op in a content script (Chrome fires it only in
    // the background context); it exists so shared code that adds a listener doesn't throw.
    function actionApi() {
      function setter(api) {
        return function (details, callback) {
          details = details || {};
          var payload = {};
          for (var k in details) { if (_Object.prototype.hasOwnProperty.call(details, k)) { payload[k] = details[k]; } }
          return settle(bridge(api, payload, token).then(function () { return undefined; }), callback);
        };
      }
      function getter(api) {
        return function (details, callback) {
          if (typeof details === "function") { callback = details; details = {}; }
          return settle(bridge(api, details || {}, token), callback);
        };
      }
      function toggle(api) {
        return function (tabId, callback) {
          if (typeof tabId === "function") { callback = tabId; tabId = undefined; }
          return settle(bridge(api, { tabId: tabId }, token).then(function () { return undefined; }), callback);
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
        return settle(bridge("action.setIcon", payload, token).then(function () { return undefined; }), callback);
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
        onClicked: noopEvent
      };
    }

    // --- chrome.windows / management / permissions (iOS is single-window; window id 1) ----------
    function windowsApi() {
      function normalize(getInfo, cb) {
        if (typeof getInfo === "function") { cb = getInfo; getInfo = null; }
        return { populate: !!(getInfo && getInfo.populate), cb: cb };
      }
      function get(windowId, getInfo, cb) {
        if (typeof windowId === "object" && windowId !== null) { cb = getInfo; getInfo = windowId; }
        else if (typeof windowId === "function") { cb = windowId; getInfo = null; }
        var n = normalize(getInfo, cb);
        return settle(bridge("windows.get", { populate: n.populate }, token), n.cb);
      }
      function getCurrent(getInfo, cb) { var n = normalize(getInfo, cb); return settle(bridge("windows.getCurrent", { populate: n.populate }, token), n.cb); }
      function getLastFocused(getInfo, cb) { var n = normalize(getInfo, cb); return settle(bridge("windows.getLastFocused", { populate: n.populate }, token), n.cb); }
      function getAll(getInfo, cb) { var n = normalize(getInfo, cb); return settle(bridge("windows.getAll", { populate: n.populate }, token), n.cb); }
      function create(createData, cb) {
        createData = createData || {};
        var url = createData.url;
        if (_Array.isArray(url)) { url = url[0]; }   // multi-URL create -> first url in our single tab
        return settle(bridge("windows.create", { url: url, focused: createData.focused !== false, populate: false }, token), cb);
      }
      function update(windowId, updateInfo, cb) { return settle(bridge("windows.update", { populate: false }, token), cb); }
      function remove(windowId, cb) { return settle(bridge("windows.remove", {}, token).then(function () { return undefined; }), cb); }
      return {
        WINDOW_ID_NONE: -1, WINDOW_ID_CURRENT: -2,
        get: get, getCurrent: getCurrent, getLastFocused: getLastFocused, getAll: getAll,
        create: create, update: update, remove: remove,
        onCreated: noopEvent, onRemoved: noopEvent, onFocusChanged: noopEvent, onBoundsChanged: noopEvent
      };
    }
    function managementApi() {
      return {
        getSelf: function (cb) { return settle(bridge("management.getSelf", {}, token), cb); },
        get: function (id, cb) { return settle(bridge("management.get", { id: id }, token), cb); },
        getAll: function (cb) { return settle(bridge("management.getAll", {}, token), cb); },
        onInstalled: noopEvent, onUninstalled: noopEvent, onEnabled: noopEvent, onDisabled: noopEvent
      };
    }
    function permissionsApi() {
      function perms(p) { p = p || {}; return { permissions: p.permissions || [], origins: p.origins || [] }; }
      return {
        getAll: function (cb) { return settle(bridge("permissions.getAll", {}, token), cb); },
        contains: function (p, cb) { return settle(bridge("permissions.contains", perms(p), token), cb); },
        request: function (p, cb) { return settle(bridge("permissions.request", perms(p), token), cb); },
        remove: function (p, cb) { return settle(bridge("permissions.remove", perms(p), token), cb); },
        onAdded: noopEvent, onRemoved: noopEvent
      };
    }

    // --- chrome.declarativeNetRequest + chrome.userScripts ------------------------------------
    // A native {error} object becomes a rejected promise (so the callback gets undefined / the promise
    // throws), preserving Chrome's failure semantics across the bridge.
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
      // Chrome 121+ per-bucket limits, matching the page + background shims (adblockers read these).
      MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000,
      MAX_NUMBER_OF_SESSION_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
      MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000,
      MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
      GUARANTEED_MINIMUM_STATIC_RULES: 30000,
      GETMATCHEDRULES_QUOTA_INTERVAL: 10, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20,
      updateDynamicRules: function (options, callback) {
        return settle(bridge("dnr.updateDynamicRules", options || {}, token).then(unwrap).then(function () { return undefined; }), callback);
      },
      getDynamicRules: function (filter, callback) {
        if (typeof filter === "function") { callback = filter; filter = null; }
        return settle(bridge("dnr.getDynamicRules", { ruleIds: (filter && filter.ruleIds) || null }, token).then(unwrap), callback);
      },
      updateSessionRules: function (options, callback) {
        return settle(bridge("dnr.updateSessionRules", options || {}, token).then(unwrap).then(function () { return undefined; }), callback);
      },
      getSessionRules: function (filter, callback) {
        if (typeof filter === "function") { callback = filter; filter = null; }
        return settle(bridge("dnr.getSessionRules", { ruleIds: (filter && filter.ruleIds) || null }, token).then(unwrap), callback);
      },
      updateEnabledRulesets: function (options, callback) {
        return settle(bridge("dnr.updateEnabledRulesets", options || {}, token).then(unwrap).then(function () { return undefined; }), callback);
      },
      getEnabledRulesets: function (callback) {
        return settle(bridge("dnr.getEnabledRulesets", {}, token).then(unwrap), callback);
      },
      getMatchedRules: function (filter, callback) {
        if (typeof filter === "function") { callback = filter; filter = null; }
        return settle(_Promise.resolve({ rulesMatchedInfo: [] }), callback);   // no iOS telemetry source
      },
      setExtensionActionOptions: function (options, callback) { return settle(_Promise.resolve(undefined), callback); },
      isRegexSupported: function (regexOptions, callback) { return settle(_Promise.resolve({ isSupported: true }), callback); },
      onRuleMatchedDebug: noopEvent
    };
    var userScripts = {
      register: function (scripts, callback) {
        return settle(bridge("userScripts.register", { scripts: scripts || [] }, token).then(unwrap).then(function () { return undefined; }), callback);
      },
      update: function (scripts, callback) {
        return settle(bridge("userScripts.update", { scripts: scripts || [] }, token).then(unwrap).then(function () { return undefined; }), callback);
      },
      unregister: function (filter, callback) {
        if (typeof filter === "function") { callback = filter; filter = null; }
        return settle(bridge("userScripts.unregister", { filter: filter || null }, token).then(unwrap).then(function () { return undefined; }), callback);
      },
      getScripts: function (filter, callback) {
        if (typeof filter === "function") { callback = filter; filter = null; }
        return settle(bridge("userScripts.getScripts", { filter: filter || null }, token).then(unwrap), callback);
      },
      configureWorld: function (properties, callback) {
        return settle(bridge("userScripts.configureWorld", { properties: properties || {} }, token).then(unwrap).then(function () { return undefined; }), callback);
      }
    };

    // --- chrome.contextMenus (content scripts may create/update/remove; onClicked fires in the
    //     background page in Chrome, so the event here is a no-op) --------------------------------
    function contextMenusApi() {
      return {
        create: function (createProperties, callback) {
          createProperties = createProperties || {};
          bridge("contextMenus.create", { properties: createProperties }, token).then(unwrap).then(function () {
            if (typeof callback === "function") { callback(); }
          }, function () { if (typeof callback === "function") { callback(); } });
          return (createProperties.id !== undefined && createProperties.id !== null) ? createProperties.id : undefined;
        },
        update: function (id, updateProperties, callback) {
          return settle(bridge("contextMenus.update", { id: id, properties: updateProperties || {} }, token).then(unwrap).then(function () { return undefined; }), callback);
        },
        remove: function (menuItemId, callback) {
          return settle(bridge("contextMenus.remove", { id: menuItemId }, token).then(unwrap).then(function () { return undefined; }), callback);
        },
        removeAll: function (callback) {
          return settle(bridge("contextMenus.removeAll", {}, token).then(unwrap).then(function () { return undefined; }), callback);
        },
        onClicked: noopEvent,
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
      // chrome.tabs.* and chrome.webNavigation.* EVENTS are not delivered to content scripts in Chrome
      // (those live in background/popup contexts). The namespace exists but is inert so a shared script
      // can add a listener without throwing; it just never fires.
      webNavigation: {
        onBeforeNavigate: noopEvent, onCommitted: noopEvent, onDOMContentLoaded: noopEvent,
        onCompleted: noopEvent, onHistoryStateUpdated: noopEvent, onErrorOccurred: noopEvent,
        onReferenceFragmentUpdated: noopEvent, onCreatedNavigationTarget: noopEvent
      },
      runtime: {
        id: data.extensionId,
        getManifest: function () { return manifest; },
        getURL: getURL,
        openOptionsPage: function (cb) {
          return settle(bridge("runtime.openOptionsPage", {}, token).then(function () { return undefined; }), cb);
        },
        setUninstallURL: function (url, cb) {
          return settle(bridge("runtime.setUninstallURL", { url: url || "" }, token).then(function () { return undefined; }), cb);
        },
        sendMessage: function () {
          // Overloaded like Chrome: (extensionId?, message, options?, callback?). We deliver to
          // this extension's own background worker and resolve with the listener's response value.
          // A USER_SCRIPT-world script (configureWorld({messaging:true})) routes to the worker's
          // onUserScriptMessage instead of onMessage (the MV3 User Scripts channel).
          var args = _Array.prototype.slice.call(arguments);
          var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
          var message = (typeof args[0] === "string" && args.length > 1) ? args[1] : args[0];
          var msgApi = (data.world === "USER_SCRIPT" && data.userScriptMessaging)
            ? "runtime.userScriptMessage" : "runtime.sendMessage";
          var promise = bridge(msgApi, { message: (message === undefined ? null : message), url: location.href }, token)
            .then(function (resp) {
              if (resp && resp.__bbNoReceiver) {
                // No context received the message — Chrome rejects (promise) / sets lastError (callback).
                var e = new Error("Could not establish connection. Receiving end does not exist.");
                e.__bbLastError = true; throw e;
              }
              return resp ? resp.value : undefined;
            });
          return settle(promise, cb);
        },
        onMessage: makeEvent(messageListeners),
        onConnect: makeEvent(connectListeners),
        onInstalled: noopEvent,
        connect: runtimeConnect,
        get lastError() { return _bbLastError; },
        getPlatformInfo: function (cb) { var info = { os: "ios", arch: "arm64", nacl_arch: "arm64" }; if (typeof cb === "function") { cb(info); return undefined; } return _Promise.resolve(info); },
        // chrome.runtime.sendNativeMessage — native app messaging is not supported on iOS. Reject
        // clearly (callback: sets lastError + calls back with undefined; promise: rejects) so an
        // extension that probes it gets a diagnosable error instead of a crash on undefined.
        sendNativeMessage: function (application, message, cb) {
          var err = { message: "native messaging is not supported on iOS" };
          if (typeof cb === "function") {
            _bbLastError = err;
            try { cb(undefined); } finally { _bbLastError = null; }
            return undefined;
          }
          var e = new Error(err.message); e.__bbLastError = true;
          return _Promise.reject(e);
        },
        // chrome.runtime.getBrowserInfo — Firefox-origin API, probed by Vimium and others.
        getBrowserInfo: function (cb) {
          var info = { name: "BrownBear", vendor: "BrownBear", version: "1.0.0", buildID: "20240101" };
          if (typeof cb === "function") { cb(info); return undefined; }
          return _Promise.resolve(info);
        }
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
      },
      // chrome.dom.openOrClosedShadowRoot(el) — content scripts (e.g. uBO Lite's cosmetic filtering,
      // 12 call sites) use it to reach an element's shadow root for selector matching. WebKit exposes
      // OPEN shadow roots via element.shadowRoot; CLOSED ones are inaccessible to any script on WebKit
      // (no equivalent of Chrome's privileged access), so we return the open root or null instead of
      // throwing "chrome.dom is undefined" and killing the content script.
      dom: {
        openOrClosedShadowRoot: function (element) {
          try { return (element && element.shadowRoot) || null; } catch (e) { return null; }
        }
      },
      // chrome.sidePanel — Chrome 114+ side-panel API. Content scripts from Grammarly and other
      // productivity extensions call sidePanel.open() from a content-script context. iOS has no
      // persistent side-panel surface, so all methods resolve as graceful no-ops.
      sidePanel: {
        open: function (options, cb) {
          if (typeof options === "function") { cb = options; }
          if (typeof cb === "function") { cb(); return undefined; }
          return _Promise.resolve(undefined);
        },
        setOptions: function (options, cb) {
          if (typeof cb === "function") { cb(); return undefined; }
          return _Promise.resolve(undefined);
        },
        getOptions: function (options, cb) {
          if (typeof options === "function") { cb = options; }
          if (typeof cb === "function") { cb({}); return undefined; }
          return _Promise.resolve({});
        },
        setPanel: function (options, cb) {
          if (typeof cb === "function") { cb(); return undefined; }
          return _Promise.resolve(undefined);
        },
        setPanelBehavior: function (behavior, cb) {
          if (typeof cb === "function") { cb(); return undefined; }
          return _Promise.resolve(undefined);
        },
        getPanelBehavior: function (cb) {
          var r = { openPanelOnActionClick: false };
          if (typeof cb === "function") { cb(r); return undefined; }
          return _Promise.resolve(r);
        },
        onShown: noopEvent,
        onHidden: noopEvent
      },
      // chrome.devtools — DevTools extension API. Content scripts in a devtools context (React
      // DevTools injects content/prepareInjection.js into every tab) reference this namespace.
      // iOS has no embedded DevTools, so all methods are inert no-ops that don't throw.
      devtools: {
        inspectedWindow: {
          eval: function (expression, options, cb) {
            if (typeof options === "function") { cb = options; }
            if (typeof cb === "function") { cb(undefined, { isException: false }); return undefined; }
            return _Promise.resolve([undefined, { isException: false }]);
          },
          reload: function () {},
          getResources: function (cb) { if (typeof cb === "function") { cb([]); } },
          tabId: 0
        },
        panels: {
          create: function (title, iconPath, pagePath, cb) {
            if (typeof cb === "function") { cb(null); }
            return _Promise.resolve(null);
          },
          elements: { createSidebarPane: function (title, cb) { if (typeof cb === "function") { cb(null); } } },
          sources: { createSidebarPane: function (title, cb) { if (typeof cb === "function") { cb(null); } } },
          themeName: "default",
          openResource: function () {}
        },
        network: {
          addRules: function () {},
          getHAR: function (cb) { if (typeof cb === "function") { cb({ entries: [] }); } },
          onNavigated: noopEvent,
          onRequestFinished: noopEvent
        }
      }
    };

    // Native → this content script push surface, keyed by the injection token. The runtime evaluates
    // into this isolated world to deliver chrome.tabs.sendMessage payloads (onMessage) and
    // chrome.storage changes (onStorageChanged). Kept off `chrome` so the page can't see or spoof it.
    var registry = W.__bbExtContent || (W.__bbExtContent = {});
    registry[token] = {
      onMessage: function (message, sender, responseId) {
        var responded = false;
        var willRespondAsync = false;
        function sendResponse(value) {
          if (responded) { return; }
          responded = true;
          bridge("runtime.messageResponse",
            { responseId: responseId, value: (value === undefined ? null : value) }, token).catch(function () {});
        }
        for (var i = 0; i < messageListeners.length; i++) {
          var returned;
          try { returned = messageListeners[i](message, sender, sendResponse); }
          catch (e) { reportContentError(e, token); continue; }
          if (returned === true) { willRespondAsync = true; }
          else if (returned && typeof returned.then === "function") {
            willRespondAsync = true;
            returned.then(function (v) { sendResponse(v); }, function () { sendResponse(undefined); });
          }
          if (responded) { break; }
        }
        // No synchronous answer and no listener kept the channel open: release the sender now.
        if (!responded && !willRespondAsync) { sendResponse(undefined); }
      },
      onStorageChanged: function (rawChanges, areaName) {
        var changes = {};
        _Object.keys(rawChanges || {}).forEach(function (k) {
          var entry = {};
          if (rawChanges[k].oldValue != null) { try { entry.oldValue = _JSON.parse(rawChanges[k].oldValue); } catch (e) {} }
          if (rawChanges[k].newValue != null) { try { entry.newValue = _JSON.parse(rawChanges[k].newValue); } catch (e) {} }
          changes[k] = entry;
        });
        for (var i = 0; i < storageListeners.length; i++) {
          try { storageListeners[i](changes, areaName); }
          catch (e) { reportContentError(e, token); }
        }
        // chrome.storage.<area>.onChanged listeners get just the changes (the area is implicit).
        var areaList = storageAreaListeners[areaName];
        if (areaList) {
          for (var a = 0; a < areaList.length; a++) {
            try { areaList[a](changes); }
            catch (e2) { reportContentError(e2, token); }
          }
        }
      },
      // Port pushes from native (the worker's side of a port this endpoint opened). For a port opened
      // TOWARD this endpoint (responder path — present for symmetry), onPortConnect builds the port and
      // fires onConnect. name/sender arrive already parsed (embedded as JS literals by native).
      onPortConnect: function (portId, name, sender) {
        var port = makePort(typeof name === "string" ? name : "", sender || null);
        port._bindId(portId);
        for (var i = 0; i < connectListeners.length; i++) {
          try { connectListeners[i](port); } catch (e) { reportContentError(e, token); }
        }
      },
      onPortMessage: function (portId, message) {
        var p = ports[portId];
        // Diagnostic: a worker port message reaching THIS content world (e.g. a ScriptCat GM_xmlhttpRequest
        // response arriving at scripting.js). If the SW logged "port post" but this never logs, the
        // worker→content port delivery is the gap; if this logs but the userscript still stalls, the gap is
        // the content→page relay. Pinpoints which side of the chain drops the response.
        try {
          if (handler && __bbLogToken) {
            var _sz = 0; try { _sz = JSON.stringify(message == null ? null : message).length; } catch (e) { _sz = -1; }
            bridge("runtime.frameLog", { level: "debug", message: "[content] port recv " + portId + " " + _sz + "b" + (p ? "" : " (NO PORT)") }, null).catch(function () {});
          }
        } catch (e) { /* diagnostic must never break delivery */ }
        if (p) { p._fireMessage(message); }
      },
      onPortDisconnect: function (portId) {
        var p = ports[portId];
        if (p) { delete ports[portId]; p._fireDisconnect(); }
      }
    };
    return chrome;
  }

  // ---------------------------------------------------------------- cross-world event bridge
  //
  // ScriptCat/Tampermonkey-style managers run as THREE cooperating scripts that must message each other
  // across world boundaries: inject.js (page MAIN world), content.js (USER_SCRIPT world) and scripting.js
  // (ISOLATED world). Their home-grown bus dispatches CustomEvents on a shared EventTarget and carries
  // every payload in `event.detail`. In WebKit a WKContentWorld shares the DOM but NOT JS state — and
  // CustomEvent.detail is a world-bound value (WebCore CustomEvent::detail() returns a JSValueInWrappedObject),
  // so a detail created in the page world reads as `null` from our isolated world and vice-versa. The
  // manager's eventFlag handshake therefore never completes and no userscript ever runs.
  //
  // The target object differs by version: ScriptCat <=1.0 dispatched on `performance`; the shipped build
  // (v1.1.2+, what users install) dispatches its ENTIRE bus on `window` (window.dispatchEvent /
  // window.addEventListener in inject.js + content.js — no `performance` use at all). A `performance`-only
  // bridge therefore relays nothing for the shipped build: the eventFlag rendezvous completes inside the
  // isolated world (content.js <-> scripting.js, un-graying the script) but NEVER reaches inject.js in the
  // page MAIN world, so the userscript un-grays but never runs and `nativeSend` later throws
  // "custom_event_message is not ready" ("[page] script error"). We bridge BOTH `performance` AND `window`.
  //
  // We bridge the ONE boundary that matters for us — page MAIN world <-> our single isolated content world
  // (content.js + scripting.js already share that isolated world, so they talk directly). The relay mirrors
  // every dispatched CustomEvent/MouseEvent to the other world over a channel that DOES cross: the SHARED
  // DOM. We dispatch a bare signal Event on a shared sentinel element (events on shared DOM nodes fire
  // listeners in every world) and pass the serialized payload through a string attribute (strings cross
  // worlds). Each bridged target gets its OWN channel (distinct attribute/event suffix) so the `performance`
  // and `window` relays never read each other's payloads off the one sentinel. Dispatch is synchronous, so
  // the manager's sync readiness ping (preventDefault round-trip) and syncSendMessage keep working. The shim
  // is self-contained (no closure refs) so it can be re-serialized via toString() and injected into the page.
  function installPerfBridge(role) {
    try {
      var doc = document;
      var rootEl = doc.documentElement || doc.head || doc.body;
      if (!rootEl) { return; }
      var JSONlocal = JSON, CE = CustomEvent, EV = Event;
      var ME = (typeof MouseEvent !== "undefined") ? MouseEvent : null;
      // Diagnostic (capped): confirm a manager's GM_xhr RESPONSE actually crosses isolated->MAIN on the
      // real device. The transport SW->scripting.js is already proven (port logs); this is the one
      // unmeasured hop. A ScriptCat auth response is ~2-3KB, so logging sizeable cross-world relays makes
      // it unmistakable whether the body in MAIN is receiving it. Gated to >=512b so it never floods.
      // MUST surface in the Logs tab: the ISOLATED-world console is NOT forwarded (only the `bridge`
      // frameLog channel is — that's what the `[content] port recv` lines use), so prefer it. The iso
      // copy of installPerfBridge (the direct call below) has `bridge` in scope; the page copy is
      // toString-injected with no `bridge`, so it falls back to console.log (the PAGE console IS forwarded).
      var __pbLogN = 0;
      function __pbEmit(msg) {
        try {
          if (typeof bridge === "function") { bridge("runtime.frameLog", { level: "debug", message: msg }, null).catch(function () {}); }
          else if (typeof console !== "undefined" && console.log) { console.log(msg); }
        } catch (e) {}
      }
      function __pbLog(dir, n) {
        if (n < 512 || ++__pbLogN > 50) { return; }
        __pbEmit("[bb-perfbridge] " + dir + " " + n + "b");
      }

      // Eval/CSP capability probe (diagnostic for the ScriptCat eval-loader class of bot: a granted
      // userscript that GM_xhr-fetches an encrypted module, decrypts it, then new Function()/eval()s it).
      // ScriptCat compiles every body with `new Function` (utils.ts compileScript) and EXPECTS to need a
      // CSP-relaxed world — on desktop it sets userScripts.configureWorld({csp:"...unsafe-eval..."}) on the
      // USER_SCRIPT world. The body runs in whichever world its registration lands in: MAIN (inject.js) is
      // the page realm and inherits the PAGE's CSP, so a strict script-src there silently kills the final
      // new Function(decryptedModule) — "scriptcat says running" (the loader ran) but "doesn't inject" (the
      // module never evals). The isolated content world is CSP-immune. Probe BOTH roles and surface the
      // answer in the Logs tab — no desktop Web Inspector needed. Self-contained (the page copy is
      // toString-injected with no closure refs beyond `role`/`doc`/`__pbEmit`). Runs once per world.
      try {
        var __ev = (typeof window !== "undefined") ? window : ((typeof self !== "undefined") ? self : null);
        if (__ev && !__ev.__bbEvalProbed) {
          __ev.__bbEvalProbed = 1;
          var __fnOK = false, __evOK = false, __fnErr = "", __evErr = "";
          try { __fnOK = ((new Function("return 1"))() === 1); }
          catch (e) { __fnErr = (e && e.name) || "err"; }
          try { __evOK = ((0, eval)("1") === 1); }
          catch (e2) { __evErr = (e2 && e2.name) || "err"; }
          var __metaCsp = "";
          try {
            var __m = doc.querySelector('meta[http-equiv="Content-Security-Policy" i]');
            if (__m) { __metaCsp = (__m.getAttribute("content") || "").slice(0, 200); }
          } catch (e3) {}
          __pbEmit("[bb-evalprobe] " + role
            + " Function:" + (__fnOK ? "OK" : ("BLOCKED(" + __fnErr + ")"))
            + " eval:" + (__evOK ? "OK" : ("BLOCKED(" + __evErr + ")"))
            + (__metaCsp ? " metaCSP=" + __metaCsp : ""));
          // Live capture in the page realm: when the page's CSP actually refuses a script/eval (e.g. the
          // bot's new Function(module)), the browser fires securitypolicyviolation carrying the exact
          // directive — even for a header-delivered CSP we can't read from JS. Cap so a noisy page can't
          // flood the Logs tab. This pins down Theory A (page-CSP-blocked eval) vs a cross-world bridge gap.
          if (role === "page") {
            var __cspN = 0;
            doc.addEventListener("securitypolicyviolation", function (cv) {
              if (++__cspN > 5) { return; }
              try {
                __pbEmit("[bb-evalprobe] CSP-VIOLATION "
                  + (cv.violatedDirective || cv.effectiveDirective || "?")
                  + " blocked=" + (cv.blockedURI || "?")
                  + (cv.sample ? " sample=" + String(cv.sample).slice(0, 60) : ""));
              } catch (e4) {}
            });
          }
        }
      } catch (e0) {}

      // One shared sentinel element, the same DOM node in every world (find-or-create).
      var chan = rootEl.querySelector("bb-perf-bridge[data-bb-perf-bridge]");
      if (!chan) {
        chan = doc.createElement("bb-perf-bridge");
        chan.setAttribute("data-bb-perf-bridge", "1");
        try { chan.style.display = "none"; } catch (e) {}
        rootEl.appendChild(chan);
      }

      // Bridge ONE EventTarget's CustomEvent/MouseEvent traffic to the other world. `sfx` namespaces this
      // target's relay channel (attribute + signal-event names) so the `performance` and `window` bridges
      // installed on the same sentinel never read each other's payloads.
      function bridgeTarget(target, sfx) {
        if (!target || target.__bbPerfBridge) { return; }
        var origDispatch = target.dispatchEvent.bind(target);
        var IN = ((role === "page") ? "i2p" : "p2i") + sfx;   // events the OTHER world relayed to me
        var OUT = ((role === "page") ? "p2i" : "i2p") + sfx;  // events I relay to the OTHER world
        var DATA_IN = "data-" + IN, DATA_OUT = "data-" + OUT, PREV = "data-prev" + sfx;
        var relCounter = 0;

        // Inbound: reconstruct the event the other world dispatched and fire it on our local target.
        chan.addEventListener(IN, function () {
          var raw = chan.getAttribute(DATA_IN);   // read FIRST (before any re-entrant dispatch)
          if (raw == null) { return; }
          var d;
          try { d = JSONlocal.parse(raw); } catch (e) { return; }
          var ev;
          try {
            if (d.k === "m" && ME) {
              var mi = { cancelable: !!d.c, bubbles: false };
              if (typeof d.mx === "number") { mi.movementX = d.mx; }
              if (d.rt) {
                var el = rootEl.querySelector('[data-bb-perf-rt="' + d.rt + '"]');
                if (el) { mi.relatedTarget = el; }
              }
              ev = new ME(d.t, mi);
            } else {
              ev = new CE(d.t, { detail: ("d" in d ? d.d : null), cancelable: !!d.c, bubbles: false });
            }
          } catch (e) { return; }
          ev.__bbPerfMirror = 1;
          var notCancelled = origDispatch(ev);
          if (d.k === "m") { chan.setAttribute(PREV, notCancelled === false ? "1" : "0"); }
        });

        // Outbound: run locally, then mirror to the other world. Skip events we ourselves mirrored in.
        var patched = function (ev) {
          var localResult = origDispatch(ev);
          if (!ev || ev.__bbPerfMirror) { return localResult; }
          try {
            var d = { t: ev.type, c: !!ev.cancelable };
            if (ME && ev instanceof ME) {
              d.k = "m";
              d.mx = ev.movementX;
              if (ev.relatedTarget && ev.relatedTarget.setAttribute) {
                var id = "" + (++relCounter);
                ev.relatedTarget.setAttribute("data-bb-perf-rt", id);
                d.rt = id;
              }
            } else if (ev instanceof CE) {
              d.k = "c";
              try { d.d = (ev.detail === undefined) ? null : JSONlocal.parse(JSONlocal.stringify(ev.detail)); }
              catch (e) { return localResult; }   // detail not JSON-serializable: nothing to relay
            } else {
              return localResult;   // only CustomEvent / MouseEvent traffic is relayed
            }
            chan.setAttribute(PREV, "0");
            var _ser = JSONlocal.stringify(d);
            chan.setAttribute(DATA_OUT, _ser);
            if (d.k === "c") { __pbLog((role === "page") ? "page->iso" : "iso->page", _ser.length); }
            chan.dispatchEvent(new EV(OUT));   // synchronous; fires the other world's listener
            if (d.rt) {
              var rel = rootEl.querySelector('[data-bb-perf-rt="' + d.rt + '"]');
              if (rel) { rel.removeAttribute("data-bb-perf-rt"); }
            }
            if (d.k === "m" && chan.getAttribute(PREV) === "1") { return false; }
          } catch (e) {}
          return localResult;
        };
        try {
          Object.defineProperty(target, "dispatchEvent", { value: patched, writable: true, configurable: true });
        } catch (e) {
          try { target.dispatchEvent = patched; } catch (e2) { return; }
        }
        target.__bbPerfBridge = 1;
      }

      // ScriptCat <=1.0 dispatched on `performance`; the shipped build (v1.1.2+) dispatches on `window`.
      // Bridge BOTH so the eventFlag rendezvous crosses page<->isolated regardless of which the manager uses.
      if (typeof performance !== "undefined") { bridgeTarget(performance, "P"); }
      bridgeTarget((typeof window !== "undefined") ? window : ((typeof self !== "undefined") ? self : null), "W");
      // Confirm BOTH halves install on device. If `installed page` never appears, the page-world half
      // never ran (so iso->page relays can't be delivered) — that alone explains a MAIN-world manager's
      // GM_xhr responses never reaching the body. Ungated (one line per world).
      __pbEmit("[bb-perfbridge] installed " + role);
    } catch (e) {}
  }

  // Install the isolated-world half once (before any cross-world content script runs).
  var __bbIsoBridgeDone = false;
  function ensureIsoPerfBridge() {
    if (__bbIsoBridgeDone) { return; }
    __bbIsoBridgeDone = true;
    installPerfBridge("iso");
  }

  // The page-world half of the cross-world bridge is installed lazily, PREPENDED to the first MAIN-world
  // injection so it runs (with performance.dispatchEvent already patched) before any manager code in the
  // same evaluation — guaranteeing order regardless of how many world:"MAIN" scripts follow.
  var __bbPageBridgeDone = false;

  // Run `code` in the page's REAL main world. Prefer a NATIVE page-world eval: an inline <script> element
  // is blocked by a strict page CSP (script-src without 'unsafe-inline'), which silently kills MV3
  // world:"MAIN" managers (ScriptCat's inject.js) AND this bridge on hardened sites (GitHub/X/Google). A
  // native evaluateJavaScript in the page world is NOT subject to the page CSP. Fall back to a <script>
  // element only when the native bridge is unavailable (e.g. a headless context with no message handler).
  function injectPageWorldCode(code) {
    if (handler) {
      bridge("page.injectMainWorld", { code: code }, null).catch(function () {});
      return true;
    }
    try {
      var s = document.createElement("script");
      s.textContent = code;
      var parent = document.head || document.documentElement || document.body;
      if (!parent) { return false; }
      parent.appendChild(s);
      if (s.parentNode) { s.parentNode.removeChild(s); }
      return true;
    } catch (e) { return false; }
  }

  // Inject code into the page's REAL main world (MV3 `world:"MAIN"` userScripts). We're in an isolated
  // world, which can't eval into the page world directly. No extension/chrome API is exposed to MAIN-world
  // code, per the userScripts contract. The cross-world `performance` bridge shim is prepended to the first
  // injection so a manager's eventFlag handshake can reach our isolated world.
  function injectIntoPage(code, extensionId) {
    try {
      // SAME-ORIGIN sourceURL — critical for error visibility. WebKit attributes a natively-evaluated
      // MAIN-world script's errors to its `//# sourceURL` ORIGIN. A `chrome-extension://<id>` sourceURL is
      // cross-origin to the page, so any uncaught throw — including an ASYNC userscript callback (a `load`
      // or timer handler) that escapes the manager's own try/catch — reaches the page's window 'error'
      // listener SANITIZED to a bare "Script error." with no message, file, or stack (the undebuggable
      // "[page] script error" Logs line). Tagging the code with the PAGE's own origin keeps the real
      // message + stack + line:col, while a distinctive filename still marks it as injected. Pure
      // attribution metadata — it does not change what runs. Omit it on an opaque-origin page (origin "null").
      var srcURL = "";
      try {
        var org = (typeof location !== "undefined" && location.origin && location.origin !== "null")
          ? location.origin : "";
        if (org) { srcURL = "\n//# sourceURL=" + org + "/brownbear-userscript-" + (extensionId || "main") + ".js"; }
      } catch (e) { srcURL = ""; }
      var payload = code + srcURL;
      if (!__bbPageBridgeDone) {
        __bbPageBridgeDone = true;
        payload = "(" + installPerfBridge.toString() + ')("page");\n' + payload;
      }
      return injectPageWorldCode(payload);
    } catch (e) {
      reportContentError(e, null);   // no token here; reportContentError falls back to __bbLogToken
      return false;
    }
  }


  // ScriptCat exec-trigger probe (diagnostic for the "ScriptCat says running but the userscript never
  // injects" bug). ScriptCat compiles each userscript body to `window['<flag>'] = function(){…}` and runs
  // it ONLY when its own runner (inject.js startScripts → definePropertyListener) later invokes
  // window[flag]. If that runner never fires, the body is injected (we see it) but never executes — exactly
  // the reported symptom, and SILENT (no error to surface). For a MAIN-world body that matches that
  // signature, append a one-shot self-check: after a beat, if window[flag] is STILL the function, the runner
  // never invoked it (report NOT-FIRED); if it's gone, the runner ran it (report fired). Logged via the page
  // console (forwarded to the Logs tab, and not gated by the .debug filter) so it's the definitive
  // inject-vs-run signal with no desktop debugger. ADDITIVE + fully guarded — a complete IIFE appended after
  // the body, so it can never alter or break the userscript itself; a non-match returns the code unchanged.
  function maybeAppendExecProbe(code) {
    try {
      var m = /window\[(['"])([^'"]+)\1\]\s*=\s*function/.exec(code);
      if (!m) { return code; }
      var flag = m[2];
      return code + "\n;(function(f){try{setTimeout(function(){try{"
        + "var fired=(typeof window[f]!=='function');"
        + "console.info('[bb-scexec] '+f+' '+(fired?'fired (runner invoked the body)':"
        + "'NOT-FIRED — body injected but ScriptCat runner never invoked window[flag]'));"
        + "}catch(e){}},3000);}catch(e){}})(" + _JSON.stringify(flag) + ");";
    } catch (e) { return code; }
  }

  function runContentScript(data) {
    if (data.css) {
      try {
        var style = document.createElement("style");
        style.textContent = data.css;
        (document.head || document.documentElement).appendChild(style);
      } catch (e) { /* ignore */ }
    }
    if (!data.js) { return; }
    if (data.world === "MAIN") {
      injectIntoPage(maybeAppendExecProbe(data.js), data.extensionId);   // real page world, no chrome.* (userScripts contract)
      return;
    }
    var chrome = buildChrome(data);
    // Use the extension's own base (moz-extension:// for a Firefox build) so the error-attribution label
    // matches the page origin; fall back to chrome-extension if native didn't supply a base.
    var sourceURL = "//# sourceURL=" + ((data.baseURL || ("chrome-extension://" + data.extensionId + "/")) + "content.js");
    // Webpack-bundled content scripts (Violentmonkey's injected.js, ScriptCat's scripting/content
    // brokers) read `chrome`/`browser` off the GLOBAL at module load — `const { chrome } = global` then
    // a top-level `chrome.runtime.getURL('')` — not from our eval params. Our isolated world's window had
    // no `chrome`, so that ran `undefined.runtime` → TypeError before the bundle's init() ever fired, and
    // NEITHER manager injected (the page runtime already sets these — that's why VM's popup/options work).
    // Set this script's chrome on the world for the SYNCHRONOUS eval (when the bundle captures it), then
    // restore — the world is shared across extensions and across a bundle's concatenated files, so leaving
    // it would leak one extension's chrome (and its per-script token/lastError) into another. Both
    // `chrome` AND `browser` are required: VM only builds its response-unwrapping proxy when
    // `browser.runtime` is absent, and our background returns RAW (un-proxied) responses — giving it a
    // `browser` that already has `.runtime` keeps the content side un-proxied and symmetric.
    var prevC = W.chrome, prevB = W.browser;
    var hadC = ("chrome" in W), hadB = ("browser" in W);
    try {
      W.chrome = chrome;
      W.browser = chrome;
      var fn = _Function("chrome", "browser", "window", "self", "globalThis", data.js + "\n" + sourceURL);
      fn.call(W, chrome, chrome, W, W, W);
    } catch (e) {
      // A thrown content/registered-userScript script (e.g. a manager's ISOLATED-world broker like
      // ScriptCat's scripting.js) would otherwise vanish into the page console — the runtime only forwards
      // UNCAUGHT window errors. Surface it on the Logs tab so a broker that dies before it can message the
      // worker is diagnosable, not silently dead.
      reportContentError(e, data.token);
    } finally {
      if (hadC) { W.chrome = prevC; } else { try { delete W.chrome; } catch (x) { W.chrome = undefined; } }
      if (hadB) { W.browser = prevB; } else { try { delete W.browser; } catch (x2) { W.browser = undefined; } }
    }
  }

  // Forward a caught content-world error to the Logs tab (the page console isn't captured for the isolated
  // world). Best-effort: needs the native bridge + a token to attribute the line to the extension.
  function reportContentError(e, token) {
    // JSC error.stack is JUST the call stack (no message), so lead with name+message — otherwise the
    // Logs show a bare stack and the actual fault ("X is undefined") is lost.
    var head = (e && e.name ? e.name + ": " : "") + ((e && e.message) ? e.message : String(e));
    var msg = head + ((e && e.stack) ? "\n" + e.stack : "");
    if (_console.error) { _console.error("[BrownBear ext] content script error:", e); }
    var tok = token || __bbLogToken;
    if (handler && tok) {
      try { bridge("runtime.pageLog", { level: "error", message: "[content] " + msg }, tok).catch(function () {}); }
      catch (ignored) {}
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
        var starts = [], ends = [], idles = [], hasCrossWorld = false, allTokens = [];
        for (var i = 0; i < scripts.length; i += 1) {
          var s = scripts[i];
          if (s.token) { allTokens.push(s.token); }
          if (s.world === "MAIN" || s.world === "USER_SCRIPT") { hasCrossWorld = true; }
          if (s.runAt === "document_start") { starts.push(s); }
          else if (s.runAt === "document_idle") { idles.push(s); }
          else { ends.push(s); }
        }
        // WebKit's back-forward cache restores this document WITHOUT re-running document-start scripts:
        // the content scripts above keep running, but native purged their session tokens when the tab
        // navigated away — every later bridge call then fails ("unrecognized extension token"), so
        // managers report "no access to this page" and storage/messaging die on exactly the pages
        // reached via back/forward. Re-register this document's tokens on every persisted pageshow
        // (native revives them from its own tombstones; identity stays native-side).
        if (allTokens.length) {
          W.addEventListener("pageshow", function (ev) {
            if (!ev || !ev.persisted) { return; }
            bridge("revalidateSessions", { tokens: allTokens }, null).catch(function () {});
          });
        }
        // A page-world (MAIN) or USER_SCRIPT script means a cross-world manager is present; stand up the
        // isolated half of the `performance` bridge before ANY of its scripts (incl. the ISOLATED broker)
        // dispatch, so the eventFlag rendezvous can cross worlds.
        if (hasCrossWorld) {
          // Stand up the ISOLATED half of the `performance` bridge before any manager script runs. The PAGE
          // half is installed SYNCHRONOUSLY by injectIntoPage(), which PREPENDS installPerfBridge("page") to
          // the FIRST MAIN-world eval so it runs in the SAME page eval immediately before the manager's MAIN
          // code (the proven ordering). We must NOT await a separate page-bridge install here: runAll(starts)
          // has to run in THIS microtask tick — exactly as Chrome injects document_start — because the
          // scripts array is frame-global across ALL enabled extensions, so deferring it past an await
          // delays the WHOLE document_start batch (incl. other extensions' isolated content scripts) by a
          // microtask + a native round-trip and breaks injection for every co-enabled extension (#177).
          ensureIsoPerfBridge();
          // Diagnostic (Logs tab): a userscript manager (ScriptCat/Tampermonkey) only runs if its ISOLATED
          // broker + MAIN inject + USER_SCRIPT content scripts are all injected. Surface what we actually
          // got so a registration/resolution gap (e.g. the broker never returned) is visible, not silent.
          try {
            var worlds = scripts.map(function (s) {
              return (s.world || "ISOLATED") + ":" + s.runAt + ":" + ((s.js && s.js.length) || 0) + "b";
            });
            var tok = scripts[0] && scripts[0].token;
            if (handler && tok) {
              bridge("runtime.pageLog", { level: "info",
                message: "[content] inject " + scripts.length + " ext script(s): " + worlds.join(", ") }, tok)
                .catch(function () {});
            }
          } catch (ignored) {}
        }
        if (starts.length) { runAll(starts); }
        if (ends.length) { whenDOMReady(function () { runAll(ends); }); }
        if (idles.length) { whenLoaded(function () { runAll(idles); }); }
      })
      .catch(function (e) {
        // A getContentScripts failure aborts ALL injection for this frame (total, silent). Forward via the
        // tokenless frame log (the loader has no token; runtime.frameLog is routed before resolve()).
        var m = "content-script loader failed: " + ((e && e.message) ? e.message : String(e)) + ((e && e.stack) ? "\n" + e.stack : "");
        if (handler) { bridge("runtime.frameLog", { level: "error", message: "[content] " + m }, null).catch(function () {}); }
        if (_console.error) { _console.error("[BrownBear ext] loader error:", e); }
      });
  }

  W.__brownbearWebext = { version: 2 };
  loadAndRun();
})();
