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

  // Structured-clone-aware JSON. IndexedDB stores real structured-clone values (the engine clones
  // every put), so a snapshot must round-trip Date/RegExp/Map/Set/BigInt/ArrayBuffer/typed arrays —
  // not just plain JSON. We tag each via `__bbT` and reconstruct on revive. The replacer reads the RAW
  // value via `this[k]` because JSON.stringify applies toJSON (e.g. Date→ISO string) before `val`, and
  // because a BigInt left untouched would make stringify THROW (losing the whole snapshot).
  function encode(obj) {
    return JSON.stringify(obj, function (k, val) {
      var raw = this[k];
      if (typeof raw === 'bigint') { return { __bbT: 'BigInt', v: raw.toString() }; }
      if (raw instanceof Date) { return { __bbT: 'Date', v: raw.getTime() }; }
      if (raw instanceof RegExp) { return { __bbT: 'RegExp', s: raw.source, f: raw.flags }; }
      if (raw instanceof Map) { return { __bbT: 'Map', v: Array.from(raw.entries()) }; }
      if (raw instanceof Set) { return { __bbT: 'Set', v: Array.from(raw.values()) }; }
      if (raw instanceof ArrayBuffer) { return { __bbT: 'ArrayBuffer', v: Array.prototype.slice.call(new Uint8Array(raw)) }; }
      if (typeof DataView !== 'undefined' && raw instanceof DataView) {
        return { __bbT: 'DataView', v: Array.prototype.slice.call(new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength)) };
      }
      if (raw && ArrayBuffer.isView(raw)) {
        return { __bbT: 'TypedArray', c: (raw.constructor && raw.constructor.name) || 'Uint8Array',
                 v: Array.prototype.slice.call(raw) };
      }
      // Blob/File: the engine stores real (revived) Blob objects whose bytes live off-enumerable, so a
      // plain JSON pass would drop them. Tag them with their bytes (and File's name/lastModified) so a
      // ScriptCat-style imported Blob survives an SW restart instead of vanishing as "no data found".
      if (g.Blob && raw instanceof g.Blob) {
        var blobBytes = raw._bbBytes || new Uint8Array(0);
        var blobRec = { __bbT: (g.File && raw instanceof g.File) ? 'File' : 'Blob',
                        type: raw.type || '', v: Array.prototype.slice.call(blobBytes) };
        if (blobRec.__bbT === 'File') { blobRec.name = raw.name || ''; blobRec.lastModified = raw.lastModified || 0; }
        return blobRec;
      }
      return val;
    });
  }
  function revive(val) {
    if (!val || typeof val !== 'object') { return val; }
    switch (val.__bbT) {
      case 'BigInt': return (typeof BigInt === 'function') ? BigInt(val.v) : Number(val.v);
      case 'Date': return new Date(val.v);
      case 'RegExp': return new RegExp(val.s, val.f);
      case 'Map': { var m = new Map(); var e = val.v || []; for (var i = 0; i < e.length; i++) { m.set(revive(e[i][0]), revive(e[i][1])); } return m; }
      case 'Set': { var s = new Set(); var a = val.v || []; for (var j = 0; j < a.length; j++) { s.add(revive(a[j])); } return s; }
      case 'ArrayBuffer': return new Uint8Array(val.v || []).buffer;
      case 'DataView': return new DataView(new Uint8Array(val.v || []).buffer);
      case 'TypedArray': { var Ctor = g[val.c] || Uint8Array; try { return new Ctor(val.v || []); } catch (e) { return new Uint8Array(val.v || []); } }
      case 'Blob': return (typeof g.Blob === 'function')
        ? new g.Blob([new Uint8Array(val.v || []).buffer], { type: val.type || '' }) : val;
      case 'File': return (typeof g.File === 'function')
        ? new g.File([new Uint8Array(val.v || []).buffer], val.name || '', { type: val.type || '', lastModified: val.lastModified || 0 }) : val;
      default: break;
    }
    if (Array.isArray(val)) { for (var x = 0; x < val.length; x++) { val[x] = revive(val[x]); } return val; }
    for (var key in val) { if (Object.prototype.hasOwnProperty.call(val, key)) { val[key] = revive(val[key]); } }
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
