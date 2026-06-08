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
    bridge("port.connect", { name: ci.name || "" }).then(function (res) {
      port._bindId(res && res.portId ? res.portId : null);
    }, function () { port._bindId(null); });
    return port;
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
    // chrome.storage.session.setAccessLevel — no-op (BrownBear has no separate untrusted tier); resolves.
    function setAccessLevel(_opts, callback) {
      if (typeof callback === "function") { callback(); return undefined; }
      return _Promise.resolve();
    }
    return { get: get, set: set, remove: remove, clear: clear, setAccessLevel: setAccessLevel };
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
    function sendMessage() {
      // chrome.tabs.sendMessage(tabId, message, options?, callback?) — a popup messaging a tab's
      // content scripts. Native delivers to that tab and resolves with the content listener's response.
      var args = _Array.prototype.slice.call(arguments);
      var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
      var tabId = args[0];
      var message = args[1];
      return settle(bridge("tabs.sendMessage", { tabId: tabId, message: (message === undefined ? null : message) }), cb);
    }
    return {
      query: query, get: get, getCurrent: getCurrent, create: create, update: update, remove: remove, reload: reload,
      executeScript: executeScript, insertCSS: insertCSS, sendMessage: sendMessage,
      onCreated: makeEvent(tabEventLists["tabs.onCreated"]),
      onUpdated: makeEvent(tabEventLists["tabs.onUpdated"]),
      onActivated: makeEvent(tabEventLists["tabs.onActivated"]),
      onRemoved: makeEvent(tabEventLists["tabs.onRemoved"]),
      onReplaced: makeEvent([])
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
      executeScript: function (injection, callback) { return settle(bridge("scripting.executeScript", serialize(injection)), callback); },
      insertCSS: function (injection, callback) { return settle(bridge("scripting.insertCSS", cssPayload(injection)).then(function () { return undefined; }), callback); },
      removeCSS: function (injection, callback) { return settle(bridge("scripting.removeCSS", cssPayload(injection)).then(function () { return undefined; }), callback); }
    };
  }

  var storageListeners = [];
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
      setTitle: setter("action.setTitle"),
      setPopup: setter("action.setPopup"),
      setIcon: setIcon,
      enable: toggle("action.enable"),
      disable: toggle("action.disable"),
      getBadgeText: getter("action.getBadgeText"),
      getTitle: getter("action.getTitle"),
      getBadgeBackgroundColor: getter("action.getBadgeBackgroundColor"),
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
      onAdded: noopEvent, onRemoved: noopEvent
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
    MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000,
    MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
    GETMATCHEDRULES_QUOTA_INTERVAL: 600, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20,
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
    onRuleMatchedDebug: { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } },
    MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000,
    MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
    DYNAMIC_RULESET_ID: "_dynamic",
    SESSION_RULESET_ID: "_session"
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
      ACTION_MENU_TOP_LEVEL_LIMIT: 6
    };
  }

  var chrome = {
    storage: {
      local: storageArea("local"),
      sync: storageArea("sync"),
      session: storageArea("session"),
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
    webNavigation: {
      onBeforeNavigate: makeEvent(webNavLists["webNavigation.onBeforeNavigate"]),
      onCommitted: makeEvent(webNavLists["webNavigation.onCommitted"]),
      onDOMContentLoaded: makeEvent(webNavLists["webNavigation.onDOMContentLoaded"]),
      onCompleted: makeEvent(webNavLists["webNavigation.onCompleted"]),
      onHistoryStateUpdated: makeEvent(webNavLists["webNavigation.onHistoryStateUpdated"]),
      onErrorOccurred: makeEvent(webNavLists["webNavigation.onErrorOccurred"]),
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
      sendMessage: function () {
        var args = _Array.prototype.slice.call(arguments);
        var cb = (args.length && typeof args[args.length - 1] === "function") ? args.pop() : null;
        var message = (typeof args[0] === "string" && args.length > 1) ? args[1] : args[0];
        var promise = bridge("runtime.sendMessage", { message: (message === undefined ? null : message), url: location.href })
          .then(function (resp) { return resp ? resp.value : undefined; });
        return settle(promise, cb);
      },
      connect: runtimeConnect,
      openOptionsPage: function (cb) {
        return settle(bridge("runtime.openOptionsPage", {}).then(function () { return undefined; }), cb);
      },
      setUninstallURL: function (url, cb) {
        return settle(bridge("runtime.setUninstallURL", { url: url || "" }).then(function () { return undefined; }), cb);
      },
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
      var list = tabEventLists[name] || webNavLists[name];
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
  W.__brownbearExtPageReady = true;
})();
