//
//  brownbear-idb-persist.js
//  BrownBear
//
//  Snapshot/restore persistence for the bundled in-memory IndexedDB (brownbear-indexeddb.js) in a
//  headless JSContext. Snapshot walks the engine's internal store synchronously; restore replays
//  through the PUBLIC IndexedDB API (so it survives engine-internal changes). Writes schedule a
//  debounced snapshot handed to native (__bb_idb_save); native rehydrates by calling __bbIDBRestore at
//  boot with the last saved blob. Loaded AFTER brownbear-indexeddb.js.
//
(function () {
  'use strict';
  var g = globalThis;
  if (!g.indexedDB || !g.indexedDB._databases) { return; }

  function encode(obj) {
    // Read the RAW value via this[k]: JSON.stringify applies Date.prototype.toJSON (→ ISO string)
    // before the replacer sees `val`, so we'd otherwise lose the Date type.
    return JSON.stringify(obj, function (k, val) {
      var raw = this[k];
      if (raw instanceof Date) { return { __bbT: 'Date', v: raw.getTime() }; }
      return val;
    });
  }
  function revive(val) {
    if (val && typeof val === 'object') {
      if (val.__bbT === 'Date') { return new Date(val.v); }
      if (Array.isArray(val)) { for (var i = 0; i < val.length; i++) { val[i] = revive(val[i]); } return val; }
      for (var k in val) { if (Object.prototype.hasOwnProperty.call(val, k)) { val[k] = revive(val[k]); } }
    }
    return val;
  }
  function decode(s) { return revive(JSON.parse(s)); }

  g.__bbIDBSnapshot = function () {
    var out = { v: 1, databases: [] };
    g.indexedDB._databases.forEach(function (rawDb) {
      var dbRec = { name: rawDb.name, version: rawDb.version, stores: [] };
      rawDb.rawObjectStores.forEach(function (store) {
        if (store.deleted) { return; }
        var rec = {
          name: store.name,
          keyPath: (store.keyPath === undefined ? null : store.keyPath),
          autoIncrement: !!store.autoIncrement,
          indexes: [],
          records: []
        };
        store.rawIndexes.forEach(function (idx) {
          if (idx.deleted) { return; }
          rec.indexes.push({ name: idx.name, keyPath: idx.keyPath, multiEntry: !!idx.multiEntry, unique: !!idx.unique });
        });
        var recs = (store.records && store.records.records) ? store.records.records : [];
        for (var i = 0; i < recs.length; i++) { rec.records.push({ key: recs[i].key, value: recs[i].value }); }
        dbRec.stores.push(rec);
      });
      out.databases.push(dbRec);
    });
    return encode(out);
  };

  g.__bbIDBRestore = function (snapshotJSON) {
    if (!snapshotJSON) { return; }
    var snap;
    try { snap = decode(snapshotJSON); } catch (e) { return; }
    if (!snap || !snap.databases) { return; }
    snap.databases.forEach(function (dbRec) {
      var openReq = g.indexedDB.open(dbRec.name, dbRec.version || 1);
      openReq.onupgradeneeded = function (e) {
        var db = e.target.result;
        dbRec.stores.forEach(function (s) {
          var opts = {};
          if (s.keyPath !== null && s.keyPath !== undefined) { opts.keyPath = s.keyPath; }
          if (s.autoIncrement) { opts.autoIncrement = true; }
          var os = e.target.transaction.db.objectStoreNames.contains(s.name)
            ? e.target.transaction.objectStore(s.name) : db.createObjectStore(s.name, opts);
          s.indexes.forEach(function (ix) {
            if (!os.indexNames.contains(ix.name)) {
              os.createIndex(ix.name, ix.keyPath, { multiEntry: ix.multiEntry, unique: ix.unique });
            }
          });
        });
      };
      openReq.onsuccess = function (e) {
        var db = e.target.result;
        dbRec.stores.forEach(function (s) {
          if (!s.records.length) { return; }
          var tx = db.transaction(s.name, 'readwrite');
          var os = tx.objectStore(s.name);
          var inline = (s.keyPath !== null && s.keyPath !== undefined);
          for (var i = 0; i < s.records.length; i++) {
            try { inline ? os.put(s.records[i].value) : os.put(s.records[i].value, s.records[i].key); } catch (err) { /* skip bad record */ }
          }
        });
      };
      openReq.onerror = function () {};
    });
  };

  var snapTimer = null;
  function scheduleSnapshot() {
    // No setTimeout (the one-shot userscript runner) → rely on the end-of-run __bbIDBFlush instead.
    if (typeof setTimeout !== 'function') { return; }
    if (snapTimer !== null) { return; }
    snapTimer = setTimeout(function () {
      snapTimer = null;
      try { var j = g.__bbIDBSnapshot(); if (typeof __bb_idb_save === 'function') { __bb_idb_save(j); } } catch (e) {}
    }, 300);
  }
  g.__bbIDBFlush = function () {
    try { var j = g.__bbIDBSnapshot(); if (typeof __bb_idb_save === 'function') { __bb_idb_save(j); } } catch (e) {}
  };

  function wrap(ctor, methods) {
    if (!ctor || !ctor.prototype) { return; }
    methods.forEach(function (m) {
      var orig = ctor.prototype[m];
      if (typeof orig !== 'function') { return; }
      ctor.prototype[m] = function () { var r = orig.apply(this, arguments); scheduleSnapshot(); return r; };
    });
  }
  wrap(g.IDBObjectStore, ['put', 'add', 'delete', 'clear', 'createIndex', 'deleteIndex']);
  wrap(g.IDBCursor, ['delete', 'update']);
  wrap(g.IDBDatabase, ['createObjectStore', 'deleteObjectStore']);
  if (g.IDBFactory) { wrap(g.IDBFactory, ['deleteDatabase']); }
})();
