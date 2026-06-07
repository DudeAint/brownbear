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
