//
//  brownbear-webext-background.js
//  BrownBear
//
//  The chrome.* / browser.* surface for an extension BACKGROUND context (MV2 background scripts and
//  MV3 service workers), running headless in a JavaScriptCore JSContext — there is no DOM, no
//  `window`, no `fetch` beyond what we expose. Native blocks (installed before this file runs by
//  WebExtensionBackgroundContext) back the async parts: __bb_storage_*, __bb_alarm_*, __bb_log,
//  __bb_send_message, __bb_message_response. This file wires the idiomatic chrome shape around them
//  and exposes a single dispatch object (__bbBg) the native side calls to deliver events.
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
    get lastError() { return undefined; }
  };

  // ---------------------------------------------------------------- assemble + expose

  // Surfaces with no iOS trigger/host yet — stubbed so a worker that touches them doesn't throw.
  // chrome.commands has no keyboard source on iOS; chrome.action's badge/title are no-ops without
  // a visible toolbar button. Both fully arrive in Phase 3.
  var commands = {
    onCommand: makeEvent([]),
    getAll: function (cb) { if (typeof cb === 'function') { cb([]); } }
  };
  function noop() {}
  var action = {
    onClicked: makeEvent([]),
    setBadgeText: noop, setBadgeBackgroundColor: noop, setTitle: noop, setIcon: noop,
    setPopup: noop, enable: noop, disable: noop,
    getBadgeText: function (_d, cb) { if (typeof cb === 'function') { cb(''); } }
  };

  var chrome = {
    runtime: runtime,
    storage: storage,
    alarms: alarms,
    commands: commands,
    action: action,
    browserAction: action,
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
