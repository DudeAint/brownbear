//
//  brownbear-indexeddb.js
//  BrownBear
//
//  An in-memory IndexedDB implementation for headless JavaScriptCore contexts (the extension MV3
//  service-worker context and the userscript background runner), which JSC does not provide. Lets
//  ScriptCat/Dexie-based background scripts and extensions that reach for `indexedDB` run instead of
//  throwing "Can't find variable: indexedDB". Persistence (snapshot to native disk + rehydrate on
//  launch) is layered on by brownbear-idb-persist.js, loaded immediately after this file.
//
//  GENERATED — do not hand-edit. Vendored from fake-indexeddb v3.1.7 (Apache-2.0, © Jeremy Scheff),
//  bundled to an IIFE with a setImmediate→microtask prelude (so IndexedDB async work drains between
//  JSContext.evaluateScript turns). The `--define`s rewrite Node globals JSC lacks (`global`,
//  `process`, `Deno`) so the bundle loads in a bare JSContext instead of throwing at load. Reproduce:
//    npm i fake-indexeddb@3.1.7 esbuild
//    esbuild entry.mjs --bundle --format=iife --target=es2017 \
//      --define:global=globalThis --define:process=undefined --define:Deno=undefined
//    (entry exposes the IDB* globals; prepend the setImmediate→microtask shim)
//  v3.1.7 is chosen because it carries its own structured-clone (no global structuredClone needed).
//
/* setImmediate — a REAL macrotask (native setTimeout) wherever one exists. fake-indexeddb v3.1.7's
   transaction state machine reschedules its run loop via setImmediate and assumes macrotask semantics:
   each queued request settles in its own turn so a transaction stays alive across concurrent + nested
   requests. A microtask-only shim drained an entire transaction inside one microtask checkpoint, which
   raced multi-store / nested getAll() flows — Violentmonkey's patch-db legacy migration and ScriptCat's
   Dexie migration wedged (surfacing as `t.catch` of undefined, a null Dexie table on save, and
   destructuring an undefined getAll result). The extension service worker has a native setTimeout, so it
   gets true macrotasks. The one-shot userscript runner has NO setTimeout, so it keeps the microtask path
   (its IndexedDB must drain before the single end-of-run flush). */
(function(){var g=globalThis;if(typeof g.setImmediate!=='function'){g.setImmediate=function(fn){var a=Array.prototype.slice.call(arguments,1);if(typeof g.setTimeout==='function'){return g.setTimeout(function(){fn.apply(null,a);},0);}Promise.resolve().then(function(){fn.apply(null,a);});return 0;};g.clearImmediate=function(id){if(typeof g.clearTimeout==='function'){g.clearTimeout(id);}};}})();
(() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
    get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
  }) : x)(function(x) {
    if (typeof require !== "undefined") return require.apply(this, arguments);
    throw Error('Dynamic require of "' + x + '" is not supported');
  });
  var __commonJS = (cb, mod) => function __require2() {
    return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));

  // node_modules/fake-indexeddb/build/lib/errors.js
  var require_errors = __commonJS({
    "node_modules/fake-indexeddb/build/lib/errors.js"(exports) {
      "use strict";
      var __extends = exports && exports.__extends || /* @__PURE__ */ (function() {
        var extendStatics = function(d, b) {
          extendStatics = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(d2, b2) {
            d2.__proto__ = b2;
          } || function(d2, b2) {
            for (var p in b2) if (b2.hasOwnProperty(p)) d2[p] = b2[p];
          };
          return extendStatics(d, b);
        };
        return function(d, b) {
          extendStatics(d, b);
          function __() {
            this.constructor = d;
          }
          d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
        };
      })();
      Object.defineProperty(exports, "__esModule", { value: true });
      var messages = {
        AbortError: "A request was aborted, for example through a call to IDBTransaction.abort.",
        ConstraintError: "A mutation operation in the transaction failed because a constraint was not satisfied. For example, an object such as an object store or index already exists and a request attempted to create a new one.",
        DataCloneError: "The data being stored could not be cloned by the internal structured cloning algorithm.",
        DataError: "Data provided to an operation does not meet requirements.",
        InvalidAccessError: "An invalid operation was performed on an object. For example transaction creation attempt was made, but an empty scope was provided.",
        InvalidStateError: "An operation was called on an object on which it is not allowed or at a time when it is not allowed. Also occurs if a request is made on a source object that has been deleted or removed. Use TransactionInactiveError or ReadOnlyError when possible, as they are more specific variations of InvalidStateError.",
        NotFoundError: "The operation failed because the requested database object could not be found. For example, an object store did not exist but was being opened.",
        ReadOnlyError: 'The mutating operation was attempted in a "readonly" transaction.',
        TransactionInactiveError: "A request was placed against a transaction which is currently not active, or which is finished.",
        VersionError: "An attempt was made to open a database using a lower version than the existing version."
      };
      var AbortError = (
        /** @class */
        (function(_super) {
          __extends(AbortError2, _super);
          function AbortError2(message) {
            if (message === void 0) {
              message = messages.AbortError;
            }
            var _this = _super.call(this) || this;
            _this.name = "AbortError";
            _this.message = message;
            return _this;
          }
          return AbortError2;
        })(Error)
      );
      exports.AbortError = AbortError;
      var ConstraintError = (
        /** @class */
        (function(_super) {
          __extends(ConstraintError2, _super);
          function ConstraintError2(message) {
            if (message === void 0) {
              message = messages.ConstraintError;
            }
            var _this = _super.call(this) || this;
            _this.name = "ConstraintError";
            _this.message = message;
            return _this;
          }
          return ConstraintError2;
        })(Error)
      );
      exports.ConstraintError = ConstraintError;
      var DataCloneError = (
        /** @class */
        (function(_super) {
          __extends(DataCloneError2, _super);
          function DataCloneError2(message) {
            if (message === void 0) {
              message = messages.DataCloneError;
            }
            var _this = _super.call(this) || this;
            _this.name = "DataCloneError";
            _this.message = message;
            return _this;
          }
          return DataCloneError2;
        })(Error)
      );
      exports.DataCloneError = DataCloneError;
      var DataError = (
        /** @class */
        (function(_super) {
          __extends(DataError2, _super);
          function DataError2(message) {
            if (message === void 0) {
              message = messages.DataError;
            }
            var _this = _super.call(this) || this;
            _this.name = "DataError";
            _this.message = message;
            return _this;
          }
          return DataError2;
        })(Error)
      );
      exports.DataError = DataError;
      var InvalidAccessError = (
        /** @class */
        (function(_super) {
          __extends(InvalidAccessError2, _super);
          function InvalidAccessError2(message) {
            if (message === void 0) {
              message = messages.InvalidAccessError;
            }
            var _this = _super.call(this) || this;
            _this.name = "InvalidAccessError";
            _this.message = message;
            return _this;
          }
          return InvalidAccessError2;
        })(Error)
      );
      exports.InvalidAccessError = InvalidAccessError;
      var InvalidStateError = (
        /** @class */
        (function(_super) {
          __extends(InvalidStateError2, _super);
          function InvalidStateError2(message) {
            if (message === void 0) {
              message = messages.InvalidStateError;
            }
            var _this = _super.call(this) || this;
            _this.name = "InvalidStateError";
            _this.message = message;
            return _this;
          }
          return InvalidStateError2;
        })(Error)
      );
      exports.InvalidStateError = InvalidStateError;
      var NotFoundError = (
        /** @class */
        (function(_super) {
          __extends(NotFoundError2, _super);
          function NotFoundError2(message) {
            if (message === void 0) {
              message = messages.NotFoundError;
            }
            var _this = _super.call(this) || this;
            _this.name = "NotFoundError";
            _this.message = message;
            return _this;
          }
          return NotFoundError2;
        })(Error)
      );
      exports.NotFoundError = NotFoundError;
      var ReadOnlyError = (
        /** @class */
        (function(_super) {
          __extends(ReadOnlyError2, _super);
          function ReadOnlyError2(message) {
            if (message === void 0) {
              message = messages.ReadOnlyError;
            }
            var _this = _super.call(this) || this;
            _this.name = "ReadOnlyError";
            _this.message = message;
            return _this;
          }
          return ReadOnlyError2;
        })(Error)
      );
      exports.ReadOnlyError = ReadOnlyError;
      var TransactionInactiveError = (
        /** @class */
        (function(_super) {
          __extends(TransactionInactiveError2, _super);
          function TransactionInactiveError2(message) {
            if (message === void 0) {
              message = messages.TransactionInactiveError;
            }
            var _this = _super.call(this) || this;
            _this.name = "TransactionInactiveError";
            _this.message = message;
            return _this;
          }
          return TransactionInactiveError2;
        })(Error)
      );
      exports.TransactionInactiveError = TransactionInactiveError;
      var VersionError = (
        /** @class */
        (function(_super) {
          __extends(VersionError2, _super);
          function VersionError2(message) {
            if (message === void 0) {
              message = messages.VersionError;
            }
            var _this = _super.call(this) || this;
            _this.name = "VersionError";
            _this.message = message;
            return _this;
          }
          return VersionError2;
        })(Error)
      );
      exports.VersionError = VersionError;
    }
  });

  // node_modules/fake-indexeddb/build/lib/valueToKey.js
  var require_valueToKey = __commonJS({
    "node_modules/fake-indexeddb/build/lib/valueToKey.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var errors_1 = require_errors();
      var valueToKey = function(input, seen) {
        if (typeof input === "number") {
          if (isNaN(input)) {
            throw new errors_1.DataError();
          }
          return input;
        } else if (input instanceof Date) {
          var ms = input.valueOf();
          if (isNaN(ms)) {
            throw new errors_1.DataError();
          }
          return new Date(ms);
        } else if (typeof input === "string") {
          return input;
        } else if (input instanceof ArrayBuffer || typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(input)) {
          if (input instanceof ArrayBuffer) {
            return new Uint8Array(input).buffer;
          }
          return new Uint8Array(input.buffer).buffer;
        } else if (Array.isArray(input)) {
          if (seen === void 0) {
            seen = /* @__PURE__ */ new Set();
          } else if (seen.has(input)) {
            throw new errors_1.DataError();
          }
          seen.add(input);
          var keys = [];
          for (var i = 0; i < input.length; i++) {
            var hop = input.hasOwnProperty(i);
            if (!hop) {
              throw new errors_1.DataError();
            }
            var entry = input[i];
            var key = valueToKey(entry, seen);
            keys.push(key);
          }
          return keys;
        } else {
          throw new errors_1.DataError();
        }
      };
      exports.default = valueToKey;
    }
  });

  // node_modules/fake-indexeddb/build/lib/cmp.js
  var require_cmp = __commonJS({
    "node_modules/fake-indexeddb/build/lib/cmp.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var errors_1 = require_errors();
      var valueToKey_1 = require_valueToKey();
      var getType = function(x) {
        if (typeof x === "number") {
          return "Number";
        }
        if (x instanceof Date) {
          return "Date";
        }
        if (Array.isArray(x)) {
          return "Array";
        }
        if (typeof x === "string") {
          return "String";
        }
        if (x instanceof ArrayBuffer) {
          return "Binary";
        }
        throw new errors_1.DataError();
      };
      var cmp = function(first, second) {
        if (second === void 0) {
          throw new TypeError();
        }
        first = valueToKey_1.default(first);
        second = valueToKey_1.default(second);
        var t1 = getType(first);
        var t2 = getType(second);
        if (t1 !== t2) {
          if (t1 === "Array") {
            return 1;
          }
          if (t1 === "Binary" && (t2 === "String" || t2 === "Date" || t2 === "Number")) {
            return 1;
          }
          if (t1 === "String" && (t2 === "Date" || t2 === "Number")) {
            return 1;
          }
          if (t1 === "Date" && t2 === "Number") {
            return 1;
          }
          return -1;
        }
        if (t1 === "Binary") {
          first = new Uint8Array(first);
          second = new Uint8Array(second);
        }
        if (t1 === "Array" || t1 === "Binary") {
          var length_1 = Math.min(first.length, second.length);
          for (var i = 0; i < length_1; i++) {
            var result = cmp(first[i], second[i]);
            if (result !== 0) {
              return result;
            }
          }
          if (first.length > second.length) {
            return 1;
          }
          if (first.length < second.length) {
            return -1;
          }
          return 0;
        }
        if (t1 === "Date") {
          if (first.getTime() === second.getTime()) {
            return 0;
          }
        } else {
          if (first === second) {
            return 0;
          }
        }
        return first > second ? 1 : -1;
      };
      exports.default = cmp;
    }
  });

  // node_modules/fake-indexeddb/build/FDBKeyRange.js
  var require_FDBKeyRange = __commonJS({
    "node_modules/fake-indexeddb/build/FDBKeyRange.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var cmp_1 = require_cmp();
      var errors_1 = require_errors();
      var valueToKey_1 = require_valueToKey();
      var FDBKeyRange2 = (
        /** @class */
        (function() {
          function FDBKeyRange3(lower, upper, lowerOpen, upperOpen) {
            this.lower = lower;
            this.upper = upper;
            this.lowerOpen = lowerOpen;
            this.upperOpen = upperOpen;
          }
          FDBKeyRange3.only = function(value) {
            if (arguments.length === 0) {
              throw new TypeError();
            }
            value = valueToKey_1.default(value);
            return new FDBKeyRange3(value, value, false, false);
          };
          FDBKeyRange3.lowerBound = function(lower, open) {
            if (open === void 0) {
              open = false;
            }
            if (arguments.length === 0) {
              throw new TypeError();
            }
            lower = valueToKey_1.default(lower);
            return new FDBKeyRange3(lower, void 0, open, true);
          };
          FDBKeyRange3.upperBound = function(upper, open) {
            if (open === void 0) {
              open = false;
            }
            if (arguments.length === 0) {
              throw new TypeError();
            }
            upper = valueToKey_1.default(upper);
            return new FDBKeyRange3(void 0, upper, true, open);
          };
          FDBKeyRange3.bound = function(lower, upper, lowerOpen, upperOpen) {
            if (lowerOpen === void 0) {
              lowerOpen = false;
            }
            if (upperOpen === void 0) {
              upperOpen = false;
            }
            if (arguments.length < 2) {
              throw new TypeError();
            }
            var cmpResult = cmp_1.default(lower, upper);
            if (cmpResult === 1 || cmpResult === 0 && (lowerOpen || upperOpen)) {
              throw new errors_1.DataError();
            }
            lower = valueToKey_1.default(lower);
            upper = valueToKey_1.default(upper);
            return new FDBKeyRange3(lower, upper, lowerOpen, upperOpen);
          };
          FDBKeyRange3.prototype.includes = function(key) {
            if (arguments.length === 0) {
              throw new TypeError();
            }
            key = valueToKey_1.default(key);
            if (this.lower !== void 0) {
              var cmpResult = cmp_1.default(this.lower, key);
              if (cmpResult === 1 || cmpResult === 0 && this.lowerOpen) {
                return false;
              }
            }
            if (this.upper !== void 0) {
              var cmpResult = cmp_1.default(this.upper, key);
              if (cmpResult === -1 || cmpResult === 0 && this.upperOpen) {
                return false;
              }
            }
            return true;
          };
          FDBKeyRange3.prototype.toString = function() {
            return "[object IDBKeyRange]";
          };
          return FDBKeyRange3;
        })()
      );
      exports.default = FDBKeyRange2;
    }
  });

  // node_modules/fake-indexeddb/build/lib/extractKey.js
  var require_extractKey = __commonJS({
    "node_modules/fake-indexeddb/build/lib/extractKey.js"(exports) {
      "use strict";
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var valueToKey_1 = require_valueToKey();
      var extractKey = function(keyPath, value) {
        var e_1, _a;
        if (Array.isArray(keyPath)) {
          var result = [];
          try {
            for (var keyPath_1 = __values(keyPath), keyPath_1_1 = keyPath_1.next(); !keyPath_1_1.done; keyPath_1_1 = keyPath_1.next()) {
              var item = keyPath_1_1.value;
              if (item !== void 0 && item !== null && typeof item !== "string" && item.toString) {
                item = item.toString();
              }
              result.push(valueToKey_1.default(extractKey(item, value)));
            }
          } catch (e_1_1) {
            e_1 = { error: e_1_1 };
          } finally {
            try {
              if (keyPath_1_1 && !keyPath_1_1.done && (_a = keyPath_1.return)) _a.call(keyPath_1);
            } finally {
              if (e_1) throw e_1.error;
            }
          }
          return result;
        }
        if (keyPath === "") {
          return value;
        }
        var remainingKeyPath = keyPath;
        var object = value;
        while (remainingKeyPath !== null) {
          var identifier = void 0;
          var i = remainingKeyPath.indexOf(".");
          if (i >= 0) {
            identifier = remainingKeyPath.slice(0, i);
            remainingKeyPath = remainingKeyPath.slice(i + 1);
          } else {
            identifier = remainingKeyPath;
            remainingKeyPath = null;
          }
          if (!object.hasOwnProperty(identifier)) {
            return;
          }
          object = object[identifier];
        }
        return object;
      };
      exports.default = extractKey;
    }
  });

  // node_modules/realistic-structured-clone/dist/index.js
  var require_dist = __commonJS({
    "node_modules/realistic-structured-clone/dist/index.js"(exports, module) {
      (function(f) {
        if (typeof exports === "object" && typeof module !== "undefined") {
          module.exports = f();
        } else if (typeof define === "function" && define.amd) {
          define([], f);
        } else {
          var g2;
          if (typeof window !== "undefined") {
            g2 = window;
          } else if (typeof globalThis !== "undefined") {
            g2 = globalThis;
          } else if (typeof self !== "undefined") {
            g2 = self;
          } else {
            g2 = this;
          }
          g2.realisticStructuredClone = f();
        }
      })(function() {
        var define2, module2, exports2;
        return (/* @__PURE__ */ (function() {
          function r(e, n, t) {
            function o(i2, f) {
              if (!n[i2]) {
                if (!e[i2]) {
                  var c = "function" == typeof __require && __require;
                  if (!f && c) return c(i2, true);
                  if (u) return u(i2, true);
                  var a = new Error("Cannot find module '" + i2 + "'");
                  throw a.code = "MODULE_NOT_FOUND", a;
                }
                var p = n[i2] = { exports: {} };
                e[i2][0].call(p.exports, function(r2) {
                  var n2 = e[i2][1][r2];
                  return o(n2 || r2);
                }, p, p.exports, r, e, n, t);
              }
              return n[i2].exports;
            }
            for (var u = "function" == typeof __require && __require, i = 0; i < t.length; i++) o(t[i]);
            return o;
          }
          return r;
        })())({ 1: [function(_dereq_, module3, exports3) {
          "use strict";
          _dereq_("core-js/actual/array/includes");
          _dereq_("core-js/actual/object/values");
          var DOMException2 = _dereq_("domexception");
          var Typeson = _dereq_("typeson");
          var structuredCloningThrowing = _dereq_("typeson-registry/dist/presets/structured-cloning-throwing");
          var globalVar = typeof window !== "undefined" ? window : typeof WorkerGlobalScope !== "undefined" ? self : typeof globalThis !== "undefined" ? globalThis : Function("return this;")();
          if (!globalVar.DOMException) {
            globalVar.DOMException = DOMException2;
          }
          var TSON = new Typeson().register(structuredCloningThrowing);
          function realisticStructuredClone(obj) {
            return TSON.revive(TSON.encapsulate(obj));
          }
          module3.exports = realisticStructuredClone;
        }, { "core-js/actual/array/includes": 2, "core-js/actual/object/values": 3, "domexception": 83, "typeson": 86, "typeson-registry/dist/presets/structured-cloning-throwing": 85 }], 2: [function(_dereq_, module3, exports3) {
          "use strict";
          var parent = _dereq_("../../stable/array/includes");
          module3.exports = parent;
        }, { "../../stable/array/includes": 78 }], 3: [function(_dereq_, module3, exports3) {
          "use strict";
          var parent = _dereq_("../../stable/object/values");
          module3.exports = parent;
        }, { "../../stable/object/values": 79 }], 4: [function(_dereq_, module3, exports3) {
          "use strict";
          _dereq_("../../modules/es.array.includes");
          var entryUnbind = _dereq_("../../internals/entry-unbind");
          module3.exports = entryUnbind("Array", "includes");
        }, { "../../internals/entry-unbind": 18, "../../modules/es.array.includes": 76 }], 5: [function(_dereq_, module3, exports3) {
          "use strict";
          _dereq_("../../modules/es.object.values");
          var path = _dereq_("../../internals/path");
          module3.exports = path.Object.values;
        }, { "../../internals/path": 57, "../../modules/es.object.values": 77 }], 6: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var isCallable = _dereq_("../internals/is-callable");
          var tryToString = _dereq_("../internals/try-to-string");
          var TypeError2 = global2.TypeError;
          module3.exports = function(argument) {
            if (isCallable(argument)) return argument;
            throw TypeError2(tryToString(argument) + " is not a function");
          };
        }, { "../internals/global": 28, "../internals/is-callable": 36, "../internals/try-to-string": 71 }], 7: [function(_dereq_, module3, exports3) {
          "use strict";
          var wellKnownSymbol = _dereq_("../internals/well-known-symbol");
          var create = _dereq_("../internals/object-create");
          var definePropertyModule = _dereq_("../internals/object-define-property");
          var UNSCOPABLES = wellKnownSymbol("unscopables");
          var ArrayPrototype = Array.prototype;
          if (ArrayPrototype[UNSCOPABLES] == void 0) {
            definePropertyModule.f(ArrayPrototype, UNSCOPABLES, {
              configurable: true,
              value: create(null)
            });
          }
          module3.exports = function(key) {
            ArrayPrototype[UNSCOPABLES][key] = true;
          };
        }, { "../internals/object-create": 44, "../internals/object-define-property": 46, "../internals/well-known-symbol": 75 }], 8: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var isObject = _dereq_("../internals/is-object");
          var String2 = global2.String;
          var TypeError2 = global2.TypeError;
          module3.exports = function(argument) {
            if (isObject(argument)) return argument;
            throw TypeError2(String2(argument) + " is not an object");
          };
        }, { "../internals/global": 28, "../internals/is-object": 38 }], 9: [function(_dereq_, module3, exports3) {
          "use strict";
          var toIndexedObject = _dereq_("../internals/to-indexed-object");
          var toAbsoluteIndex = _dereq_("../internals/to-absolute-index");
          var lengthOfArrayLike = _dereq_("../internals/length-of-array-like");
          var createMethod = function createMethod2(IS_INCLUDES) {
            return function($this, el, fromIndex) {
              var O = toIndexedObject($this);
              var length = lengthOfArrayLike(O);
              var index = toAbsoluteIndex(fromIndex, length);
              var value;
              if (IS_INCLUDES && el != el) while (length > index) {
                value = O[index++];
                if (value != value) return true;
              }
              else for (; length > index; index++) {
                if ((IS_INCLUDES || index in O) && O[index] === el) return IS_INCLUDES || index || 0;
              }
              return !IS_INCLUDES && -1;
            };
          };
          module3.exports = {
            // `Array.prototype.includes` method
            // https://tc39.es/ecma262/#sec-array.prototype.includes
            includes: createMethod(true),
            // `Array.prototype.indexOf` method
            // https://tc39.es/ecma262/#sec-array.prototype.indexof
            indexOf: createMethod(false)
          };
        }, { "../internals/length-of-array-like": 41, "../internals/to-absolute-index": 64, "../internals/to-indexed-object": 65 }], 10: [function(_dereq_, module3, exports3) {
          "use strict";
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var toString = uncurryThis({}.toString);
          var stringSlice = uncurryThis("".slice);
          module3.exports = function(it) {
            return stringSlice(toString(it), 8, -1);
          };
        }, { "../internals/function-uncurry-this": 25 }], 11: [function(_dereq_, module3, exports3) {
          "use strict";
          var hasOwn = _dereq_("../internals/has-own-property");
          var ownKeys = _dereq_("../internals/own-keys");
          var getOwnPropertyDescriptorModule = _dereq_("../internals/object-get-own-property-descriptor");
          var definePropertyModule = _dereq_("../internals/object-define-property");
          module3.exports = function(target, source, exceptions) {
            var keys = ownKeys(source);
            var defineProperty = definePropertyModule.f;
            var getOwnPropertyDescriptor = getOwnPropertyDescriptorModule.f;
            for (var i = 0; i < keys.length; i++) {
              var key = keys[i];
              if (!hasOwn(target, key) && !(exceptions && hasOwn(exceptions, key))) {
                defineProperty(target, key, getOwnPropertyDescriptor(source, key));
              }
            }
          };
        }, { "../internals/has-own-property": 29, "../internals/object-define-property": 46, "../internals/object-get-own-property-descriptor": 47, "../internals/own-keys": 56 }], 12: [function(_dereq_, module3, exports3) {
          "use strict";
          var DESCRIPTORS = _dereq_("../internals/descriptors");
          var definePropertyModule = _dereq_("../internals/object-define-property");
          var createPropertyDescriptor = _dereq_("../internals/create-property-descriptor");
          module3.exports = DESCRIPTORS ? function(object, key, value) {
            return definePropertyModule.f(object, key, createPropertyDescriptor(1, value));
          } : function(object, key, value) {
            object[key] = value;
            return object;
          };
        }, { "../internals/create-property-descriptor": 13, "../internals/descriptors": 14, "../internals/object-define-property": 46 }], 13: [function(_dereq_, module3, exports3) {
          "use strict";
          module3.exports = function(bitmap, value) {
            return {
              enumerable: !(bitmap & 1),
              configurable: !(bitmap & 2),
              writable: !(bitmap & 4),
              value
            };
          };
        }, {}], 14: [function(_dereq_, module3, exports3) {
          "use strict";
          var fails = _dereq_("../internals/fails");
          module3.exports = !fails(function() {
            return Object.defineProperty({}, 1, { get: function get() {
              return 7;
            } })[1] != 7;
          });
        }, { "../internals/fails": 21 }], 15: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var isObject = _dereq_("../internals/is-object");
          var document2 = global2.document;
          var EXISTS = isObject(document2) && isObject(document2.createElement);
          module3.exports = function(it) {
            return EXISTS ? document2.createElement(it) : {};
          };
        }, { "../internals/global": 28, "../internals/is-object": 38 }], 16: [function(_dereq_, module3, exports3) {
          "use strict";
          var getBuiltIn = _dereq_("../internals/get-built-in");
          module3.exports = getBuiltIn("navigator", "userAgent") || "";
        }, { "../internals/get-built-in": 26 }], 17: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var userAgent = _dereq_("../internals/engine-user-agent");
          var process = global2.process;
          var Deno = global2.Deno;
          var versions = process && process.versions || Deno && Deno.version;
          var v8 = versions && versions.v8;
          var match, version;
          if (v8) {
            match = v8.split(".");
            version = match[0] > 0 && match[0] < 4 ? 1 : +(match[0] + match[1]);
          }
          if (!version && userAgent) {
            match = userAgent.match(/Edge\/(\d+)/);
            if (!match || match[1] >= 74) {
              match = userAgent.match(/Chrome\/(\d+)/);
              if (match) version = +match[1];
            }
          }
          module3.exports = version;
        }, { "../internals/engine-user-agent": 16, "../internals/global": 28 }], 18: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          module3.exports = function(CONSTRUCTOR, METHOD) {
            return uncurryThis(global2[CONSTRUCTOR].prototype[METHOD]);
          };
        }, { "../internals/function-uncurry-this": 25, "../internals/global": 28 }], 19: [function(_dereq_, module3, exports3) {
          "use strict";
          module3.exports = ["constructor", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "toLocaleString", "toString", "valueOf"];
        }, {}], 20: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          var global2 = _dereq_("../internals/global");
          var getOwnPropertyDescriptor = _dereq_("../internals/object-get-own-property-descriptor").f;
          var createNonEnumerableProperty = _dereq_("../internals/create-non-enumerable-property");
          var redefine = _dereq_("../internals/redefine");
          var setGlobal = _dereq_("../internals/set-global");
          var copyConstructorProperties = _dereq_("../internals/copy-constructor-properties");
          var isForced = _dereq_("../internals/is-forced");
          module3.exports = function(options, source) {
            var TARGET = options.target;
            var GLOBAL = options.global;
            var STATIC = options.stat;
            var FORCED, target, key, targetProperty, sourceProperty, descriptor;
            if (GLOBAL) {
              target = global2;
            } else if (STATIC) {
              target = global2[TARGET] || setGlobal(TARGET, {});
            } else {
              target = (global2[TARGET] || {}).prototype;
            }
            if (target) for (key in source) {
              sourceProperty = source[key];
              if (options.noTargetGet) {
                descriptor = getOwnPropertyDescriptor(target, key);
                targetProperty = descriptor && descriptor.value;
              } else targetProperty = target[key];
              FORCED = isForced(GLOBAL ? key : TARGET + (STATIC ? "." : "#") + key, options.forced);
              if (!FORCED && targetProperty !== void 0) {
                if ((typeof sourceProperty === "undefined" ? "undefined" : _typeof(sourceProperty)) == (typeof targetProperty === "undefined" ? "undefined" : _typeof(targetProperty))) continue;
                copyConstructorProperties(sourceProperty, targetProperty);
              }
              if (options.sham || targetProperty && targetProperty.sham) {
                createNonEnumerableProperty(sourceProperty, "sham", true);
              }
              redefine(target, key, sourceProperty, options);
            }
          };
        }, { "../internals/copy-constructor-properties": 11, "../internals/create-non-enumerable-property": 12, "../internals/global": 28, "../internals/is-forced": 37, "../internals/object-get-own-property-descriptor": 47, "../internals/redefine": 58, "../internals/set-global": 60 }], 21: [function(_dereq_, module3, exports3) {
          "use strict";
          module3.exports = function(exec) {
            try {
              return !!exec();
            } catch (error) {
              return true;
            }
          };
        }, {}], 22: [function(_dereq_, module3, exports3) {
          "use strict";
          var fails = _dereq_("../internals/fails");
          module3.exports = !fails(function() {
            var test = function() {
            }.bind();
            return typeof test != "function" || test.hasOwnProperty("prototype");
          });
        }, { "../internals/fails": 21 }], 23: [function(_dereq_, module3, exports3) {
          "use strict";
          var NATIVE_BIND = _dereq_("../internals/function-bind-native");
          var call = Function.prototype.call;
          module3.exports = NATIVE_BIND ? call.bind(call) : function() {
            return call.apply(call, arguments);
          };
        }, { "../internals/function-bind-native": 22 }], 24: [function(_dereq_, module3, exports3) {
          "use strict";
          var DESCRIPTORS = _dereq_("../internals/descriptors");
          var hasOwn = _dereq_("../internals/has-own-property");
          var FunctionPrototype = Function.prototype;
          var getDescriptor = DESCRIPTORS && Object.getOwnPropertyDescriptor;
          var EXISTS = hasOwn(FunctionPrototype, "name");
          var PROPER = EXISTS && function something() {
          }.name === "something";
          var CONFIGURABLE = EXISTS && (!DESCRIPTORS || DESCRIPTORS && getDescriptor(FunctionPrototype, "name").configurable);
          module3.exports = {
            EXISTS,
            PROPER,
            CONFIGURABLE
          };
        }, { "../internals/descriptors": 14, "../internals/has-own-property": 29 }], 25: [function(_dereq_, module3, exports3) {
          "use strict";
          var NATIVE_BIND = _dereq_("../internals/function-bind-native");
          var FunctionPrototype = Function.prototype;
          var bind = FunctionPrototype.bind;
          var call = FunctionPrototype.call;
          var uncurryThis = NATIVE_BIND && bind.bind(call, call);
          module3.exports = NATIVE_BIND ? function(fn) {
            return fn && uncurryThis(fn);
          } : function(fn) {
            return fn && function() {
              return call.apply(fn, arguments);
            };
          };
        }, { "../internals/function-bind-native": 22 }], 26: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var isCallable = _dereq_("../internals/is-callable");
          var aFunction = function aFunction2(argument) {
            return isCallable(argument) ? argument : void 0;
          };
          module3.exports = function(namespace, method) {
            return arguments.length < 2 ? aFunction(global2[namespace]) : global2[namespace] && global2[namespace][method];
          };
        }, { "../internals/global": 28, "../internals/is-callable": 36 }], 27: [function(_dereq_, module3, exports3) {
          "use strict";
          var aCallable = _dereq_("../internals/a-callable");
          module3.exports = function(V, P) {
            var func = V[P];
            return func == null ? void 0 : aCallable(func);
          };
        }, { "../internals/a-callable": 6 }], 28: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          var check = function check2(it) {
            return it && it.Math == Math && it;
          };
          module3.exports = // eslint-disable-next-line es/no-global-this -- safe
          check((typeof globalThis === "undefined" ? "undefined" : _typeof(globalThis)) == "object" && globalThis) || check((typeof window === "undefined" ? "undefined" : _typeof(window)) == "object" && window) || // eslint-disable-next-line no-restricted-globals -- safe
          check((typeof self === "undefined" ? "undefined" : _typeof(self)) == "object" && self) || check((typeof globalThis === "undefined" ? "undefined" : _typeof(globalThis)) == "object" && globalThis) || // eslint-disable-next-line no-new-func -- fallback
          /* @__PURE__ */ (function() {
            return this;
          })() || Function("return this")();
        }, {}], 29: [function(_dereq_, module3, exports3) {
          "use strict";
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var toObject = _dereq_("../internals/to-object");
          var hasOwnProperty = uncurryThis({}.hasOwnProperty);
          module3.exports = Object.hasOwn || function hasOwn(it, key) {
            return hasOwnProperty(toObject(it), key);
          };
        }, { "../internals/function-uncurry-this": 25, "../internals/to-object": 68 }], 30: [function(_dereq_, module3, exports3) {
          "use strict";
          module3.exports = {};
        }, {}], 31: [function(_dereq_, module3, exports3) {
          "use strict";
          var getBuiltIn = _dereq_("../internals/get-built-in");
          module3.exports = getBuiltIn("document", "documentElement");
        }, { "../internals/get-built-in": 26 }], 32: [function(_dereq_, module3, exports3) {
          "use strict";
          var DESCRIPTORS = _dereq_("../internals/descriptors");
          var fails = _dereq_("../internals/fails");
          var createElement = _dereq_("../internals/document-create-element");
          module3.exports = !DESCRIPTORS && !fails(function() {
            return Object.defineProperty(createElement("div"), "a", {
              get: function get() {
                return 7;
              }
            }).a != 7;
          });
        }, { "../internals/descriptors": 14, "../internals/document-create-element": 15, "../internals/fails": 21 }], 33: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var fails = _dereq_("../internals/fails");
          var classof = _dereq_("../internals/classof-raw");
          var Object2 = global2.Object;
          var split = uncurryThis("".split);
          module3.exports = fails(function() {
            return !Object2("z").propertyIsEnumerable(0);
          }) ? function(it) {
            return classof(it) == "String" ? split(it, "") : Object2(it);
          } : Object2;
        }, { "../internals/classof-raw": 10, "../internals/fails": 21, "../internals/function-uncurry-this": 25, "../internals/global": 28 }], 34: [function(_dereq_, module3, exports3) {
          "use strict";
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var isCallable = _dereq_("../internals/is-callable");
          var store = _dereq_("../internals/shared-store");
          var functionToString = uncurryThis(Function.toString);
          if (!isCallable(store.inspectSource)) {
            store.inspectSource = function(it) {
              return functionToString(it);
            };
          }
          module3.exports = store.inspectSource;
        }, { "../internals/function-uncurry-this": 25, "../internals/is-callable": 36, "../internals/shared-store": 62 }], 35: [function(_dereq_, module3, exports3) {
          "use strict";
          var NATIVE_WEAK_MAP = _dereq_("../internals/native-weak-map");
          var global2 = _dereq_("../internals/global");
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var isObject = _dereq_("../internals/is-object");
          var createNonEnumerableProperty = _dereq_("../internals/create-non-enumerable-property");
          var hasOwn = _dereq_("../internals/has-own-property");
          var shared = _dereq_("../internals/shared-store");
          var sharedKey = _dereq_("../internals/shared-key");
          var hiddenKeys = _dereq_("../internals/hidden-keys");
          var OBJECT_ALREADY_INITIALIZED = "Object already initialized";
          var TypeError2 = global2.TypeError;
          var WeakMap = global2.WeakMap;
          var set, get, has;
          var enforce = function enforce2(it) {
            return has(it) ? get(it) : set(it, {});
          };
          var getterFor = function getterFor2(TYPE) {
            return function(it) {
              var state;
              if (!isObject(it) || (state = get(it)).type !== TYPE) {
                throw TypeError2("Incompatible receiver, " + TYPE + " required");
              }
              return state;
            };
          };
          if (NATIVE_WEAK_MAP || shared.state) {
            var store = shared.state || (shared.state = new WeakMap());
            var wmget = uncurryThis(store.get);
            var wmhas = uncurryThis(store.has);
            var wmset = uncurryThis(store.set);
            set = function set2(it, metadata) {
              if (wmhas(store, it)) throw new TypeError2(OBJECT_ALREADY_INITIALIZED);
              metadata.facade = it;
              wmset(store, it, metadata);
              return metadata;
            };
            get = function get2(it) {
              return wmget(store, it) || {};
            };
            has = function has2(it) {
              return wmhas(store, it);
            };
          } else {
            var STATE = sharedKey("state");
            hiddenKeys[STATE] = true;
            set = function set2(it, metadata) {
              if (hasOwn(it, STATE)) throw new TypeError2(OBJECT_ALREADY_INITIALIZED);
              metadata.facade = it;
              createNonEnumerableProperty(it, STATE, metadata);
              return metadata;
            };
            get = function get2(it) {
              return hasOwn(it, STATE) ? it[STATE] : {};
            };
            has = function has2(it) {
              return hasOwn(it, STATE);
            };
          }
          module3.exports = {
            set,
            get,
            has,
            enforce,
            getterFor
          };
        }, { "../internals/create-non-enumerable-property": 12, "../internals/function-uncurry-this": 25, "../internals/global": 28, "../internals/has-own-property": 29, "../internals/hidden-keys": 30, "../internals/is-object": 38, "../internals/native-weak-map": 43, "../internals/shared-key": 61, "../internals/shared-store": 62 }], 36: [function(_dereq_, module3, exports3) {
          "use strict";
          module3.exports = function(argument) {
            return typeof argument == "function";
          };
        }, {}], 37: [function(_dereq_, module3, exports3) {
          "use strict";
          var fails = _dereq_("../internals/fails");
          var isCallable = _dereq_("../internals/is-callable");
          var replacement = /#|\.prototype\./;
          var isForced = function isForced2(feature, detection) {
            var value = data[normalize(feature)];
            return value == POLYFILL ? true : value == NATIVE ? false : isCallable(detection) ? fails(detection) : !!detection;
          };
          var normalize = isForced.normalize = function(string) {
            return String(string).replace(replacement, ".").toLowerCase();
          };
          var data = isForced.data = {};
          var NATIVE = isForced.NATIVE = "N";
          var POLYFILL = isForced.POLYFILL = "P";
          module3.exports = isForced;
        }, { "../internals/fails": 21, "../internals/is-callable": 36 }], 38: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          var isCallable = _dereq_("../internals/is-callable");
          module3.exports = function(it) {
            return (typeof it === "undefined" ? "undefined" : _typeof(it)) == "object" ? it !== null : isCallable(it);
          };
        }, { "../internals/is-callable": 36 }], 39: [function(_dereq_, module3, exports3) {
          "use strict";
          module3.exports = false;
        }, {}], 40: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          var global2 = _dereq_("../internals/global");
          var getBuiltIn = _dereq_("../internals/get-built-in");
          var isCallable = _dereq_("../internals/is-callable");
          var isPrototypeOf = _dereq_("../internals/object-is-prototype-of");
          var USE_SYMBOL_AS_UID = _dereq_("../internals/use-symbol-as-uid");
          var Object2 = global2.Object;
          module3.exports = USE_SYMBOL_AS_UID ? function(it) {
            return (typeof it === "undefined" ? "undefined" : _typeof(it)) == "symbol";
          } : function(it) {
            var $Symbol = getBuiltIn("Symbol");
            return isCallable($Symbol) && isPrototypeOf($Symbol.prototype, Object2(it));
          };
        }, { "../internals/get-built-in": 26, "../internals/global": 28, "../internals/is-callable": 36, "../internals/object-is-prototype-of": 50, "../internals/use-symbol-as-uid": 73 }], 41: [function(_dereq_, module3, exports3) {
          "use strict";
          var toLength = _dereq_("../internals/to-length");
          module3.exports = function(obj) {
            return toLength(obj.length);
          };
        }, { "../internals/to-length": 67 }], 42: [function(_dereq_, module3, exports3) {
          "use strict";
          var V8_VERSION = _dereq_("../internals/engine-v8-version");
          var fails = _dereq_("../internals/fails");
          module3.exports = !!Object.getOwnPropertySymbols && !fails(function() {
            var symbol = /* @__PURE__ */ Symbol();
            return !String(symbol) || !(Object(symbol) instanceof Symbol) || // Chrome 38-40 symbols are not inherited from DOM collections prototypes to instances
            !Symbol.sham && V8_VERSION && V8_VERSION < 41;
          });
        }, { "../internals/engine-v8-version": 17, "../internals/fails": 21 }], 43: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var isCallable = _dereq_("../internals/is-callable");
          var inspectSource = _dereq_("../internals/inspect-source");
          var WeakMap = global2.WeakMap;
          module3.exports = isCallable(WeakMap) && /native code/.test(inspectSource(WeakMap));
        }, { "../internals/global": 28, "../internals/inspect-source": 34, "../internals/is-callable": 36 }], 44: [function(_dereq_, module3, exports3) {
          "use strict";
          var anObject = _dereq_("../internals/an-object");
          var definePropertiesModule = _dereq_("../internals/object-define-properties");
          var enumBugKeys = _dereq_("../internals/enum-bug-keys");
          var hiddenKeys = _dereq_("../internals/hidden-keys");
          var html = _dereq_("../internals/html");
          var documentCreateElement = _dereq_("../internals/document-create-element");
          var sharedKey = _dereq_("../internals/shared-key");
          var GT = ">";
          var LT = "<";
          var PROTOTYPE = "prototype";
          var SCRIPT = "script";
          var IE_PROTO = sharedKey("IE_PROTO");
          var EmptyConstructor = function EmptyConstructor2() {
          };
          var scriptTag = function scriptTag2(content) {
            return LT + SCRIPT + GT + content + LT + "/" + SCRIPT + GT;
          };
          var NullProtoObjectViaActiveX = function NullProtoObjectViaActiveX2(activeXDocument2) {
            activeXDocument2.write(scriptTag(""));
            activeXDocument2.close();
            var temp = activeXDocument2.parentWindow.Object;
            activeXDocument2 = null;
            return temp;
          };
          var NullProtoObjectViaIFrame = function NullProtoObjectViaIFrame2() {
            var iframe = documentCreateElement("iframe");
            var JS = "java" + SCRIPT + ":";
            var iframeDocument;
            iframe.style.display = "none";
            html.appendChild(iframe);
            iframe.src = String(JS);
            iframeDocument = iframe.contentWindow.document;
            iframeDocument.open();
            iframeDocument.write(scriptTag("document.F=Object"));
            iframeDocument.close();
            return iframeDocument.F;
          };
          var activeXDocument;
          var _NullProtoObject = function NullProtoObject() {
            try {
              activeXDocument = new ActiveXObject("htmlfile");
            } catch (error) {
            }
            _NullProtoObject = typeof document != "undefined" ? document.domain && activeXDocument ? NullProtoObjectViaActiveX(activeXDocument) : NullProtoObjectViaIFrame() : NullProtoObjectViaActiveX(activeXDocument);
            var length = enumBugKeys.length;
            while (length--) {
              delete _NullProtoObject[PROTOTYPE][enumBugKeys[length]];
            }
            return _NullProtoObject();
          };
          hiddenKeys[IE_PROTO] = true;
          module3.exports = Object.create || function create(O, Properties) {
            var result;
            if (O !== null) {
              EmptyConstructor[PROTOTYPE] = anObject(O);
              result = new EmptyConstructor();
              EmptyConstructor[PROTOTYPE] = null;
              result[IE_PROTO] = O;
            } else result = _NullProtoObject();
            return Properties === void 0 ? result : definePropertiesModule.f(result, Properties);
          };
        }, { "../internals/an-object": 8, "../internals/document-create-element": 15, "../internals/enum-bug-keys": 19, "../internals/hidden-keys": 30, "../internals/html": 31, "../internals/object-define-properties": 45, "../internals/shared-key": 61 }], 45: [function(_dereq_, module3, exports3) {
          "use strict";
          var DESCRIPTORS = _dereq_("../internals/descriptors");
          var V8_PROTOTYPE_DEFINE_BUG = _dereq_("../internals/v8-prototype-define-bug");
          var definePropertyModule = _dereq_("../internals/object-define-property");
          var anObject = _dereq_("../internals/an-object");
          var toIndexedObject = _dereq_("../internals/to-indexed-object");
          var objectKeys = _dereq_("../internals/object-keys");
          exports3.f = DESCRIPTORS && !V8_PROTOTYPE_DEFINE_BUG ? Object.defineProperties : function defineProperties(O, Properties) {
            anObject(O);
            var props = toIndexedObject(Properties);
            var keys = objectKeys(Properties);
            var length = keys.length;
            var index = 0;
            var key;
            while (length > index) {
              definePropertyModule.f(O, key = keys[index++], props[key]);
            }
            return O;
          };
        }, { "../internals/an-object": 8, "../internals/descriptors": 14, "../internals/object-define-property": 46, "../internals/object-keys": 52, "../internals/to-indexed-object": 65, "../internals/v8-prototype-define-bug": 74 }], 46: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var DESCRIPTORS = _dereq_("../internals/descriptors");
          var IE8_DOM_DEFINE = _dereq_("../internals/ie8-dom-define");
          var V8_PROTOTYPE_DEFINE_BUG = _dereq_("../internals/v8-prototype-define-bug");
          var anObject = _dereq_("../internals/an-object");
          var toPropertyKey = _dereq_("../internals/to-property-key");
          var TypeError2 = global2.TypeError;
          var $defineProperty = Object.defineProperty;
          var $getOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
          var ENUMERABLE = "enumerable";
          var CONFIGURABLE = "configurable";
          var WRITABLE = "writable";
          exports3.f = DESCRIPTORS ? V8_PROTOTYPE_DEFINE_BUG ? function defineProperty(O, P, Attributes) {
            anObject(O);
            P = toPropertyKey(P);
            anObject(Attributes);
            if (typeof O === "function" && P === "prototype" && "value" in Attributes && WRITABLE in Attributes && !Attributes[WRITABLE]) {
              var current = $getOwnPropertyDescriptor(O, P);
              if (current && current[WRITABLE]) {
                O[P] = Attributes.value;
                Attributes = {
                  configurable: CONFIGURABLE in Attributes ? Attributes[CONFIGURABLE] : current[CONFIGURABLE],
                  enumerable: ENUMERABLE in Attributes ? Attributes[ENUMERABLE] : current[ENUMERABLE],
                  writable: false
                };
              }
            }
            return $defineProperty(O, P, Attributes);
          } : $defineProperty : function defineProperty(O, P, Attributes) {
            anObject(O);
            P = toPropertyKey(P);
            anObject(Attributes);
            if (IE8_DOM_DEFINE) try {
              return $defineProperty(O, P, Attributes);
            } catch (error) {
            }
            if ("get" in Attributes || "set" in Attributes) throw TypeError2("Accessors not supported");
            if ("value" in Attributes) O[P] = Attributes.value;
            return O;
          };
        }, { "../internals/an-object": 8, "../internals/descriptors": 14, "../internals/global": 28, "../internals/ie8-dom-define": 32, "../internals/to-property-key": 70, "../internals/v8-prototype-define-bug": 74 }], 47: [function(_dereq_, module3, exports3) {
          "use strict";
          var DESCRIPTORS = _dereq_("../internals/descriptors");
          var call = _dereq_("../internals/function-call");
          var propertyIsEnumerableModule = _dereq_("../internals/object-property-is-enumerable");
          var createPropertyDescriptor = _dereq_("../internals/create-property-descriptor");
          var toIndexedObject = _dereq_("../internals/to-indexed-object");
          var toPropertyKey = _dereq_("../internals/to-property-key");
          var hasOwn = _dereq_("../internals/has-own-property");
          var IE8_DOM_DEFINE = _dereq_("../internals/ie8-dom-define");
          var $getOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
          exports3.f = DESCRIPTORS ? $getOwnPropertyDescriptor : function getOwnPropertyDescriptor(O, P) {
            O = toIndexedObject(O);
            P = toPropertyKey(P);
            if (IE8_DOM_DEFINE) try {
              return $getOwnPropertyDescriptor(O, P);
            } catch (error) {
            }
            if (hasOwn(O, P)) return createPropertyDescriptor(!call(propertyIsEnumerableModule.f, O, P), O[P]);
          };
        }, { "../internals/create-property-descriptor": 13, "../internals/descriptors": 14, "../internals/function-call": 23, "../internals/has-own-property": 29, "../internals/ie8-dom-define": 32, "../internals/object-property-is-enumerable": 53, "../internals/to-indexed-object": 65, "../internals/to-property-key": 70 }], 48: [function(_dereq_, module3, exports3) {
          "use strict";
          var internalObjectKeys = _dereq_("../internals/object-keys-internal");
          var enumBugKeys = _dereq_("../internals/enum-bug-keys");
          var hiddenKeys = enumBugKeys.concat("length", "prototype");
          exports3.f = Object.getOwnPropertyNames || function getOwnPropertyNames(O) {
            return internalObjectKeys(O, hiddenKeys);
          };
        }, { "../internals/enum-bug-keys": 19, "../internals/object-keys-internal": 51 }], 49: [function(_dereq_, module3, exports3) {
          "use strict";
          exports3.f = Object.getOwnPropertySymbols;
        }, {}], 50: [function(_dereq_, module3, exports3) {
          "use strict";
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          module3.exports = uncurryThis({}.isPrototypeOf);
        }, { "../internals/function-uncurry-this": 25 }], 51: [function(_dereq_, module3, exports3) {
          "use strict";
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var hasOwn = _dereq_("../internals/has-own-property");
          var toIndexedObject = _dereq_("../internals/to-indexed-object");
          var indexOf = _dereq_("../internals/array-includes").indexOf;
          var hiddenKeys = _dereq_("../internals/hidden-keys");
          var push = uncurryThis([].push);
          module3.exports = function(object, names) {
            var O = toIndexedObject(object);
            var i = 0;
            var result = [];
            var key;
            for (key in O) {
              !hasOwn(hiddenKeys, key) && hasOwn(O, key) && push(result, key);
            }
            while (names.length > i) {
              if (hasOwn(O, key = names[i++])) {
                ~indexOf(result, key) || push(result, key);
              }
            }
            return result;
          };
        }, { "../internals/array-includes": 9, "../internals/function-uncurry-this": 25, "../internals/has-own-property": 29, "../internals/hidden-keys": 30, "../internals/to-indexed-object": 65 }], 52: [function(_dereq_, module3, exports3) {
          "use strict";
          var internalObjectKeys = _dereq_("../internals/object-keys-internal");
          var enumBugKeys = _dereq_("../internals/enum-bug-keys");
          module3.exports = Object.keys || function keys(O) {
            return internalObjectKeys(O, enumBugKeys);
          };
        }, { "../internals/enum-bug-keys": 19, "../internals/object-keys-internal": 51 }], 53: [function(_dereq_, module3, exports3) {
          "use strict";
          var $propertyIsEnumerable = {}.propertyIsEnumerable;
          var getOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
          var NASHORN_BUG = getOwnPropertyDescriptor && !$propertyIsEnumerable.call({ 1: 2 }, 1);
          exports3.f = NASHORN_BUG ? function propertyIsEnumerable(V) {
            var descriptor = getOwnPropertyDescriptor(this, V);
            return !!descriptor && descriptor.enumerable;
          } : $propertyIsEnumerable;
        }, {}], 54: [function(_dereq_, module3, exports3) {
          "use strict";
          var DESCRIPTORS = _dereq_("../internals/descriptors");
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var objectKeys = _dereq_("../internals/object-keys");
          var toIndexedObject = _dereq_("../internals/to-indexed-object");
          var $propertyIsEnumerable = _dereq_("../internals/object-property-is-enumerable").f;
          var propertyIsEnumerable = uncurryThis($propertyIsEnumerable);
          var push = uncurryThis([].push);
          var createMethod = function createMethod2(TO_ENTRIES) {
            return function(it) {
              var O = toIndexedObject(it);
              var keys = objectKeys(O);
              var length = keys.length;
              var i = 0;
              var result = [];
              var key;
              while (length > i) {
                key = keys[i++];
                if (!DESCRIPTORS || propertyIsEnumerable(O, key)) {
                  push(result, TO_ENTRIES ? [key, O[key]] : O[key]);
                }
              }
              return result;
            };
          };
          module3.exports = {
            // `Object.entries` method
            // https://tc39.es/ecma262/#sec-object.entries
            entries: createMethod(true),
            // `Object.values` method
            // https://tc39.es/ecma262/#sec-object.values
            values: createMethod(false)
          };
        }, { "../internals/descriptors": 14, "../internals/function-uncurry-this": 25, "../internals/object-keys": 52, "../internals/object-property-is-enumerable": 53, "../internals/to-indexed-object": 65 }], 55: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var call = _dereq_("../internals/function-call");
          var isCallable = _dereq_("../internals/is-callable");
          var isObject = _dereq_("../internals/is-object");
          var TypeError2 = global2.TypeError;
          module3.exports = function(input, pref) {
            var fn, val;
            if (pref === "string" && isCallable(fn = input.toString) && !isObject(val = call(fn, input))) return val;
            if (isCallable(fn = input.valueOf) && !isObject(val = call(fn, input))) return val;
            if (pref !== "string" && isCallable(fn = input.toString) && !isObject(val = call(fn, input))) return val;
            throw TypeError2("Can't convert object to primitive value");
          };
        }, { "../internals/function-call": 23, "../internals/global": 28, "../internals/is-callable": 36, "../internals/is-object": 38 }], 56: [function(_dereq_, module3, exports3) {
          "use strict";
          var getBuiltIn = _dereq_("../internals/get-built-in");
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var getOwnPropertyNamesModule = _dereq_("../internals/object-get-own-property-names");
          var getOwnPropertySymbolsModule = _dereq_("../internals/object-get-own-property-symbols");
          var anObject = _dereq_("../internals/an-object");
          var concat = uncurryThis([].concat);
          module3.exports = getBuiltIn("Reflect", "ownKeys") || function ownKeys(it) {
            var keys = getOwnPropertyNamesModule.f(anObject(it));
            var getOwnPropertySymbols = getOwnPropertySymbolsModule.f;
            return getOwnPropertySymbols ? concat(keys, getOwnPropertySymbols(it)) : keys;
          };
        }, { "../internals/an-object": 8, "../internals/function-uncurry-this": 25, "../internals/get-built-in": 26, "../internals/object-get-own-property-names": 48, "../internals/object-get-own-property-symbols": 49 }], 57: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          module3.exports = global2;
        }, { "../internals/global": 28 }], 58: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var isCallable = _dereq_("../internals/is-callable");
          var hasOwn = _dereq_("../internals/has-own-property");
          var createNonEnumerableProperty = _dereq_("../internals/create-non-enumerable-property");
          var setGlobal = _dereq_("../internals/set-global");
          var inspectSource = _dereq_("../internals/inspect-source");
          var InternalStateModule = _dereq_("../internals/internal-state");
          var CONFIGURABLE_FUNCTION_NAME = _dereq_("../internals/function-name").CONFIGURABLE;
          var getInternalState = InternalStateModule.get;
          var enforceInternalState = InternalStateModule.enforce;
          var TEMPLATE = String(String).split("String");
          (module3.exports = function(O, key, value, options) {
            var unsafe = options ? !!options.unsafe : false;
            var simple = options ? !!options.enumerable : false;
            var noTargetGet = options ? !!options.noTargetGet : false;
            var name = options && options.name !== void 0 ? options.name : key;
            var state;
            if (isCallable(value)) {
              if (String(name).slice(0, 7) === "Symbol(") {
                name = "[" + String(name).replace(/^Symbol\(([^)]*)\)/, "$1") + "]";
              }
              if (!hasOwn(value, "name") || CONFIGURABLE_FUNCTION_NAME && value.name !== name) {
                createNonEnumerableProperty(value, "name", name);
              }
              state = enforceInternalState(value);
              if (!state.source) {
                state.source = TEMPLATE.join(typeof name == "string" ? name : "");
              }
            }
            if (O === global2) {
              if (simple) O[key] = value;
              else setGlobal(key, value);
              return;
            } else if (!unsafe) {
              delete O[key];
            } else if (!noTargetGet && O[key]) {
              simple = true;
            }
            if (simple) O[key] = value;
            else createNonEnumerableProperty(O, key, value);
          })(Function.prototype, "toString", function toString() {
            return isCallable(this) && getInternalState(this).source || inspectSource(this);
          });
        }, { "../internals/create-non-enumerable-property": 12, "../internals/function-name": 24, "../internals/global": 28, "../internals/has-own-property": 29, "../internals/inspect-source": 34, "../internals/internal-state": 35, "../internals/is-callable": 36, "../internals/set-global": 60 }], 59: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var TypeError2 = global2.TypeError;
          module3.exports = function(it) {
            if (it == void 0) throw TypeError2("Can't call method on " + it);
            return it;
          };
        }, { "../internals/global": 28 }], 60: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var defineProperty = Object.defineProperty;
          module3.exports = function(key, value) {
            try {
              defineProperty(global2, key, { value, configurable: true, writable: true });
            } catch (error) {
              global2[key] = value;
            }
            return value;
          };
        }, { "../internals/global": 28 }], 61: [function(_dereq_, module3, exports3) {
          "use strict";
          var shared = _dereq_("../internals/shared");
          var uid = _dereq_("../internals/uid");
          var keys = shared("keys");
          module3.exports = function(key) {
            return keys[key] || (keys[key] = uid(key));
          };
        }, { "../internals/shared": 63, "../internals/uid": 72 }], 62: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var setGlobal = _dereq_("../internals/set-global");
          var SHARED = "__core-js_shared__";
          var store = global2[SHARED] || setGlobal(SHARED, {});
          module3.exports = store;
        }, { "../internals/global": 28, "../internals/set-global": 60 }], 63: [function(_dereq_, module3, exports3) {
          "use strict";
          var IS_PURE = _dereq_("../internals/is-pure");
          var store = _dereq_("../internals/shared-store");
          (module3.exports = function(key, value) {
            return store[key] || (store[key] = value !== void 0 ? value : {});
          })("versions", []).push({
            version: "3.21.1",
            mode: IS_PURE ? "pure" : "global",
            copyright: "\xA9 2014-2022 Denis Pushkarev (zloirock.ru)",
            license: "https://github.com/zloirock/core-js/blob/v3.21.1/LICENSE",
            source: "https://github.com/zloirock/core-js"
          });
        }, { "../internals/is-pure": 39, "../internals/shared-store": 62 }], 64: [function(_dereq_, module3, exports3) {
          "use strict";
          var toIntegerOrInfinity = _dereq_("../internals/to-integer-or-infinity");
          var max = Math.max;
          var min = Math.min;
          module3.exports = function(index, length) {
            var integer = toIntegerOrInfinity(index);
            return integer < 0 ? max(integer + length, 0) : min(integer, length);
          };
        }, { "../internals/to-integer-or-infinity": 66 }], 65: [function(_dereq_, module3, exports3) {
          "use strict";
          var IndexedObject = _dereq_("../internals/indexed-object");
          var requireObjectCoercible = _dereq_("../internals/require-object-coercible");
          module3.exports = function(it) {
            return IndexedObject(requireObjectCoercible(it));
          };
        }, { "../internals/indexed-object": 33, "../internals/require-object-coercible": 59 }], 66: [function(_dereq_, module3, exports3) {
          "use strict";
          var ceil = Math.ceil;
          var floor = Math.floor;
          module3.exports = function(argument) {
            var number = +argument;
            return number !== number || number === 0 ? 0 : (number > 0 ? floor : ceil)(number);
          };
        }, {}], 67: [function(_dereq_, module3, exports3) {
          "use strict";
          var toIntegerOrInfinity = _dereq_("../internals/to-integer-or-infinity");
          var min = Math.min;
          module3.exports = function(argument) {
            return argument > 0 ? min(toIntegerOrInfinity(argument), 9007199254740991) : 0;
          };
        }, { "../internals/to-integer-or-infinity": 66 }], 68: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var requireObjectCoercible = _dereq_("../internals/require-object-coercible");
          var Object2 = global2.Object;
          module3.exports = function(argument) {
            return Object2(requireObjectCoercible(argument));
          };
        }, { "../internals/global": 28, "../internals/require-object-coercible": 59 }], 69: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var call = _dereq_("../internals/function-call");
          var isObject = _dereq_("../internals/is-object");
          var isSymbol = _dereq_("../internals/is-symbol");
          var getMethod = _dereq_("../internals/get-method");
          var ordinaryToPrimitive = _dereq_("../internals/ordinary-to-primitive");
          var wellKnownSymbol = _dereq_("../internals/well-known-symbol");
          var TypeError2 = global2.TypeError;
          var TO_PRIMITIVE = wellKnownSymbol("toPrimitive");
          module3.exports = function(input, pref) {
            if (!isObject(input) || isSymbol(input)) return input;
            var exoticToPrim = getMethod(input, TO_PRIMITIVE);
            var result;
            if (exoticToPrim) {
              if (pref === void 0) pref = "default";
              result = call(exoticToPrim, input, pref);
              if (!isObject(result) || isSymbol(result)) return result;
              throw TypeError2("Can't convert object to primitive value");
            }
            if (pref === void 0) pref = "number";
            return ordinaryToPrimitive(input, pref);
          };
        }, { "../internals/function-call": 23, "../internals/get-method": 27, "../internals/global": 28, "../internals/is-object": 38, "../internals/is-symbol": 40, "../internals/ordinary-to-primitive": 55, "../internals/well-known-symbol": 75 }], 70: [function(_dereq_, module3, exports3) {
          "use strict";
          var toPrimitive = _dereq_("../internals/to-primitive");
          var isSymbol = _dereq_("../internals/is-symbol");
          module3.exports = function(argument) {
            var key = toPrimitive(argument, "string");
            return isSymbol(key) ? key : key + "";
          };
        }, { "../internals/is-symbol": 40, "../internals/to-primitive": 69 }], 71: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var String2 = global2.String;
          module3.exports = function(argument) {
            try {
              return String2(argument);
            } catch (error) {
              return "Object";
            }
          };
        }, { "../internals/global": 28 }], 72: [function(_dereq_, module3, exports3) {
          "use strict";
          var uncurryThis = _dereq_("../internals/function-uncurry-this");
          var id = 0;
          var postfix = Math.random();
          var toString = uncurryThis(1 .toString);
          module3.exports = function(key) {
            return "Symbol(" + (key === void 0 ? "" : key) + ")_" + toString(++id + postfix, 36);
          };
        }, { "../internals/function-uncurry-this": 25 }], 73: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          var NATIVE_SYMBOL = _dereq_("../internals/native-symbol");
          module3.exports = NATIVE_SYMBOL && !Symbol.sham && _typeof(Symbol.iterator) == "symbol";
        }, { "../internals/native-symbol": 42 }], 74: [function(_dereq_, module3, exports3) {
          "use strict";
          var DESCRIPTORS = _dereq_("../internals/descriptors");
          var fails = _dereq_("../internals/fails");
          module3.exports = DESCRIPTORS && fails(function() {
            return Object.defineProperty(function() {
            }, "prototype", {
              value: 42,
              writable: false
            }).prototype != 42;
          });
        }, { "../internals/descriptors": 14, "../internals/fails": 21 }], 75: [function(_dereq_, module3, exports3) {
          "use strict";
          var global2 = _dereq_("../internals/global");
          var shared = _dereq_("../internals/shared");
          var hasOwn = _dereq_("../internals/has-own-property");
          var uid = _dereq_("../internals/uid");
          var NATIVE_SYMBOL = _dereq_("../internals/native-symbol");
          var USE_SYMBOL_AS_UID = _dereq_("../internals/use-symbol-as-uid");
          var WellKnownSymbolsStore = shared("wks");
          var _Symbol = global2.Symbol;
          var symbolFor = _Symbol && _Symbol["for"];
          var createWellKnownSymbol = USE_SYMBOL_AS_UID ? _Symbol : _Symbol && _Symbol.withoutSetter || uid;
          module3.exports = function(name) {
            if (!hasOwn(WellKnownSymbolsStore, name) || !(NATIVE_SYMBOL || typeof WellKnownSymbolsStore[name] == "string")) {
              var description = "Symbol." + name;
              if (NATIVE_SYMBOL && hasOwn(_Symbol, name)) {
                WellKnownSymbolsStore[name] = _Symbol[name];
              } else if (USE_SYMBOL_AS_UID && symbolFor) {
                WellKnownSymbolsStore[name] = symbolFor(description);
              } else {
                WellKnownSymbolsStore[name] = createWellKnownSymbol(description);
              }
            }
            return WellKnownSymbolsStore[name];
          };
        }, { "../internals/global": 28, "../internals/has-own-property": 29, "../internals/native-symbol": 42, "../internals/shared": 63, "../internals/uid": 72, "../internals/use-symbol-as-uid": 73 }], 76: [function(_dereq_, module3, exports3) {
          "use strict";
          var $ = _dereq_("../internals/export");
          var $includes = _dereq_("../internals/array-includes").includes;
          var addToUnscopables = _dereq_("../internals/add-to-unscopables");
          $({ target: "Array", proto: true }, {
            includes: function includes(el) {
              return $includes(this, el, arguments.length > 1 ? arguments[1] : void 0);
            }
          });
          addToUnscopables("includes");
        }, { "../internals/add-to-unscopables": 7, "../internals/array-includes": 9, "../internals/export": 20 }], 77: [function(_dereq_, module3, exports3) {
          "use strict";
          var $ = _dereq_("../internals/export");
          var $values = _dereq_("../internals/object-to-array").values;
          $({ target: "Object", stat: true }, {
            values: function values(O) {
              return $values(O);
            }
          });
        }, { "../internals/export": 20, "../internals/object-to-array": 54 }], 78: [function(_dereq_, module3, exports3) {
          "use strict";
          var parent = _dereq_("../../es/array/includes");
          module3.exports = parent;
        }, { "../../es/array/includes": 4 }], 79: [function(_dereq_, module3, exports3) {
          "use strict";
          var parent = _dereq_("../../es/object/values");
          module3.exports = parent;
        }, { "../../es/object/values": 5 }], 80: [function(_dereq_, module3, exports3) {
          "use strict";
          var _slicedToArray = /* @__PURE__ */ (function() {
            function sliceIterator(arr, i) {
              var _arr = [];
              var _n = true;
              var _d = false;
              var _e = void 0;
              try {
                for (var _i = arr[Symbol.iterator](), _s; !(_n = (_s = _i.next()).done); _n = true) {
                  _arr.push(_s.value);
                  if (i && _arr.length === i) break;
                }
              } catch (err) {
                _d = true;
                _e = err;
              } finally {
                try {
                  if (!_n && _i["return"]) _i["return"]();
                } finally {
                  if (_d) throw _e;
                }
              }
              return _arr;
            }
            return function(arr, i) {
              if (Array.isArray(arr)) {
                return arr;
              } else if (Symbol.iterator in Object(arr)) {
                return sliceIterator(arr, i);
              } else {
                throw new TypeError("Invalid attempt to destructure non-iterable instance");
              }
            };
          })();
          var _createClass = /* @__PURE__ */ (function() {
            function defineProperties(target, props) {
              for (var i = 0; i < props.length; i++) {
                var descriptor = props[i];
                descriptor.enumerable = descriptor.enumerable || false;
                descriptor.configurable = true;
                if ("value" in descriptor) descriptor.writable = true;
                Object.defineProperty(target, descriptor.key, descriptor);
              }
            }
            return function(Constructor, protoProps, staticProps) {
              if (protoProps) defineProperties(Constructor.prototype, protoProps);
              if (staticProps) defineProperties(Constructor, staticProps);
              return Constructor;
            };
          })();
          function _classCallCheck(instance, Constructor) {
            if (!(instance instanceof Constructor)) {
              throw new TypeError("Cannot call a class as a function");
            }
          }
          var legacyErrorCodes = _dereq_("./legacy-error-codes.json");
          var idlUtils = _dereq_("./utils.js");
          exports3.implementation = (function() {
            function DOMExceptionImpl(_ref) {
              var _ref2 = _slicedToArray(_ref, 2), message = _ref2[0], name = _ref2[1];
              _classCallCheck(this, DOMExceptionImpl);
              this.name = name;
              this.message = message;
            }
            _createClass(DOMExceptionImpl, [{
              key: "code",
              get: function get() {
                return legacyErrorCodes[this.name] || 0;
              }
            }]);
            return DOMExceptionImpl;
          })();
          exports3.init = function(impl) {
            if (Error.captureStackTrace) {
              var wrapper = idlUtils.wrapperForImpl(impl);
              Error.captureStackTrace(wrapper, wrapper.constructor);
            }
          };
        }, { "./legacy-error-codes.json": 82, "./utils.js": 84 }], 81: [function(_dereq_, module3, exports3) {
          "use strict";
          var conversions = _dereq_("webidl-conversions");
          var utils = _dereq_("./utils.js");
          var impl = utils.implSymbol;
          function DOMException2() {
            var args = [];
            for (var i = 0; i < arguments.length && i < 2; ++i) {
              args[i] = arguments[i];
            }
            if (args[0] !== void 0) {
              args[0] = conversions["DOMString"](args[0], { context: "Failed to construct 'DOMException': parameter 1" });
            } else {
              args[0] = "";
            }
            if (args[1] !== void 0) {
              args[1] = conversions["DOMString"](args[1], { context: "Failed to construct 'DOMException': parameter 2" });
            } else {
              args[1] = "Error";
            }
            iface.setup(this, args);
          }
          Object.defineProperty(DOMException2, "prototype", {
            value: DOMException2.prototype,
            writable: false,
            enumerable: false,
            configurable: false
          });
          Object.defineProperty(DOMException2.prototype, "name", {
            get: function get() {
              return this[impl]["name"];
            },
            enumerable: true,
            configurable: true
          });
          Object.defineProperty(DOMException2.prototype, "message", {
            get: function get() {
              return this[impl]["message"];
            },
            enumerable: true,
            configurable: true
          });
          Object.defineProperty(DOMException2.prototype, "code", {
            get: function get() {
              return this[impl]["code"];
            },
            enumerable: true,
            configurable: true
          });
          Object.defineProperty(DOMException2, "INDEX_SIZE_ERR", {
            value: 1,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "INDEX_SIZE_ERR", {
            value: 1,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "DOMSTRING_SIZE_ERR", {
            value: 2,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "DOMSTRING_SIZE_ERR", {
            value: 2,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "HIERARCHY_REQUEST_ERR", {
            value: 3,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "HIERARCHY_REQUEST_ERR", {
            value: 3,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "WRONG_DOCUMENT_ERR", {
            value: 4,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "WRONG_DOCUMENT_ERR", {
            value: 4,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "INVALID_CHARACTER_ERR", {
            value: 5,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "INVALID_CHARACTER_ERR", {
            value: 5,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "NO_DATA_ALLOWED_ERR", {
            value: 6,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "NO_DATA_ALLOWED_ERR", {
            value: 6,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "NO_MODIFICATION_ALLOWED_ERR", {
            value: 7,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "NO_MODIFICATION_ALLOWED_ERR", {
            value: 7,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "NOT_FOUND_ERR", {
            value: 8,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "NOT_FOUND_ERR", {
            value: 8,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "NOT_SUPPORTED_ERR", {
            value: 9,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "NOT_SUPPORTED_ERR", {
            value: 9,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "INUSE_ATTRIBUTE_ERR", {
            value: 10,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "INUSE_ATTRIBUTE_ERR", {
            value: 10,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "INVALID_STATE_ERR", {
            value: 11,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "INVALID_STATE_ERR", {
            value: 11,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "SYNTAX_ERR", {
            value: 12,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "SYNTAX_ERR", {
            value: 12,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "INVALID_MODIFICATION_ERR", {
            value: 13,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "INVALID_MODIFICATION_ERR", {
            value: 13,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "NAMESPACE_ERR", {
            value: 14,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "NAMESPACE_ERR", {
            value: 14,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "INVALID_ACCESS_ERR", {
            value: 15,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "INVALID_ACCESS_ERR", {
            value: 15,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "VALIDATION_ERR", {
            value: 16,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "VALIDATION_ERR", {
            value: 16,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "TYPE_MISMATCH_ERR", {
            value: 17,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "TYPE_MISMATCH_ERR", {
            value: 17,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "SECURITY_ERR", {
            value: 18,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "SECURITY_ERR", {
            value: 18,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "NETWORK_ERR", {
            value: 19,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "NETWORK_ERR", {
            value: 19,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "ABORT_ERR", {
            value: 20,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "ABORT_ERR", {
            value: 20,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "URL_MISMATCH_ERR", {
            value: 21,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "URL_MISMATCH_ERR", {
            value: 21,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "QUOTA_EXCEEDED_ERR", {
            value: 22,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "QUOTA_EXCEEDED_ERR", {
            value: 22,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "TIMEOUT_ERR", {
            value: 23,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "TIMEOUT_ERR", {
            value: 23,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "INVALID_NODE_TYPE_ERR", {
            value: 24,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "INVALID_NODE_TYPE_ERR", {
            value: 24,
            enumerable: true
          });
          Object.defineProperty(DOMException2, "DATA_CLONE_ERR", {
            value: 25,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, "DATA_CLONE_ERR", {
            value: 25,
            enumerable: true
          });
          Object.defineProperty(DOMException2.prototype, Symbol.toStringTag, {
            value: "DOMException",
            writable: false,
            enumerable: false,
            configurable: true
          });
          var iface = {
            mixedInto: [],
            is: function is(obj) {
              if (obj) {
                if (obj[impl] instanceof Impl.implementation) {
                  return true;
                }
                for (var i = 0; i < module3.exports.mixedInto.length; ++i) {
                  if (obj instanceof module3.exports.mixedInto[i]) {
                    return true;
                  }
                }
              }
              return false;
            },
            isImpl: function isImpl(obj) {
              if (obj) {
                if (obj instanceof Impl.implementation) {
                  return true;
                }
                var wrapper = utils.wrapperForImpl(obj);
                for (var i = 0; i < module3.exports.mixedInto.length; ++i) {
                  if (wrapper instanceof module3.exports.mixedInto[i]) {
                    return true;
                  }
                }
              }
              return false;
            },
            convert: function convert(obj) {
              var _ref = arguments.length > 1 && arguments[1] !== void 0 ? arguments[1] : {}, _ref$context = _ref.context, context = _ref$context === void 0 ? "The provided value" : _ref$context;
              if (module3.exports.is(obj)) {
                return utils.implForWrapper(obj);
              }
              throw new TypeError(context + " is not of type 'DOMException'.");
            },
            create: function create(constructorArgs, privateData) {
              var obj = Object.create(DOMException2.prototype);
              this.setup(obj, constructorArgs, privateData);
              return obj;
            },
            createImpl: function createImpl(constructorArgs, privateData) {
              var obj = Object.create(DOMException2.prototype);
              this.setup(obj, constructorArgs, privateData);
              return utils.implForWrapper(obj);
            },
            _internalSetup: function _internalSetup(obj) {
            },
            setup: function setup(obj, constructorArgs, privateData) {
              if (!privateData) privateData = {};
              privateData.wrapper = obj;
              this._internalSetup(obj);
              Object.defineProperty(obj, impl, {
                value: new Impl.implementation(constructorArgs, privateData),
                writable: false,
                enumerable: false,
                configurable: true
              });
              obj[impl][utils.wrapperSymbol] = obj;
              if (Impl.init) {
                Impl.init(obj[impl], privateData);
              }
            },
            interface: DOMException2,
            expose: {
              Window: { DOMException: DOMException2 },
              Worker: { DOMException: DOMException2 }
            }
          };
          module3.exports = iface;
          var Impl = _dereq_(".//DOMException-impl.js");
        }, { ".//DOMException-impl.js": 80, "./utils.js": 84, "webidl-conversions": 87 }], 82: [function(_dereq_, module3, exports3) {
          module3.exports = {
            "IndexSizeError": 1,
            "DOMStringSizeError": 2,
            "HierarchyRequestError": 3,
            "WrongDocumentError": 4,
            "InvalidCharacterError": 5,
            "NoDataAllowedError": 6,
            "NoModificationAllowedError": 7,
            "NotFoundError": 8,
            "NotSupportedError": 9,
            "InUseAttributeError": 10,
            "InvalidStateError": 11,
            "SyntaxError": 12,
            "InvalidModificationError": 13,
            "NamespaceError": 14,
            "InvalidAccessError": 15,
            "ValidationError": 16,
            "TypeMismatchError": 17,
            "SecurityError": 18,
            "NetworkError": 19,
            "AbortError": 20,
            "URLMismatchError": 21,
            "QuotaExceededError": 22,
            "TimeoutError": 23,
            "InvalidNodeTypeError": 24,
            "DataCloneError": 25
          };
        }, {}], 83: [function(_dereq_, module3, exports3) {
          "use strict";
          module3.exports = _dereq_("./DOMException").interface;
          Object.setPrototypeOf(module3.exports.prototype, Error.prototype);
        }, { "./DOMException": 81 }], 84: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          function isObject(value) {
            return (typeof value === "undefined" ? "undefined" : _typeof(value)) === "object" && value !== null || typeof value === "function";
          }
          function getReferenceToBytes(bufferSource) {
            if (Object.getPrototypeOf(bufferSource) === Buffer.prototype) {
              return bufferSource;
            }
            if (bufferSource instanceof ArrayBuffer) {
              return Buffer.from(bufferSource);
            }
            return Buffer.from(bufferSource.buffer, bufferSource.byteOffset, bufferSource.byteLength);
          }
          function getCopyToBytes(bufferSource) {
            return Buffer.from(getReferenceToBytes(bufferSource));
          }
          function mixin(target, source) {
            var keys = Object.getOwnPropertyNames(source);
            for (var i = 0; i < keys.length; ++i) {
              if (keys[i] in target) {
                continue;
              }
              Object.defineProperty(target, keys[i], Object.getOwnPropertyDescriptor(source, keys[i]));
            }
          }
          var wrapperSymbol = /* @__PURE__ */ Symbol("wrapper");
          var implSymbol = /* @__PURE__ */ Symbol("impl");
          var sameObjectCaches = /* @__PURE__ */ Symbol("SameObject caches");
          function getSameObject(wrapper, prop, creator) {
            if (!wrapper[sameObjectCaches]) {
              wrapper[sameObjectCaches] = /* @__PURE__ */ Object.create(null);
            }
            if (prop in wrapper[sameObjectCaches]) {
              return wrapper[sameObjectCaches][prop];
            }
            wrapper[sameObjectCaches][prop] = creator();
            return wrapper[sameObjectCaches][prop];
          }
          function wrapperForImpl(impl) {
            return impl ? impl[wrapperSymbol] : null;
          }
          function implForWrapper(wrapper) {
            return wrapper ? wrapper[implSymbol] : null;
          }
          function tryWrapperForImpl(impl) {
            var wrapper = wrapperForImpl(impl);
            return wrapper ? wrapper : impl;
          }
          function tryImplForWrapper(wrapper) {
            var impl = implForWrapper(wrapper);
            return impl ? impl : wrapper;
          }
          var iterInternalSymbol = /* @__PURE__ */ Symbol("internal");
          var IteratorPrototype = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));
          module3.exports = exports3 = {
            isObject,
            getReferenceToBytes,
            getCopyToBytes,
            mixin,
            wrapperSymbol,
            implSymbol,
            getSameObject,
            wrapperForImpl,
            implForWrapper,
            tryWrapperForImpl,
            tryImplForWrapper,
            iterInternalSymbol,
            IteratorPrototype
          };
        }, {}], 85: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof2 = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          !(function(e, t) {
            "object" == (typeof exports3 === "undefined" ? "undefined" : _typeof2(exports3)) && "undefined" != typeof module3 ? module3.exports = t() : "function" == typeof define2 && define2.amd ? define2(t) : ((e = "undefined" != typeof globalThis ? globalThis : e || self).Typeson = e.Typeson || {}, e.Typeson.presets = e.Typeson.presets || {}, e.Typeson.presets.structuredCloningThrowing = t());
          })(void 0, function() {
            "use strict";
            function _typeof$1(e2) {
              return (_typeof$1 = "function" == typeof Symbol && "symbol" == _typeof2(Symbol.iterator) ? function(e3) {
                return typeof e3 === "undefined" ? "undefined" : _typeof2(e3);
              } : function(e3) {
                return e3 && "function" == typeof Symbol && e3.constructor === Symbol && e3 !== Symbol.prototype ? "symbol" : typeof e3 === "undefined" ? "undefined" : _typeof2(e3);
              })(e2);
            }
            function _classCallCheck$1(e2, t2) {
              if (!(e2 instanceof t2)) throw new TypeError("Cannot call a class as a function");
            }
            function _defineProperties$1(e2, t2) {
              for (var r2 = 0; r2 < t2.length; r2++) {
                var n2 = t2[r2];
                n2.enumerable = n2.enumerable || false, n2.configurable = true, "value" in n2 && (n2.writable = true), Object.defineProperty(e2, n2.key, n2);
              }
            }
            function _defineProperty$1(e2, t2, r2) {
              return t2 in e2 ? Object.defineProperty(e2, t2, { value: r2, enumerable: true, configurable: true, writable: true }) : e2[t2] = r2, e2;
            }
            function ownKeys$1(e2, t2) {
              var r2 = Object.keys(e2);
              if (Object.getOwnPropertySymbols) {
                var n2 = Object.getOwnPropertySymbols(e2);
                t2 && (n2 = n2.filter(function(t3) {
                  return Object.getOwnPropertyDescriptor(e2, t3).enumerable;
                })), r2.push.apply(r2, n2);
              }
              return r2;
            }
            function _toConsumableArray$1(e2) {
              return (function _arrayWithoutHoles$1(e3) {
                if (Array.isArray(e3)) return _arrayLikeToArray$1(e3);
              })(e2) || (function _iterableToArray$1(e3) {
                if ("undefined" != typeof Symbol && Symbol.iterator in Object(e3)) return Array.from(e3);
              })(e2) || (function _unsupportedIterableToArray$1(e3, t2) {
                if (!e3) return;
                if ("string" == typeof e3) return _arrayLikeToArray$1(e3, t2);
                var r2 = Object.prototype.toString.call(e3).slice(8, -1);
                "Object" === r2 && e3.constructor && (r2 = e3.constructor.name);
                if ("Map" === r2 || "Set" === r2) return Array.from(e3);
                if ("Arguments" === r2 || /^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(r2)) return _arrayLikeToArray$1(e3, t2);
              })(e2) || (function _nonIterableSpread$1() {
                throw new TypeError("Invalid attempt to spread non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
              })();
            }
            function _arrayLikeToArray$1(e2, t2) {
              (null == t2 || t2 > e2.length) && (t2 = e2.length);
              for (var r2 = 0, n2 = new Array(t2); r2 < t2; r2++) {
                n2[r2] = e2[r2];
              }
              return n2;
            }
            function _typeof(e2) {
              return (_typeof = "function" == typeof Symbol && "symbol" == _typeof2(Symbol.iterator) ? function _typeof3(e3) {
                return typeof e3 === "undefined" ? "undefined" : _typeof2(e3);
              } : function _typeof3(e3) {
                return e3 && "function" == typeof Symbol && e3.constructor === Symbol && e3 !== Symbol.prototype ? "symbol" : typeof e3 === "undefined" ? "undefined" : _typeof2(e3);
              })(e2);
            }
            function _classCallCheck(e2, t2) {
              if (!(e2 instanceof t2)) throw new TypeError("Cannot call a class as a function");
            }
            function _defineProperties(e2, t2) {
              for (var r2 = 0; r2 < t2.length; r2++) {
                var n2 = t2[r2];
                n2.enumerable = n2.enumerable || false, n2.configurable = true, "value" in n2 && (n2.writable = true), Object.defineProperty(e2, n2.key, n2);
              }
            }
            function _defineProperty(e2, t2, r2) {
              return t2 in e2 ? Object.defineProperty(e2, t2, { value: r2, enumerable: true, configurable: true, writable: true }) : e2[t2] = r2, e2;
            }
            function ownKeys(e2, t2) {
              var r2 = Object.keys(e2);
              if (Object.getOwnPropertySymbols) {
                var n2 = Object.getOwnPropertySymbols(e2);
                t2 && (n2 = n2.filter(function(t3) {
                  return Object.getOwnPropertyDescriptor(e2, t3).enumerable;
                })), r2.push.apply(r2, n2);
              }
              return r2;
            }
            function _objectSpread2(e2) {
              for (var t2 = 1; t2 < arguments.length; t2++) {
                var r2 = null != arguments[t2] ? arguments[t2] : {};
                t2 % 2 ? ownKeys(Object(r2), true).forEach(function(t3) {
                  _defineProperty(e2, t3, r2[t3]);
                }) : Object.getOwnPropertyDescriptors ? Object.defineProperties(e2, Object.getOwnPropertyDescriptors(r2)) : ownKeys(Object(r2)).forEach(function(t3) {
                  Object.defineProperty(e2, t3, Object.getOwnPropertyDescriptor(r2, t3));
                });
              }
              return e2;
            }
            function _slicedToArray(e2, t2) {
              return (function _arrayWithHoles(e3) {
                if (Array.isArray(e3)) return e3;
              })(e2) || (function _iterableToArrayLimit(e3, t3) {
                if ("undefined" == typeof Symbol || !(Symbol.iterator in Object(e3))) return;
                var r2 = [], n2 = true, i2 = false, o2 = void 0;
                try {
                  for (var a2, c2 = e3[Symbol.iterator](); !(n2 = (a2 = c2.next()).done) && (r2.push(a2.value), !t3 || r2.length !== t3); n2 = true) {
                  }
                } catch (e4) {
                  i2 = true, o2 = e4;
                } finally {
                  try {
                    n2 || null == c2.return || c2.return();
                  } finally {
                    if (i2) throw o2;
                  }
                }
                return r2;
              })(e2, t2) || _unsupportedIterableToArray(e2, t2) || (function _nonIterableRest() {
                throw new TypeError("Invalid attempt to destructure non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
              })();
            }
            function _toConsumableArray(e2) {
              return (function _arrayWithoutHoles(e3) {
                if (Array.isArray(e3)) return _arrayLikeToArray(e3);
              })(e2) || (function _iterableToArray(e3) {
                if ("undefined" != typeof Symbol && Symbol.iterator in Object(e3)) return Array.from(e3);
              })(e2) || _unsupportedIterableToArray(e2) || (function _nonIterableSpread() {
                throw new TypeError("Invalid attempt to spread non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
              })();
            }
            function _unsupportedIterableToArray(e2, t2) {
              if (e2) {
                if ("string" == typeof e2) return _arrayLikeToArray(e2, t2);
                var r2 = Object.prototype.toString.call(e2).slice(8, -1);
                return "Object" === r2 && e2.constructor && (r2 = e2.constructor.name), "Map" === r2 || "Set" === r2 ? Array.from(e2) : "Arguments" === r2 || /^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(r2) ? _arrayLikeToArray(e2, t2) : void 0;
              }
            }
            function _arrayLikeToArray(e2, t2) {
              (null == t2 || t2 > e2.length) && (t2 = e2.length);
              for (var r2 = 0, n2 = new Array(t2); r2 < t2; r2++) {
                n2[r2] = e2[r2];
              }
              return n2;
            }
            var e = function TypesonPromise(e2) {
              _classCallCheck(this, TypesonPromise), this.p = new Promise(e2);
            };
            e.__typeson__type__ = "TypesonPromise", "undefined" != typeof Symbol && (e.prototype[Symbol.toStringTag] = "TypesonPromise"), e.prototype.then = function(t2, r2) {
              var n2 = this;
              return new e(function(e2, i2) {
                n2.p.then(function(r3) {
                  e2(t2 ? t2(r3) : r3);
                }).catch(function(e3) {
                  return r2 ? r2(e3) : Promise.reject(e3);
                }).then(e2, i2);
              });
            }, e.prototype.catch = function(e2) {
              return this.then(null, e2);
            }, e.resolve = function(t2) {
              return new e(function(e2) {
                e2(t2);
              });
            }, e.reject = function(t2) {
              return new e(function(e2, r2) {
                r2(t2);
              });
            }, ["all", "race"].forEach(function(t2) {
              e[t2] = function(r2) {
                return new e(function(e2, n2) {
                  Promise[t2](r2.map(function(e3) {
                    return e3 && e3.constructor && "TypesonPromise" === e3.constructor.__typeson__type__ ? e3.p : e3;
                  })).then(e2, n2);
                });
              };
            });
            var t = {}.toString, r = {}.hasOwnProperty, n = Object.getPrototypeOf, i = r.toString;
            function isThenable(e2, t2) {
              return isObject(e2) && "function" == typeof e2.then && (!t2 || "function" == typeof e2.catch);
            }
            function toStringTag(e2) {
              return t.call(e2).slice(8, -1);
            }
            function hasConstructorOf(e2, t2) {
              if (!e2 || "object" !== _typeof(e2)) return false;
              var o2 = n(e2);
              if (!o2) return null === t2;
              var a2 = r.call(o2, "constructor") && o2.constructor;
              return "function" != typeof a2 ? null === t2 : t2 === a2 || null !== t2 && i.call(a2) === i.call(t2) || "function" == typeof t2 && "string" == typeof a2.__typeson__type__ && a2.__typeson__type__ === t2.__typeson__type__;
            }
            function isPlainObject(e2) {
              return !(!e2 || "Object" !== toStringTag(e2)) && (!n(e2) || hasConstructorOf(e2, Object));
            }
            function isObject(e2) {
              return e2 && "object" === _typeof(e2);
            }
            function escapeKeyPathComponent(e2) {
              return e2.replace(/~/g, "~0").replace(/\./g, "~1");
            }
            function unescapeKeyPathComponent(e2) {
              return e2.replace(/~1/g, ".").replace(/~0/g, "~");
            }
            function getByKeyPath(e2, t2) {
              if ("" === t2) return e2;
              var r2 = t2.indexOf(".");
              if (r2 > -1) {
                var n2 = e2[unescapeKeyPathComponent(t2.slice(0, r2))];
                return void 0 === n2 ? void 0 : getByKeyPath(n2, t2.slice(r2 + 1));
              }
              return e2[unescapeKeyPathComponent(t2)];
            }
            function setAtKeyPath(e2, t2, r2) {
              if ("" === t2) return r2;
              var n2 = t2.indexOf(".");
              return n2 > -1 ? setAtKeyPath(e2[unescapeKeyPathComponent(t2.slice(0, n2))], t2.slice(n2 + 1), r2) : (e2[unescapeKeyPathComponent(t2)] = r2, e2);
            }
            function _await(e2, t2, r2) {
              return r2 ? t2 ? t2(e2) : e2 : (e2 && e2.then || (e2 = Promise.resolve(e2)), t2 ? e2.then(t2) : e2);
            }
            var o = Object.keys, a = Array.isArray, c = {}.hasOwnProperty, u = ["type", "replaced", "iterateIn", "iterateUnsetNumeric"];
            function _async(e2) {
              return function() {
                for (var t2 = [], r2 = 0; r2 < arguments.length; r2++) {
                  t2[r2] = arguments[r2];
                }
                try {
                  return Promise.resolve(e2.apply(this, t2));
                } catch (e3) {
                  return Promise.reject(e3);
                }
              };
            }
            function nestedPathsFirst(e2, t2) {
              if ("" === e2.keypath) return -1;
              var r2 = e2.keypath.match(/\./g) || 0, n2 = t2.keypath.match(/\./g) || 0;
              return r2 && (r2 = r2.length), n2 && (n2 = n2.length), r2 > n2 ? -1 : r2 < n2 ? 1 : e2.keypath < t2.keypath ? -1 : e2.keypath > t2.keypath;
            }
            var s = (function() {
              function Typeson(e2) {
                _classCallCheck(this, Typeson), this.options = e2, this.plainObjectReplacers = [], this.nonplainObjectReplacers = [], this.revivers = {}, this.types = {};
              }
              return (function _createClass(e2, t2, r2) {
                return t2 && _defineProperties(e2.prototype, t2), r2 && _defineProperties(e2, r2), e2;
              })(Typeson, [{ key: "stringify", value: function stringify(e2, t2, r2, n2) {
                n2 = _objectSpread2(_objectSpread2(_objectSpread2({}, this.options), n2), {}, { stringification: true });
                var i2 = this.encapsulate(e2, null, n2);
                return a(i2) ? JSON.stringify(i2[0], t2, r2) : i2.then(function(e3) {
                  return JSON.stringify(e3, t2, r2);
                });
              } }, { key: "stringifySync", value: function stringifySync(e2, t2, r2, n2) {
                return this.stringify(e2, t2, r2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, n2), {}, { sync: true }));
              } }, { key: "stringifyAsync", value: function stringifyAsync(e2, t2, r2, n2) {
                return this.stringify(e2, t2, r2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, n2), {}, { sync: false }));
              } }, { key: "parse", value: function parse(e2, t2, r2) {
                return r2 = _objectSpread2(_objectSpread2(_objectSpread2({}, this.options), r2), {}, { parse: true }), this.revive(JSON.parse(e2, t2), r2);
              } }, { key: "parseSync", value: function parseSync(e2, t2, r2) {
                return this.parse(e2, t2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, r2), {}, { sync: true }));
              } }, { key: "parseAsync", value: function parseAsync(e2, t2, r2) {
                return this.parse(e2, t2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, r2), {}, { sync: false }));
              } }, { key: "specialTypeNames", value: function specialTypeNames(e2, t2) {
                var r2 = arguments.length > 2 && void 0 !== arguments[2] ? arguments[2] : {};
                return r2.returnTypeNames = true, this.encapsulate(e2, t2, r2);
              } }, { key: "rootTypeName", value: function rootTypeName(e2, t2) {
                var r2 = arguments.length > 2 && void 0 !== arguments[2] ? arguments[2] : {};
                return r2.iterateNone = true, this.encapsulate(e2, t2, r2);
              } }, { key: "encapsulate", value: function encapsulate(t2, r2, n2) {
                var i2 = _async(function(t3, r3) {
                  return _await(Promise.all(r3.map(function(e2) {
                    return e2[1].p;
                  })), function(n3) {
                    return _await(Promise.all(n3.map(_async(function(n4) {
                      var o2 = false, a2 = [], c2 = _slicedToArray(r3.splice(0, 1), 1), u2 = _slicedToArray(c2[0], 7), s3 = u2[0], f3 = u2[2], l3 = u2[3], p3 = u2[4], y3 = u2[5], v3 = u2[6], b3 = _encapsulate(s3, n4, f3, l3, a2, true, v3), d3 = hasConstructorOf(b3, e);
                      return (function _invoke(e2, t4) {
                        var r4 = e2();
                        return r4 && r4.then ? r4.then(t4) : t4(r4);
                      })(function() {
                        if (s3 && d3) return _await(b3.p, function(e2) {
                          return p3[y3] = e2, o2 = true, i2(t3, a2);
                        });
                      }, function(e2) {
                        return o2 ? e2 : (s3 ? p3[y3] = b3 : t3 = d3 ? b3.p : b3, i2(t3, a2));
                      });
                    }))), function() {
                      return t3;
                    });
                  });
                }), s2 = (n2 = _objectSpread2(_objectSpread2({ sync: true }, this.options), n2)).sync, f2 = this, l2 = {}, p2 = [], y2 = [], v2 = [], b2 = !("cyclic" in n2) || n2.cyclic, d2 = n2.encapsulateObserver, h2 = _encapsulate("", t2, b2, r2 || {}, v2);
                function finish(e2) {
                  var t3 = Object.values(l2);
                  if (n2.iterateNone) return t3.length ? t3[0] : Typeson.getJSONType(e2);
                  if (t3.length) {
                    if (n2.returnTypeNames) return _toConsumableArray(new Set(t3));
                    e2 && isPlainObject(e2) && !c.call(e2, "$types") ? e2.$types = l2 : e2 = { $: e2, $types: { $: l2 } };
                  } else isObject(e2) && c.call(e2, "$types") && (e2 = { $: e2, $types: true });
                  return !n2.returnTypeNames && e2;
                }
                function _adaptBuiltinStateObjectProperties(e2, t3, r3) {
                  Object.assign(e2, t3);
                  var n3 = u.map(function(t4) {
                    var r4 = e2[t4];
                    return delete e2[t4], r4;
                  });
                  r3(), u.forEach(function(t4, r4) {
                    e2[t4] = n3[r4];
                  });
                }
                function _encapsulate(t3, r3, i3, u2, s3, v3, b3) {
                  var h3, g3 = {}, m2 = _typeof(r3), O2 = d2 ? function(n3) {
                    var o2 = b3 || u2.type || Typeson.getJSONType(r3);
                    d2(Object.assign(n3 || g3, { keypath: t3, value: r3, cyclic: i3, stateObj: u2, promisesData: s3, resolvingTypesonPromise: v3, awaitingTypesonPromise: hasConstructorOf(r3, e) }, { type: o2 }));
                  } : null;
                  if (["string", "boolean", "number", "undefined"].includes(m2)) return void 0 === r3 || Number.isNaN(r3) || r3 === Number.NEGATIVE_INFINITY || r3 === Number.POSITIVE_INFINITY ? (h3 = u2.replaced ? r3 : replace(t3, r3, u2, s3, false, v3, O2)) !== r3 && (g3 = { replaced: h3 }) : h3 = r3, O2 && O2(), h3;
                  if (null === r3) return O2 && O2(), r3;
                  if (i3 && !u2.iterateIn && !u2.iterateUnsetNumeric && r3 && "object" === _typeof(r3)) {
                    var _2 = p2.indexOf(r3);
                    if (!(_2 < 0)) return l2[t3] = "#", O2 && O2({ cyclicKeypath: y2[_2] }), "#" + y2[_2];
                    true === i3 && (p2.push(r3), y2.push(t3));
                  }
                  var j2, S2 = isPlainObject(r3), T2 = a(r3), w2 = (S2 || T2) && (!f2.plainObjectReplacers.length || u2.replaced) || u2.iterateIn ? r3 : replace(t3, r3, u2, s3, S2 || T2, null, O2);
                  if (w2 !== r3 ? (h3 = w2, g3 = { replaced: w2 }) : "" === t3 && hasConstructorOf(r3, e) ? (s3.push([t3, r3, i3, u2, void 0, void 0, u2.type]), h3 = r3) : T2 && "object" !== u2.iterateIn || "array" === u2.iterateIn ? (j2 = new Array(r3.length), g3 = { clone: j2 }) : (["function", "symbol"].includes(_typeof(r3)) || "toJSON" in r3 || hasConstructorOf(r3, e) || hasConstructorOf(r3, Promise) || hasConstructorOf(r3, ArrayBuffer)) && !S2 && "object" !== u2.iterateIn ? h3 = r3 : (j2 = {}, u2.addLength && (j2.length = r3.length), g3 = { clone: j2 }), O2 && O2(), n2.iterateNone) return j2 || h3;
                  if (!j2) return h3;
                  if (u2.iterateIn) {
                    var A2 = function _loop(n3) {
                      var o2 = { ownKeys: c.call(r3, n3) };
                      _adaptBuiltinStateObjectProperties(u2, o2, function() {
                        var o3 = t3 + (t3 ? "." : "") + escapeKeyPathComponent(n3), a2 = _encapsulate(o3, r3[n3], Boolean(i3), u2, s3, v3);
                        hasConstructorOf(a2, e) ? s3.push([o3, a2, Boolean(i3), u2, j2, n3, u2.type]) : void 0 !== a2 && (j2[n3] = a2);
                      });
                    };
                    for (var P2 in r3) {
                      A2(P2);
                    }
                    O2 && O2({ endIterateIn: true, end: true });
                  } else o(r3).forEach(function(n3) {
                    var o2 = t3 + (t3 ? "." : "") + escapeKeyPathComponent(n3);
                    _adaptBuiltinStateObjectProperties(u2, { ownKeys: true }, function() {
                      var t4 = _encapsulate(o2, r3[n3], Boolean(i3), u2, s3, v3);
                      hasConstructorOf(t4, e) ? s3.push([o2, t4, Boolean(i3), u2, j2, n3, u2.type]) : void 0 !== t4 && (j2[n3] = t4);
                    });
                  }), O2 && O2({ endIterateOwn: true, end: true });
                  if (u2.iterateUnsetNumeric) {
                    for (var C2 = r3.length, I2 = function _loop2(n3) {
                      if (!(n3 in r3)) {
                        var o2 = t3 + (t3 ? "." : "") + n3;
                        _adaptBuiltinStateObjectProperties(u2, { ownKeys: false }, function() {
                          var t4 = _encapsulate(o2, void 0, Boolean(i3), u2, s3, v3);
                          hasConstructorOf(t4, e) ? s3.push([o2, t4, Boolean(i3), u2, j2, n3, u2.type]) : void 0 !== t4 && (j2[n3] = t4);
                        });
                      }
                    }, N2 = 0; N2 < C2; N2++) {
                      I2(N2);
                    }
                    O2 && O2({ endIterateUnsetNumeric: true, end: true });
                  }
                  return j2;
                }
                function replace(e2, t3, r3, n3, i3, o2, a2) {
                  for (var c2 = i3 ? f2.plainObjectReplacers : f2.nonplainObjectReplacers, u2 = c2.length; u2--; ) {
                    var p3 = c2[u2];
                    if (p3.test(t3, r3)) {
                      var y3 = p3.type;
                      if (f2.revivers[y3]) {
                        var v3 = l2[e2];
                        l2[e2] = v3 ? [y3].concat(v3) : y3;
                      }
                      return Object.assign(r3, { type: y3, replaced: true }), !s2 && p3.replaceAsync || p3.replace ? (a2 && a2({ replacing: true }), _encapsulate(e2, p3[s2 || !p3.replaceAsync ? "replace" : "replaceAsync"](t3, r3), b2 && "readonly", r3, n3, o2, y3)) : (a2 && a2({ typeDetected: true }), _encapsulate(e2, t3, b2 && "readonly", r3, n3, o2, y3));
                    }
                  }
                  return t3;
                }
                return v2.length ? s2 && n2.throwOnBadSyncType ? (function() {
                  throw new TypeError("Sync method requested but async result obtained");
                })() : Promise.resolve(i2(h2, v2)).then(finish) : !s2 && n2.throwOnBadSyncType ? (function() {
                  throw new TypeError("Async method requested but sync result obtained");
                })() : n2.stringification && s2 ? [finish(h2)] : s2 ? finish(h2) : Promise.resolve(finish(h2));
              } }, { key: "encapsulateSync", value: function encapsulateSync(e2, t2, r2) {
                return this.encapsulate(e2, t2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, r2), {}, { sync: true }));
              } }, { key: "encapsulateAsync", value: function encapsulateAsync(e2, t2, r2) {
                return this.encapsulate(e2, t2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, r2), {}, { sync: false }));
              } }, { key: "revive", value: function revive(t2, r2) {
                var n2 = t2 && t2.$types;
                if (!n2) return t2;
                if (true === n2) return t2.$;
                var i2 = (r2 = _objectSpread2(_objectSpread2({ sync: true }, this.options), r2)).sync, c2 = [], u2 = {}, s2 = true;
                n2.$ && isPlainObject(n2.$) && (t2 = t2.$, n2 = n2.$, s2 = false);
                var l2 = this;
                function executeReviver(e2, t3) {
                  var r3 = _slicedToArray(l2.revivers[e2] || [], 1)[0];
                  if (!r3) throw new Error("Unregistered type: " + e2);
                  return i2 && !("revive" in r3) ? t3 : r3[i2 && r3.revive ? "revive" : !i2 && r3.reviveAsync ? "reviveAsync" : "revive"](t3, u2);
                }
                var p2 = [];
                function checkUndefined(e2) {
                  return hasConstructorOf(e2, f) ? void 0 : e2;
                }
                var y2, v2 = (function revivePlainObjects() {
                  var r3 = [];
                  if (Object.entries(n2).forEach(function(e2) {
                    var t3 = _slicedToArray(e2, 2), i3 = t3[0], o2 = t3[1];
                    "#" !== o2 && [].concat(o2).forEach(function(e3) {
                      _slicedToArray(l2.revivers[e3] || [null, {}], 2)[1].plain && (r3.push({ keypath: i3, type: e3 }), delete n2[i3]);
                    });
                  }), r3.length) return r3.sort(nestedPathsFirst).reduce(function reducer(r4, n3) {
                    var i3 = n3.keypath, o2 = n3.type;
                    if (isThenable(r4)) return r4.then(function(e2) {
                      return reducer(e2, { keypath: i3, type: o2 });
                    });
                    var a2 = getByKeyPath(t2, i3);
                    if (hasConstructorOf(a2 = executeReviver(o2, a2), e)) return a2.then(function(e2) {
                      var r5 = setAtKeyPath(t2, i3, e2);
                      r5 === e2 && (t2 = r5);
                    });
                    var c3 = setAtKeyPath(t2, i3, a2);
                    c3 === a2 && (t2 = c3);
                  }, void 0);
                })();
                return hasConstructorOf(v2, e) ? y2 = v2.then(function() {
                  return t2;
                }) : (y2 = (function _revive(t3, r3, i3, u3, l3) {
                  if (!s2 || "$types" !== t3) {
                    var y3 = n2[t3], v3 = a(r3);
                    if (v3 || isPlainObject(r3)) {
                      var b2 = v3 ? new Array(r3.length) : {};
                      for (o(r3).forEach(function(n3) {
                        var o2 = _revive(t3 + (t3 ? "." : "") + escapeKeyPathComponent(n3), r3[n3], i3 || b2, b2, n3), a2 = function set(e2) {
                          return hasConstructorOf(e2, f) ? b2[n3] = void 0 : void 0 !== e2 && (b2[n3] = e2), e2;
                        };
                        hasConstructorOf(o2, e) ? p2.push(o2.then(function(e2) {
                          return a2(e2);
                        })) : a2(o2);
                      }), r3 = b2; c2.length; ) {
                        var d2 = _slicedToArray(c2[0], 4), h2 = d2[0], g3 = d2[1], m2 = d2[2], O2 = d2[3], _2 = getByKeyPath(h2, g3);
                        if (void 0 === _2) break;
                        m2[O2] = _2, c2.splice(0, 1);
                      }
                    }
                    if (!y3) return r3;
                    if ("#" === y3) {
                      var j2 = getByKeyPath(i3, r3.slice(1));
                      return void 0 === j2 && c2.push([i3, r3.slice(1), u3, l3]), j2;
                    }
                    return [].concat(y3).reduce(function reducer(t4, r4) {
                      return hasConstructorOf(t4, e) ? t4.then(function(e2) {
                        return reducer(e2, r4);
                      }) : executeReviver(r4, t4);
                    }, r3);
                  }
                })("", t2, null), p2.length && (y2 = e.resolve(y2).then(function(t3) {
                  return e.all([t3].concat(p2));
                }).then(function(e2) {
                  return _slicedToArray(e2, 1)[0];
                }))), isThenable(y2) ? i2 && r2.throwOnBadSyncType ? (function() {
                  throw new TypeError("Sync method requested but async result obtained");
                })() : hasConstructorOf(y2, e) ? y2.p.then(checkUndefined) : y2 : !i2 && r2.throwOnBadSyncType ? (function() {
                  throw new TypeError("Async method requested but sync result obtained");
                })() : i2 ? checkUndefined(y2) : Promise.resolve(checkUndefined(y2));
              } }, { key: "reviveSync", value: function reviveSync(e2, t2) {
                return this.revive(e2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, t2), {}, { sync: true }));
              } }, { key: "reviveAsync", value: function reviveAsync(e2, t2) {
                return this.revive(e2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, t2), {}, { sync: false }));
              } }, { key: "register", value: function register(e2, t2) {
                return t2 = t2 || {}, [].concat(e2).forEach(function R(e3) {
                  var r2 = this;
                  if (a(e3)) return e3.map(function(e4) {
                    return R.call(r2, e4);
                  });
                  e3 && o(e3).forEach(function(r3) {
                    if ("#" === r3) throw new TypeError("# cannot be used as a type name as it is reserved for cyclic objects");
                    if (Typeson.JSON_TYPES.includes(r3)) throw new TypeError("Plain JSON object types are reserved as type names");
                    var n2 = e3[r3], i2 = n2 && n2.testPlainObjects ? this.plainObjectReplacers : this.nonplainObjectReplacers, o2 = i2.filter(function(e4) {
                      return e4.type === r3;
                    });
                    if (o2.length && (i2.splice(i2.indexOf(o2[0]), 1), delete this.revivers[r3], delete this.types[r3]), "function" == typeof n2) {
                      var c2 = n2;
                      n2 = { test: function test(e4) {
                        return e4 && e4.constructor === c2;
                      }, replace: function replace(e4) {
                        return _objectSpread2({}, e4);
                      }, revive: function revive(e4) {
                        return Object.assign(Object.create(c2.prototype), e4);
                      } };
                    } else if (a(n2)) {
                      var u2 = _slicedToArray(n2, 3);
                      n2 = { test: u2[0], replace: u2[1], revive: u2[2] };
                    }
                    if (n2 && n2.test) {
                      var s2 = { type: r3, test: n2.test.bind(n2) };
                      n2.replace && (s2.replace = n2.replace.bind(n2)), n2.replaceAsync && (s2.replaceAsync = n2.replaceAsync.bind(n2));
                      var f2 = "number" == typeof t2.fallback ? t2.fallback : t2.fallback ? 0 : Number.POSITIVE_INFINITY;
                      if (n2.testPlainObjects ? this.plainObjectReplacers.splice(f2, 0, s2) : this.nonplainObjectReplacers.splice(f2, 0, s2), n2.revive || n2.reviveAsync) {
                        var l2 = {};
                        n2.revive && (l2.revive = n2.revive.bind(n2)), n2.reviveAsync && (l2.reviveAsync = n2.reviveAsync.bind(n2)), this.revivers[r3] = [l2, { plain: n2.testPlainObjects }];
                      }
                      this.types[r3] = n2;
                    }
                  }, this);
                }, this), this;
              } }]), Typeson;
            })(), f = function Undefined() {
              _classCallCheck(this, Undefined);
            };
            f.__typeson__type__ = "TypesonUndefined", s.Undefined = f, s.Promise = e, s.isThenable = isThenable, s.toStringTag = toStringTag, s.hasConstructorOf = hasConstructorOf, s.isObject = isObject, s.isPlainObject = isPlainObject, s.isUserObject = function isUserObject(e2) {
              if (!e2 || "Object" !== toStringTag(e2)) return false;
              var t2 = n(e2);
              return !t2 || hasConstructorOf(e2, Object) || isUserObject(t2);
            }, s.escapeKeyPathComponent = escapeKeyPathComponent, s.unescapeKeyPathComponent = unescapeKeyPathComponent, s.getByKeyPath = getByKeyPath, s.getJSONType = function getJSONType(e2) {
              return null === e2 ? "null" : Array.isArray(e2) ? "array" : _typeof(e2);
            }, s.JSON_TYPES = ["null", "boolean", "number", "string", "array", "object"];
            for (var l = { userObject: { test: function test(e2, t2) {
              return s.isUserObject(e2);
            }, replace: function replace(e2) {
              return (function _objectSpread2$1(e3) {
                for (var t2 = 1; t2 < arguments.length; t2++) {
                  var r2 = null != arguments[t2] ? arguments[t2] : {};
                  t2 % 2 ? ownKeys$1(Object(r2), true).forEach(function(t3) {
                    _defineProperty$1(e3, t3, r2[t3]);
                  }) : Object.getOwnPropertyDescriptors ? Object.defineProperties(e3, Object.getOwnPropertyDescriptors(r2)) : ownKeys$1(Object(r2)).forEach(function(t3) {
                    Object.defineProperty(e3, t3, Object.getOwnPropertyDescriptor(r2, t3));
                  });
                }
                return e3;
              })({}, e2);
            }, revive: function revive(e2) {
              return e2;
            } } }, p = [{ arrayNonindexKeys: { testPlainObjects: true, test: function test(e2, t2) {
              return !!Array.isArray(e2) && (Object.keys(e2).some(function(e3) {
                return String(Number.parseInt(e3)) !== e3;
              }) && (t2.iterateIn = "object", t2.addLength = true), true);
            }, replace: function replace(e2, t2) {
              return t2.iterateUnsetNumeric = true, e2;
            }, revive: function revive(e2) {
              if (Array.isArray(e2)) return e2;
              var t2 = [];
              return Object.keys(e2).forEach(function(r2) {
                var n2 = e2[r2];
                t2[r2] = n2;
              }), t2;
            } } }, { sparseUndefined: { test: function test(e2, t2) {
              return void 0 === e2 && false === t2.ownKeys;
            }, replace: function replace(e2) {
              return 0;
            }, revive: function revive(e2) {
            } } }], y = { undef: { test: function test(e2, t2) {
              return void 0 === e2 && (t2.ownKeys || !("ownKeys" in t2));
            }, replace: function replace(e2) {
              return 0;
            }, revive: function revive(e2) {
              return new s.Undefined();
            } } }, v = { StringObject: { test: function test(e2) {
              return "String" === s.toStringTag(e2) && "object" === _typeof$1(e2);
            }, replace: function replace(e2) {
              return String(e2);
            }, revive: function revive(e2) {
              return new String(e2);
            } }, BooleanObject: { test: function test(e2) {
              return "Boolean" === s.toStringTag(e2) && "object" === _typeof$1(e2);
            }, replace: function replace(e2) {
              return Boolean(e2);
            }, revive: function revive(e2) {
              return new Boolean(e2);
            } }, NumberObject: { test: function test(e2) {
              return "Number" === s.toStringTag(e2) && "object" === _typeof$1(e2);
            }, replace: function replace(e2) {
              return Number(e2);
            }, revive: function revive(e2) {
              return new Number(e2);
            } } }, b = [{ nan: { test: function test(e2) {
              return Number.isNaN(e2);
            }, replace: function replace(e2) {
              return "NaN";
            }, revive: function revive(e2) {
              return Number.NaN;
            } } }, { infinity: { test: function test(e2) {
              return e2 === Number.POSITIVE_INFINITY;
            }, replace: function replace(e2) {
              return "Infinity";
            }, revive: function revive(e2) {
              return Number.POSITIVE_INFINITY;
            } } }, { negativeInfinity: { test: function test(e2) {
              return e2 === Number.NEGATIVE_INFINITY;
            }, replace: function replace(e2) {
              return "-Infinity";
            }, revive: function revive(e2) {
              return Number.NEGATIVE_INFINITY;
            } } }], d = { date: { test: function test(e2) {
              return "Date" === s.toStringTag(e2);
            }, replace: function replace(e2) {
              var t2 = e2.getTime();
              return Number.isNaN(t2) ? "NaN" : t2;
            }, revive: function revive(e2) {
              return "NaN" === e2 ? new Date(Number.NaN) : new Date(e2);
            } } }, h = { regexp: { test: function test(e2) {
              return "RegExp" === s.toStringTag(e2);
            }, replace: function replace(e2) {
              return { source: e2.source, flags: (e2.global ? "g" : "") + (e2.ignoreCase ? "i" : "") + (e2.multiline ? "m" : "") + (e2.sticky ? "y" : "") + (e2.unicode ? "u" : "") };
            }, revive: function revive(e2) {
              var t2 = e2.source, r2 = e2.flags;
              return new RegExp(t2, r2);
            } } }, g2 = { map: { test: function test(e2) {
              return "Map" === s.toStringTag(e2);
            }, replace: function replace(e2) {
              return _toConsumableArray$1(e2.entries());
            }, revive: function revive(e2) {
              return new Map(e2);
            } } }, m = { set: { test: function test(e2) {
              return "Set" === s.toStringTag(e2);
            }, replace: function replace(e2) {
              return _toConsumableArray$1(e2.values());
            }, revive: function revive(e2) {
              return new Set(e2);
            } } }, O = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", _ = new Uint8Array(256), j = 0; j < O.length; j++) {
              _[O.charCodeAt(j)] = j;
            }
            var S = function encode(e2, t2, r2) {
              null == r2 && (r2 = e2.byteLength);
              for (var n2 = new Uint8Array(e2, t2 || 0, r2), i2 = n2.length, o2 = "", a2 = 0; a2 < i2; a2 += 3) {
                o2 += O[n2[a2] >> 2], o2 += O[(3 & n2[a2]) << 4 | n2[a2 + 1] >> 4], o2 += O[(15 & n2[a2 + 1]) << 2 | n2[a2 + 2] >> 6], o2 += O[63 & n2[a2 + 2]];
              }
              return i2 % 3 == 2 ? o2 = o2.slice(0, -1) + "=" : i2 % 3 == 1 && (o2 = o2.slice(0, -2) + "=="), o2;
            }, T = function decode(e2) {
              var t2, r2, n2, i2, o2 = e2.length, a2 = 0.75 * e2.length, c2 = 0;
              "=" === e2[e2.length - 1] && (a2--, "=" === e2[e2.length - 2] && a2--);
              for (var u2 = new ArrayBuffer(a2), s2 = new Uint8Array(u2), f2 = 0; f2 < o2; f2 += 4) {
                t2 = _[e2.charCodeAt(f2)], r2 = _[e2.charCodeAt(f2 + 1)], n2 = _[e2.charCodeAt(f2 + 2)], i2 = _[e2.charCodeAt(f2 + 3)], s2[c2++] = t2 << 2 | r2 >> 4, s2[c2++] = (15 & r2) << 4 | n2 >> 2, s2[c2++] = (3 & n2) << 6 | 63 & i2;
              }
              return u2;
            }, w = { arraybuffer: { test: function test(e2) {
              return "ArrayBuffer" === s.toStringTag(e2);
            }, replace: function replace(e2, t2) {
              t2.buffers || (t2.buffers = []);
              var r2 = t2.buffers.indexOf(e2);
              return r2 > -1 ? { index: r2 } : (t2.buffers.push(e2), S(e2));
            }, revive: function revive(e2, t2) {
              if (t2.buffers || (t2.buffers = []), "object" === _typeof$1(e2)) return t2.buffers[e2.index];
              var r2 = T(e2);
              return t2.buffers.push(r2), r2;
            } } }, A = "undefined" == typeof self ? globalThis : self, P = {};
            ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array", "Float32Array", "Float64Array"].forEach(function(e2) {
              var t2 = e2, r2 = A[t2];
              r2 && (P[e2.toLowerCase()] = { test: function test(e3) {
                return s.toStringTag(e3) === t2;
              }, replace: function replace(e3, t3) {
                var r3 = e3.buffer, n2 = e3.byteOffset, i2 = e3.length;
                t3.buffers || (t3.buffers = []);
                var o2 = t3.buffers.indexOf(r3);
                return o2 > -1 ? { index: o2, byteOffset: n2, length: i2 } : (t3.buffers.push(r3), { encoded: S(r3), byteOffset: n2, length: i2 });
              }, revive: function revive(e3, t3) {
                t3.buffers || (t3.buffers = []);
                var n2, i2 = e3.byteOffset, o2 = e3.length, a2 = e3.encoded, c2 = e3.index;
                return "index" in e3 ? n2 = t3.buffers[c2] : (n2 = T(a2), t3.buffers.push(n2)), new r2(n2, i2, o2);
              } });
            });
            var C = { dataview: { test: function test(e2) {
              return "DataView" === s.toStringTag(e2);
            }, replace: function replace(e2, t2) {
              var r2 = e2.buffer, n2 = e2.byteOffset, i2 = e2.byteLength;
              t2.buffers || (t2.buffers = []);
              var o2 = t2.buffers.indexOf(r2);
              return o2 > -1 ? { index: o2, byteOffset: n2, byteLength: i2 } : (t2.buffers.push(r2), { encoded: S(r2), byteOffset: n2, byteLength: i2 });
            }, revive: function revive(e2, t2) {
              t2.buffers || (t2.buffers = []);
              var r2, n2 = e2.byteOffset, i2 = e2.byteLength, o2 = e2.encoded, a2 = e2.index;
              return "index" in e2 ? r2 = t2.buffers[a2] : (r2 = T(o2), t2.buffers.push(r2)), new DataView(r2, n2, i2);
            } } }, I = { IntlCollator: { test: function test(e2) {
              return s.hasConstructorOf(e2, Intl.Collator);
            }, replace: function replace(e2) {
              return e2.resolvedOptions();
            }, revive: function revive(e2) {
              return new Intl.Collator(e2.locale, e2);
            } }, IntlDateTimeFormat: { test: function test(e2) {
              return s.hasConstructorOf(e2, Intl.DateTimeFormat);
            }, replace: function replace(e2) {
              return e2.resolvedOptions();
            }, revive: function revive(e2) {
              return new Intl.DateTimeFormat(e2.locale, e2);
            } }, IntlNumberFormat: { test: function test(e2) {
              return s.hasConstructorOf(e2, Intl.NumberFormat);
            }, replace: function replace(e2) {
              return e2.resolvedOptions();
            }, revive: function revive(e2) {
              return new Intl.NumberFormat(e2.locale, e2);
            } } };
            function string2arraybuffer(e2) {
              for (var t2 = new Uint8Array(e2.length), r2 = 0; r2 < e2.length; r2++) {
                t2[r2] = e2.charCodeAt(r2);
              }
              return t2.buffer;
            }
            var N = { file: { test: function test(e2) {
              return "File" === s.toStringTag(e2);
            }, replace: function replace(e2) {
              var t2 = new XMLHttpRequest();
              if (t2.overrideMimeType("text/plain; charset=x-user-defined"), t2.open("GET", URL.createObjectURL(e2), false), t2.send(), 200 !== t2.status && 0 !== t2.status) throw new Error("Bad File access: " + t2.status);
              return { type: e2.type, stringContents: t2.responseText, name: e2.name, lastModified: e2.lastModified };
            }, revive: function revive(e2) {
              var t2 = e2.name, r2 = e2.type, n2 = e2.stringContents, i2 = e2.lastModified;
              return new File([string2arraybuffer(n2)], t2, { type: r2, lastModified: i2 });
            }, replaceAsync: function replaceAsync(e2) {
              return new s.Promise(function(t2, r2) {
                var n2 = new FileReader();
                n2.addEventListener("load", function() {
                  t2({ type: e2.type, stringContents: n2.result, name: e2.name, lastModified: e2.lastModified });
                }), n2.addEventListener("error", function() {
                  r2(n2.error);
                }), n2.readAsBinaryString(e2);
              });
            } } }, k = { bigint: { test: function test(e2) {
              return "bigint" == typeof e2;
            }, replace: function replace(e2) {
              return String(e2);
            }, revive: function revive(e2) {
              return BigInt(e2);
            } } }, E = { bigintObject: { test: function test(e2) {
              return "object" === _typeof$1(e2) && s.hasConstructorOf(e2, BigInt);
            }, replace: function replace(e2) {
              return String(e2);
            }, revive: function revive(e2) {
              return new Object(BigInt(e2));
            } } }, B = { cryptokey: { test: function test(e2) {
              return "CryptoKey" === s.toStringTag(e2) && e2.extractable;
            }, replaceAsync: function replaceAsync(e2) {
              return new s.Promise(function(t2, r2) {
                crypto.subtle.exportKey("jwk", e2).catch(function(e3) {
                  r2(e3);
                }).then(function(r3) {
                  t2({ jwk: r3, algorithm: e2.algorithm, usages: e2.usages });
                });
              });
            }, revive: function revive(e2) {
              var t2 = e2.jwk, r2 = e2.algorithm, n2 = e2.usages;
              return crypto.subtle.importKey("jwk", t2, r2, true, n2);
            } } };
            return [l, y, p, v, b, d, h, { imagedata: { test: function test(e2) {
              return "ImageData" === s.toStringTag(e2);
            }, replace: function replace(e2) {
              return { array: _toConsumableArray$1(e2.data), width: e2.width, height: e2.height };
            }, revive: function revive(e2) {
              return new ImageData(new Uint8ClampedArray(e2.array), e2.width, e2.height);
            } } }, { imagebitmap: { test: function test(e2) {
              return "ImageBitmap" === s.toStringTag(e2) || e2 && e2.dataset && "ImageBitmap" === e2.dataset.toStringTag;
            }, replace: function replace(e2) {
              var t2 = document.createElement("canvas");
              return t2.getContext("2d").drawImage(e2, 0, 0), t2.toDataURL();
            }, revive: function revive(e2) {
              var t2 = document.createElement("canvas"), r2 = t2.getContext("2d"), n2 = document.createElement("img");
              return n2.addEventListener("load", function() {
                r2.drawImage(n2, 0, 0);
              }), n2.src = e2, t2;
            }, reviveAsync: function reviveAsync(e2) {
              var t2 = document.createElement("canvas"), r2 = t2.getContext("2d"), n2 = document.createElement("img");
              return n2.addEventListener("load", function() {
                r2.drawImage(n2, 0, 0);
              }), n2.src = e2, createImageBitmap(t2);
            } } }, N, { file: N.file, filelist: { test: function test(e2) {
              return "FileList" === s.toStringTag(e2);
            }, replace: function replace(e2) {
              for (var t2 = [], r2 = 0; r2 < e2.length; r2++) {
                t2[r2] = e2.item(r2);
              }
              return t2;
            }, revive: function revive(e2) {
              return new ((function() {
                function FileList() {
                  _classCallCheck$1(this, FileList), this._files = arguments[0], this.length = this._files.length;
                }
                return (function _createClass$1(e3, t2, r2) {
                  return t2 && _defineProperties$1(e3.prototype, t2), r2 && _defineProperties$1(e3, r2), e3;
                })(FileList, [{ key: "item", value: function item(e3) {
                  return this._files[e3];
                } }, { key: Symbol.toStringTag, get: function get() {
                  return "FileList";
                } }]), FileList;
              })())(e2);
            } } }, { blob: { test: function test(e2) {
              return "Blob" === s.toStringTag(e2);
            }, replace: function replace(e2) {
              var t2 = new XMLHttpRequest();
              if (t2.overrideMimeType("text/plain; charset=x-user-defined"), t2.open("GET", URL.createObjectURL(e2), false), t2.send(), 200 !== t2.status && 0 !== t2.status) throw new Error("Bad Blob access: " + t2.status);
              return { type: e2.type, stringContents: t2.responseText };
            }, revive: function revive(e2) {
              var t2 = e2.type, r2 = e2.stringContents;
              return new Blob([string2arraybuffer(r2)], { type: t2 });
            }, replaceAsync: function replaceAsync(e2) {
              return new s.Promise(function(t2, r2) {
                var n2 = new FileReader();
                n2.addEventListener("load", function() {
                  t2({ type: e2.type, stringContents: n2.result });
                }), n2.addEventListener("error", function() {
                  r2(n2.error);
                }), n2.readAsBinaryString(e2);
              });
            } } }].concat("function" == typeof Map ? g2 : [], "function" == typeof Set ? m : [], "function" == typeof ArrayBuffer ? w : [], "function" == typeof Uint8Array ? P : [], "function" == typeof DataView ? C : [], "undefined" != typeof Intl ? I : [], "undefined" != typeof crypto ? B : [], "undefined" != typeof BigInt ? [k, E] : []).concat({ checkDataCloneException: { test: function test(e2) {
              var t2 = {}.toString.call(e2).slice(8, -1);
              if (["symbol", "function"].includes(_typeof$1(e2)) || ["Arguments", "Module", "Error", "Promise", "WeakMap", "WeakSet", "Event", "MessageChannel"].includes(t2) || e2 && "object" === _typeof$1(e2) && "number" == typeof e2.nodeType && "function" == typeof e2.insertBefore) throw new DOMException("The object cannot be cloned.", "DataCloneError");
              return false;
            } } });
          });
        }, {}], 86: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof2 = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          function _typeof(e2) {
            return (_typeof = "function" == typeof Symbol && "symbol" == _typeof2(Symbol.iterator) ? function(e3) {
              return typeof e3 === "undefined" ? "undefined" : _typeof2(e3);
            } : function(e3) {
              return e3 && "function" == typeof Symbol && e3.constructor === Symbol && e3 !== Symbol.prototype ? "symbol" : typeof e3 === "undefined" ? "undefined" : _typeof2(e3);
            })(e2);
          }
          function _classCallCheck(e2, t2) {
            if (!(e2 instanceof t2)) throw new TypeError("Cannot call a class as a function");
          }
          function _defineProperties(e2, t2) {
            for (var r2 = 0; r2 < t2.length; r2++) {
              var n2 = t2[r2];
              n2.enumerable = n2.enumerable || false, n2.configurable = true, "value" in n2 && (n2.writable = true), Object.defineProperty(e2, n2.key, n2);
            }
          }
          function _defineProperty(e2, t2, r2) {
            return t2 in e2 ? Object.defineProperty(e2, t2, { value: r2, enumerable: true, configurable: true, writable: true }) : e2[t2] = r2, e2;
          }
          function ownKeys(e2, t2) {
            var r2 = Object.keys(e2);
            if (Object.getOwnPropertySymbols) {
              var n2 = Object.getOwnPropertySymbols(e2);
              t2 && (n2 = n2.filter(function(t3) {
                return Object.getOwnPropertyDescriptor(e2, t3).enumerable;
              })), r2.push.apply(r2, n2);
            }
            return r2;
          }
          function _objectSpread2(e2) {
            for (var t2 = 1; t2 < arguments.length; t2++) {
              var r2 = null != arguments[t2] ? arguments[t2] : {};
              t2 % 2 ? ownKeys(Object(r2), true).forEach(function(t3) {
                _defineProperty(e2, t3, r2[t3]);
              }) : Object.getOwnPropertyDescriptors ? Object.defineProperties(e2, Object.getOwnPropertyDescriptors(r2)) : ownKeys(Object(r2)).forEach(function(t3) {
                Object.defineProperty(e2, t3, Object.getOwnPropertyDescriptor(r2, t3));
              });
            }
            return e2;
          }
          function _slicedToArray(e2, t2) {
            return (function _arrayWithHoles(e3) {
              if (Array.isArray(e3)) return e3;
            })(e2) || (function _iterableToArrayLimit(e3, t3) {
              if ("undefined" == typeof Symbol || !(Symbol.iterator in Object(e3))) return;
              var r2 = [], n2 = true, o2 = false, a2 = void 0;
              try {
                for (var i2, c2 = e3[Symbol.iterator](); !(n2 = (i2 = c2.next()).done) && (r2.push(i2.value), !t3 || r2.length !== t3); n2 = true) {
                }
              } catch (e4) {
                o2 = true, a2 = e4;
              } finally {
                try {
                  n2 || null == c2.return || c2.return();
                } finally {
                  if (o2) throw a2;
                }
              }
              return r2;
            })(e2, t2) || _unsupportedIterableToArray(e2, t2) || (function _nonIterableRest() {
              throw new TypeError("Invalid attempt to destructure non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
            })();
          }
          function _toConsumableArray(e2) {
            return (function _arrayWithoutHoles(e3) {
              if (Array.isArray(e3)) return _arrayLikeToArray(e3);
            })(e2) || (function _iterableToArray(e3) {
              if ("undefined" != typeof Symbol && Symbol.iterator in Object(e3)) return Array.from(e3);
            })(e2) || _unsupportedIterableToArray(e2) || (function _nonIterableSpread() {
              throw new TypeError("Invalid attempt to spread non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
            })();
          }
          function _unsupportedIterableToArray(e2, t2) {
            if (e2) {
              if ("string" == typeof e2) return _arrayLikeToArray(e2, t2);
              var r2 = Object.prototype.toString.call(e2).slice(8, -1);
              return "Object" === r2 && e2.constructor && (r2 = e2.constructor.name), "Map" === r2 || "Set" === r2 ? Array.from(e2) : "Arguments" === r2 || /^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(r2) ? _arrayLikeToArray(e2, t2) : void 0;
            }
          }
          function _arrayLikeToArray(e2, t2) {
            (null == t2 || t2 > e2.length) && (t2 = e2.length);
            for (var r2 = 0, n2 = new Array(t2); r2 < t2; r2++) {
              n2[r2] = e2[r2];
            }
            return n2;
          }
          var e = function TypesonPromise(e2) {
            _classCallCheck(this, TypesonPromise), this.p = new Promise(e2);
          };
          e.__typeson__type__ = "TypesonPromise", "undefined" != typeof Symbol && (e.prototype[Symbol.toStringTag] = "TypesonPromise"), e.prototype.then = function(t2, r2) {
            var n2 = this;
            return new e(function(e2, o2) {
              n2.p.then(function(r3) {
                e2(t2 ? t2(r3) : r3);
              }).catch(function(e3) {
                return r2 ? r2(e3) : Promise.reject(e3);
              }).then(e2, o2);
            });
          }, e.prototype.catch = function(e2) {
            return this.then(null, e2);
          }, e.resolve = function(t2) {
            return new e(function(e2) {
              e2(t2);
            });
          }, e.reject = function(t2) {
            return new e(function(e2, r2) {
              r2(t2);
            });
          }, ["all", "race", "allSettled"].forEach(function(t2) {
            e[t2] = function(r2) {
              return new e(function(e2, n2) {
                Promise[t2](r2.map(function(e3) {
                  return e3 && e3.constructor && "TypesonPromise" === e3.constructor.__typeson__type__ ? e3.p : e3;
                })).then(e2, n2);
              });
            };
          });
          var t = {}.toString, r = {}.hasOwnProperty, n = Object.getPrototypeOf, o = r.toString;
          function isThenable(e2, t2) {
            return isObject(e2) && "function" == typeof e2.then && (!t2 || "function" == typeof e2.catch);
          }
          function toStringTag(e2) {
            return t.call(e2).slice(8, -1);
          }
          function hasConstructorOf(e2, t2) {
            if (!e2 || "object" !== _typeof(e2)) return false;
            var a2 = n(e2);
            if (!a2) return null === t2;
            var i2 = r.call(a2, "constructor") && a2.constructor;
            return "function" != typeof i2 ? null === t2 : t2 === i2 || null !== t2 && o.call(i2) === o.call(t2) || "function" == typeof t2 && "string" == typeof i2.__typeson__type__ && i2.__typeson__type__ === t2.__typeson__type__;
          }
          function isPlainObject(e2) {
            return !(!e2 || "Object" !== toStringTag(e2)) && (!n(e2) || hasConstructorOf(e2, Object));
          }
          function isObject(e2) {
            return e2 && "object" === _typeof(e2);
          }
          function escapeKeyPathComponent(e2) {
            return e2.replace(/~/g, "~0").replace(/\./g, "~1");
          }
          function unescapeKeyPathComponent(e2) {
            return e2.replace(/~1/g, ".").replace(/~0/g, "~");
          }
          function getByKeyPath(e2, t2) {
            if ("" === t2) return e2;
            var r2 = t2.indexOf(".");
            if (r2 > -1) {
              var n2 = e2[unescapeKeyPathComponent(t2.slice(0, r2))];
              return void 0 === n2 ? void 0 : getByKeyPath(n2, t2.slice(r2 + 1));
            }
            return e2[unescapeKeyPathComponent(t2)];
          }
          function setAtKeyPath(e2, t2, r2) {
            if ("" === t2) return r2;
            var n2 = t2.indexOf(".");
            return n2 > -1 ? setAtKeyPath(e2[unescapeKeyPathComponent(t2.slice(0, n2))], t2.slice(n2 + 1), r2) : (e2[unescapeKeyPathComponent(t2)] = r2, e2);
          }
          function _await(e2, t2, r2) {
            return r2 ? t2 ? t2(e2) : e2 : (e2 && e2.then || (e2 = Promise.resolve(e2)), t2 ? e2.then(t2) : e2);
          }
          var a = Object.keys, i = Array.isArray, c = {}.hasOwnProperty, s = ["type", "replaced", "iterateIn", "iterateUnsetNumeric"];
          function _async(e2) {
            return function() {
              for (var t2 = [], r2 = 0; r2 < arguments.length; r2++) {
                t2[r2] = arguments[r2];
              }
              try {
                return Promise.resolve(e2.apply(this, t2));
              } catch (e3) {
                return Promise.reject(e3);
              }
            };
          }
          function nestedPathsFirst(e2, t2) {
            if ("" === e2.keypath) return -1;
            var r2 = e2.keypath.match(/\./g) || 0, n2 = t2.keypath.match(/\./g) || 0;
            return r2 && (r2 = r2.length), n2 && (n2 = n2.length), r2 > n2 ? -1 : r2 < n2 ? 1 : e2.keypath < t2.keypath ? -1 : e2.keypath > t2.keypath;
          }
          var u = (function() {
            function Typeson(e2) {
              _classCallCheck(this, Typeson), this.options = e2, this.plainObjectReplacers = [], this.nonplainObjectReplacers = [], this.revivers = {}, this.types = {};
            }
            return (function _createClass(e2, t2, r2) {
              return t2 && _defineProperties(e2.prototype, t2), r2 && _defineProperties(e2, r2), e2;
            })(Typeson, [{ key: "stringify", value: function stringify(e2, t2, r2, n2) {
              n2 = _objectSpread2(_objectSpread2(_objectSpread2({}, this.options), n2), {}, { stringification: true });
              var o2 = this.encapsulate(e2, null, n2);
              return i(o2) ? JSON.stringify(o2[0], t2, r2) : o2.then(function(e3) {
                return JSON.stringify(e3, t2, r2);
              });
            } }, { key: "stringifySync", value: function stringifySync(e2, t2, r2, n2) {
              return this.stringify(e2, t2, r2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, n2), {}, { sync: true }));
            } }, { key: "stringifyAsync", value: function stringifyAsync(e2, t2, r2, n2) {
              return this.stringify(e2, t2, r2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, n2), {}, { sync: false }));
            } }, { key: "parse", value: function parse(e2, t2, r2) {
              return r2 = _objectSpread2(_objectSpread2(_objectSpread2({}, this.options), r2), {}, { parse: true }), this.revive(JSON.parse(e2, t2), r2);
            } }, { key: "parseSync", value: function parseSync(e2, t2, r2) {
              return this.parse(e2, t2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, r2), {}, { sync: true }));
            } }, { key: "parseAsync", value: function parseAsync(e2, t2, r2) {
              return this.parse(e2, t2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, r2), {}, { sync: false }));
            } }, { key: "specialTypeNames", value: function specialTypeNames(e2, t2) {
              var r2 = arguments.length > 2 && void 0 !== arguments[2] ? arguments[2] : {};
              return r2.returnTypeNames = true, this.encapsulate(e2, t2, r2);
            } }, { key: "rootTypeName", value: function rootTypeName(e2, t2) {
              var r2 = arguments.length > 2 && void 0 !== arguments[2] ? arguments[2] : {};
              return r2.iterateNone = true, this.encapsulate(e2, t2, r2);
            } }, { key: "encapsulate", value: function encapsulate(t2, r2, n2) {
              var o2 = _async(function(t3, r3) {
                return _await(Promise.all(r3.map(function(e2) {
                  return e2[1].p;
                })), function(n3) {
                  return _await(Promise.all(n3.map(_async(function(n4) {
                    var a2 = false, i2 = [], c2 = _slicedToArray(r3.splice(0, 1), 1), s2 = _slicedToArray(c2[0], 7), u3 = s2[0], p3 = s2[2], y2 = s2[3], l2 = s2[4], f2 = s2[5], h2 = s2[6], v2 = _encapsulate(u3, n4, p3, y2, i2, true, h2), d2 = hasConstructorOf(v2, e);
                    return (function _invoke(e2, t4) {
                      var r4 = e2();
                      return r4 && r4.then ? r4.then(t4) : t4(r4);
                    })(function() {
                      if (u3 && d2) return _await(v2.p, function(e2) {
                        return l2[f2] = e2, a2 = true, o2(t3, i2);
                      });
                    }, function(e2) {
                      return a2 ? e2 : (u3 ? l2[f2] = v2 : t3 = d2 ? v2.p : v2, o2(t3, i2));
                    });
                  }))), function() {
                    return t3;
                  });
                });
              }), u2 = (n2 = _objectSpread2(_objectSpread2({ sync: true }, this.options), n2)).sync, p2 = this, y = {}, l = [], f = [], h = [], v = !("cyclic" in n2) || n2.cyclic, d = n2.encapsulateObserver, b = _encapsulate("", t2, v, r2 || {}, h);
              function finish(e2) {
                var t3 = Object.values(y);
                if (n2.iterateNone) return t3.length ? t3[0] : Typeson.getJSONType(e2);
                if (t3.length) {
                  if (n2.returnTypeNames) return _toConsumableArray(new Set(t3));
                  e2 && isPlainObject(e2) && !c.call(e2, "$types") ? e2.$types = y : e2 = { $: e2, $types: { $: y } };
                } else isObject(e2) && c.call(e2, "$types") && (e2 = { $: e2, $types: true });
                return !n2.returnTypeNames && e2;
              }
              function _adaptBuiltinStateObjectProperties(e2, t3, r3) {
                Object.assign(e2, t3);
                var n3 = s.map(function(t4) {
                  var r4 = e2[t4];
                  return delete e2[t4], r4;
                });
                r3(), s.forEach(function(t4, r4) {
                  e2[t4] = n3[r4];
                });
              }
              function _encapsulate(t3, r3, o3, s2, u3, h2, v2) {
                var b2, _ = {}, O = _typeof(r3), j = d ? function(n3) {
                  var a2 = v2 || s2.type || Typeson.getJSONType(r3);
                  d(Object.assign(n3 || _, { keypath: t3, value: r3, cyclic: o3, stateObj: s2, promisesData: u3, resolvingTypesonPromise: h2, awaitingTypesonPromise: hasConstructorOf(r3, e) }, { type: a2 }));
                } : null;
                if (["string", "boolean", "number", "undefined"].includes(O)) return void 0 === r3 || Number.isNaN(r3) || r3 === Number.NEGATIVE_INFINITY || r3 === Number.POSITIVE_INFINITY ? (b2 = s2.replaced ? r3 : replace(t3, r3, s2, u3, false, h2, j)) !== r3 && (_ = { replaced: b2 }) : b2 = r3, j && j(), b2;
                if (null === r3) return j && j(), r3;
                if (o3 && !s2.iterateIn && !s2.iterateUnsetNumeric && r3 && "object" === _typeof(r3)) {
                  var m = l.indexOf(r3);
                  if (!(m < 0)) return y[t3] = "#", j && j({ cyclicKeypath: f[m] }), "#" + f[m];
                  true === o3 && (l.push(r3), f.push(t3));
                }
                var S, g2 = isPlainObject(r3), P = i(r3), T = (g2 || P) && (!p2.plainObjectReplacers.length || s2.replaced) || s2.iterateIn ? r3 : replace(t3, r3, s2, u3, g2 || P, null, j);
                if (T !== r3 ? (b2 = T, _ = { replaced: T }) : "" === t3 && hasConstructorOf(r3, e) ? (u3.push([t3, r3, o3, s2, void 0, void 0, s2.type]), b2 = r3) : P && "object" !== s2.iterateIn || "array" === s2.iterateIn ? (S = new Array(r3.length), _ = { clone: S }) : (["function", "symbol"].includes(_typeof(r3)) || "toJSON" in r3 || hasConstructorOf(r3, e) || hasConstructorOf(r3, Promise) || hasConstructorOf(r3, ArrayBuffer)) && !g2 && "object" !== s2.iterateIn ? b2 = r3 : (S = {}, s2.addLength && (S.length = r3.length), _ = { clone: S }), j && j(), n2.iterateNone) return S || b2;
                if (!S) return b2;
                if (s2.iterateIn) {
                  var w = function _loop(n3) {
                    var a2 = { ownKeys: c.call(r3, n3) };
                    _adaptBuiltinStateObjectProperties(s2, a2, function() {
                      var a3 = t3 + (t3 ? "." : "") + escapeKeyPathComponent(n3), i2 = _encapsulate(a3, r3[n3], Boolean(o3), s2, u3, h2);
                      hasConstructorOf(i2, e) ? u3.push([a3, i2, Boolean(o3), s2, S, n3, s2.type]) : void 0 !== i2 && (S[n3] = i2);
                    });
                  };
                  for (var A in r3) {
                    w(A);
                  }
                  j && j({ endIterateIn: true, end: true });
                } else a(r3).forEach(function(n3) {
                  var a2 = t3 + (t3 ? "." : "") + escapeKeyPathComponent(n3);
                  _adaptBuiltinStateObjectProperties(s2, { ownKeys: true }, function() {
                    var t4 = _encapsulate(a2, r3[n3], Boolean(o3), s2, u3, h2);
                    hasConstructorOf(t4, e) ? u3.push([a2, t4, Boolean(o3), s2, S, n3, s2.type]) : void 0 !== t4 && (S[n3] = t4);
                  });
                }), j && j({ endIterateOwn: true, end: true });
                if (s2.iterateUnsetNumeric) {
                  for (var C = r3.length, k = function _loop2(n3) {
                    if (!(n3 in r3)) {
                      var a2 = t3 + (t3 ? "." : "") + n3;
                      _adaptBuiltinStateObjectProperties(s2, { ownKeys: false }, function() {
                        var t4 = _encapsulate(a2, void 0, Boolean(o3), s2, u3, h2);
                        hasConstructorOf(t4, e) ? u3.push([a2, t4, Boolean(o3), s2, S, n3, s2.type]) : void 0 !== t4 && (S[n3] = t4);
                      });
                    }
                  }, N = 0; N < C; N++) {
                    k(N);
                  }
                  j && j({ endIterateUnsetNumeric: true, end: true });
                }
                return S;
              }
              function replace(e2, t3, r3, n3, o3, a2, i2) {
                for (var c2 = o3 ? p2.plainObjectReplacers : p2.nonplainObjectReplacers, s2 = c2.length; s2--; ) {
                  var l2 = c2[s2];
                  if (l2.test(t3, r3)) {
                    var f2 = l2.type;
                    if (p2.revivers[f2]) {
                      var h2 = y[e2];
                      y[e2] = h2 ? [f2].concat(h2) : f2;
                    }
                    return Object.assign(r3, { type: f2, replaced: true }), !u2 && l2.replaceAsync || l2.replace ? (i2 && i2({ replacing: true }), _encapsulate(e2, l2[u2 || !l2.replaceAsync ? "replace" : "replaceAsync"](t3, r3), v && "readonly", r3, n3, a2, f2)) : (i2 && i2({ typeDetected: true }), _encapsulate(e2, t3, v && "readonly", r3, n3, a2, f2));
                  }
                }
                return t3;
              }
              return h.length ? u2 && n2.throwOnBadSyncType ? (function() {
                throw new TypeError("Sync method requested but async result obtained");
              })() : Promise.resolve(o2(b, h)).then(finish) : !u2 && n2.throwOnBadSyncType ? (function() {
                throw new TypeError("Async method requested but sync result obtained");
              })() : n2.stringification && u2 ? [finish(b)] : u2 ? finish(b) : Promise.resolve(finish(b));
            } }, { key: "encapsulateSync", value: function encapsulateSync(e2, t2, r2) {
              return this.encapsulate(e2, t2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, r2), {}, { sync: true }));
            } }, { key: "encapsulateAsync", value: function encapsulateAsync(e2, t2, r2) {
              return this.encapsulate(e2, t2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, r2), {}, { sync: false }));
            } }, { key: "revive", value: function revive(t2, r2) {
              var n2 = t2 && t2.$types;
              if (!n2) return t2;
              if (true === n2) return t2.$;
              var o2 = (r2 = _objectSpread2(_objectSpread2({ sync: true }, this.options), r2)).sync, c2 = [], s2 = {}, u2 = true;
              n2.$ && isPlainObject(n2.$) && (t2 = t2.$, n2 = n2.$, u2 = false);
              var y = this;
              function executeReviver(e2, t3) {
                var r3 = _slicedToArray(y.revivers[e2] || [], 1)[0];
                if (!r3) throw new Error("Unregistered type: " + e2);
                return o2 && !("revive" in r3) ? t3 : r3[o2 && r3.revive ? "revive" : !o2 && r3.reviveAsync ? "reviveAsync" : "revive"](t3, s2);
              }
              var l = [];
              function checkUndefined(e2) {
                return hasConstructorOf(e2, p) ? void 0 : e2;
              }
              var f, h = (function revivePlainObjects() {
                var r3 = [];
                if (Object.entries(n2).forEach(function(e2) {
                  var t3 = _slicedToArray(e2, 2), o3 = t3[0], a2 = t3[1];
                  "#" !== a2 && [].concat(a2).forEach(function(e3) {
                    _slicedToArray(y.revivers[e3] || [null, {}], 2)[1].plain && (r3.push({ keypath: o3, type: e3 }), delete n2[o3]);
                  });
                }), r3.length) return r3.sort(nestedPathsFirst).reduce(function reducer(r4, n3) {
                  var o3 = n3.keypath, a2 = n3.type;
                  if (isThenable(r4)) return r4.then(function(e2) {
                    return reducer(e2, { keypath: o3, type: a2 });
                  });
                  var i2 = getByKeyPath(t2, o3);
                  if (hasConstructorOf(i2 = executeReviver(a2, i2), e)) return i2.then(function(e2) {
                    var r5 = setAtKeyPath(t2, o3, e2);
                    r5 === e2 && (t2 = r5);
                  });
                  var c3 = setAtKeyPath(t2, o3, i2);
                  c3 === i2 && (t2 = c3);
                }, void 0);
              })();
              return hasConstructorOf(h, e) ? f = h.then(function() {
                return t2;
              }) : (f = (function _revive(t3, r3, o3, s3, y2) {
                if (!u2 || "$types" !== t3) {
                  var f2 = n2[t3], h2 = i(r3);
                  if (h2 || isPlainObject(r3)) {
                    var v = h2 ? new Array(r3.length) : {};
                    for (a(r3).forEach(function(n3) {
                      var a2 = _revive(t3 + (t3 ? "." : "") + escapeKeyPathComponent(n3), r3[n3], o3 || v, v, n3), i2 = function set(e2) {
                        return hasConstructorOf(e2, p) ? v[n3] = void 0 : void 0 !== e2 && (v[n3] = e2), e2;
                      };
                      hasConstructorOf(a2, e) ? l.push(a2.then(function(e2) {
                        return i2(e2);
                      })) : i2(a2);
                    }), r3 = v; c2.length; ) {
                      var d = _slicedToArray(c2[0], 4), b = d[0], _ = d[1], O = d[2], j = d[3], m = getByKeyPath(b, _);
                      if (void 0 === m) break;
                      O[j] = m, c2.splice(0, 1);
                    }
                  }
                  if (!f2) return r3;
                  if ("#" === f2) {
                    var S = getByKeyPath(o3, r3.slice(1));
                    return void 0 === S && c2.push([o3, r3.slice(1), s3, y2]), S;
                  }
                  return [].concat(f2).reduce(function reducer(t4, r4) {
                    return hasConstructorOf(t4, e) ? t4.then(function(e2) {
                      return reducer(e2, r4);
                    }) : executeReviver(r4, t4);
                  }, r3);
                }
              })("", t2, null), l.length && (f = e.resolve(f).then(function(t3) {
                return e.all([t3].concat(l));
              }).then(function(e2) {
                return _slicedToArray(e2, 1)[0];
              }))), isThenable(f) ? o2 && r2.throwOnBadSyncType ? (function() {
                throw new TypeError("Sync method requested but async result obtained");
              })() : hasConstructorOf(f, e) ? f.p.then(checkUndefined) : f : !o2 && r2.throwOnBadSyncType ? (function() {
                throw new TypeError("Async method requested but sync result obtained");
              })() : o2 ? checkUndefined(f) : Promise.resolve(checkUndefined(f));
            } }, { key: "reviveSync", value: function reviveSync(e2, t2) {
              return this.revive(e2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, t2), {}, { sync: true }));
            } }, { key: "reviveAsync", value: function reviveAsync(e2, t2) {
              return this.revive(e2, _objectSpread2(_objectSpread2({ throwOnBadSyncType: true }, t2), {}, { sync: false }));
            } }, { key: "register", value: function register(e2, t2) {
              return t2 = t2 || {}, [].concat(e2).forEach(function R(e3) {
                var r2 = this;
                if (i(e3)) return e3.map(function(e4) {
                  return R.call(r2, e4);
                });
                e3 && a(e3).forEach(function(r3) {
                  if ("#" === r3) throw new TypeError("# cannot be used as a type name as it is reserved for cyclic objects");
                  if (Typeson.JSON_TYPES.includes(r3)) throw new TypeError("Plain JSON object types are reserved as type names");
                  var n2 = e3[r3], o2 = n2 && n2.testPlainObjects ? this.plainObjectReplacers : this.nonplainObjectReplacers, a2 = o2.filter(function(e4) {
                    return e4.type === r3;
                  });
                  if (a2.length && (o2.splice(o2.indexOf(a2[0]), 1), delete this.revivers[r3], delete this.types[r3]), "function" == typeof n2) {
                    var c2 = n2;
                    n2 = { test: function test(e4) {
                      return e4 && e4.constructor === c2;
                    }, replace: function replace(e4) {
                      return _objectSpread2({}, e4);
                    }, revive: function revive(e4) {
                      return Object.assign(Object.create(c2.prototype), e4);
                    } };
                  } else if (i(n2)) {
                    var s2 = _slicedToArray(n2, 3);
                    n2 = { test: s2[0], replace: s2[1], revive: s2[2] };
                  }
                  if (n2 && n2.test) {
                    var u2 = { type: r3, test: n2.test.bind(n2) };
                    n2.replace && (u2.replace = n2.replace.bind(n2)), n2.replaceAsync && (u2.replaceAsync = n2.replaceAsync.bind(n2));
                    var p2 = "number" == typeof t2.fallback ? t2.fallback : t2.fallback ? 0 : Number.POSITIVE_INFINITY;
                    if (n2.testPlainObjects ? this.plainObjectReplacers.splice(p2, 0, u2) : this.nonplainObjectReplacers.splice(p2, 0, u2), n2.revive || n2.reviveAsync) {
                      var y = {};
                      n2.revive && (y.revive = n2.revive.bind(n2)), n2.reviveAsync && (y.reviveAsync = n2.reviveAsync.bind(n2)), this.revivers[r3] = [y, { plain: n2.testPlainObjects }];
                    }
                    this.types[r3] = n2;
                  }
                }, this);
              }, this), this;
            } }]), Typeson;
          })(), p = function Undefined() {
            _classCallCheck(this, Undefined);
          };
          p.__typeson__type__ = "TypesonUndefined", u.Undefined = p, u.Promise = e, u.isThenable = isThenable, u.toStringTag = toStringTag, u.hasConstructorOf = hasConstructorOf, u.isObject = isObject, u.isPlainObject = isPlainObject, u.isUserObject = function isUserObject(e2) {
            if (!e2 || "Object" !== toStringTag(e2)) return false;
            var t2 = n(e2);
            return !t2 || hasConstructorOf(e2, Object) || isUserObject(t2);
          }, u.escapeKeyPathComponent = escapeKeyPathComponent, u.unescapeKeyPathComponent = unescapeKeyPathComponent, u.getByKeyPath = getByKeyPath, u.getJSONType = function getJSONType(e2) {
            return null === e2 ? "null" : Array.isArray(e2) ? "array" : _typeof(e2);
          }, u.JSON_TYPES = ["null", "boolean", "number", "string", "array", "object"], module3.exports = u;
        }, {}], 87: [function(_dereq_, module3, exports3) {
          "use strict";
          var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function(obj) {
            return typeof obj;
          } : function(obj) {
            return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj;
          };
          function _(message, opts) {
            return (opts && opts.context ? opts.context : "Value") + " " + message + ".";
          }
          function type(V) {
            if (V === null) {
              return "Null";
            }
            switch (typeof V === "undefined" ? "undefined" : _typeof(V)) {
              case "undefined":
                return "Undefined";
              case "boolean":
                return "Boolean";
              case "number":
                return "Number";
              case "string":
                return "String";
              case "symbol":
                return "Symbol";
              case "object":
              // Falls through
              case "function":
              // Falls through
              default:
                return "Object";
            }
          }
          function evenRound(x) {
            if (x > 0 && x % 1 === 0.5 && (x & 1) === 0 || x < 0 && x % 1 === -0.5 && (x & 1) === 1) {
              return censorNegativeZero(Math.floor(x));
            }
            return censorNegativeZero(Math.round(x));
          }
          function integerPart(n) {
            return censorNegativeZero(Math.trunc(n));
          }
          function sign(x) {
            return x < 0 ? -1 : 1;
          }
          function modulo(x, y) {
            var signMightNotMatch = x % y;
            if (sign(y) !== sign(signMightNotMatch)) {
              return signMightNotMatch + y;
            }
            return signMightNotMatch;
          }
          function censorNegativeZero(x) {
            return x === 0 ? 0 : x;
          }
          function createIntegerConversion(bitLength, typeOpts) {
            var isSigned = !typeOpts.unsigned;
            var lowerBound = void 0;
            var upperBound = void 0;
            if (bitLength === 64) {
              upperBound = Math.pow(2, 53) - 1;
              lowerBound = !isSigned ? 0 : -Math.pow(2, 53) + 1;
            } else if (!isSigned) {
              lowerBound = 0;
              upperBound = Math.pow(2, bitLength) - 1;
            } else {
              lowerBound = -Math.pow(2, bitLength - 1);
              upperBound = Math.pow(2, bitLength - 1) - 1;
            }
            var twoToTheBitLength = Math.pow(2, bitLength);
            var twoToOneLessThanTheBitLength = Math.pow(2, bitLength - 1);
            return function(V, opts) {
              if (opts === void 0) {
                opts = {};
              }
              var x = +V;
              x = censorNegativeZero(x);
              if (opts.enforceRange) {
                if (!Number.isFinite(x)) {
                  throw new TypeError(_("is not a finite number", opts));
                }
                x = integerPart(x);
                if (x < lowerBound || x > upperBound) {
                  throw new TypeError(_("is outside the accepted range of " + lowerBound + " to " + upperBound + ", inclusive", opts));
                }
                return x;
              }
              if (!Number.isNaN(x) && opts.clamp) {
                x = Math.min(Math.max(x, lowerBound), upperBound);
                x = evenRound(x);
                return x;
              }
              if (!Number.isFinite(x) || x === 0) {
                return 0;
              }
              x = integerPart(x);
              if (x >= lowerBound && x <= upperBound) {
                return x;
              }
              x = modulo(x, twoToTheBitLength);
              if (isSigned && x >= twoToOneLessThanTheBitLength) {
                return x - twoToTheBitLength;
              }
              return x;
            };
          }
          exports3.any = function(V) {
            return V;
          };
          exports3.void = function() {
            return void 0;
          };
          exports3.boolean = function(val) {
            return !!val;
          };
          exports3.byte = createIntegerConversion(8, { unsigned: false });
          exports3.octet = createIntegerConversion(8, { unsigned: true });
          exports3.short = createIntegerConversion(16, { unsigned: false });
          exports3["unsigned short"] = createIntegerConversion(16, { unsigned: true });
          exports3.long = createIntegerConversion(32, { unsigned: false });
          exports3["unsigned long"] = createIntegerConversion(32, { unsigned: true });
          exports3["long long"] = createIntegerConversion(64, { unsigned: false });
          exports3["unsigned long long"] = createIntegerConversion(64, { unsigned: true });
          exports3.double = function(V, opts) {
            var x = +V;
            if (!Number.isFinite(x)) {
              throw new TypeError(_("is not a finite floating-point value", opts));
            }
            return x;
          };
          exports3["unrestricted double"] = function(V) {
            var x = +V;
            return x;
          };
          exports3.float = function(V, opts) {
            var x = +V;
            if (!Number.isFinite(x)) {
              throw new TypeError(_("is not a finite floating-point value", opts));
            }
            if (Object.is(x, -0)) {
              return x;
            }
            var y = Math.fround(x);
            if (!Number.isFinite(y)) {
              throw new TypeError(_("is outside the range of a single-precision floating-point value", opts));
            }
            return y;
          };
          exports3["unrestricted float"] = function(V) {
            var x = +V;
            if (isNaN(x)) {
              return x;
            }
            if (Object.is(x, -0)) {
              return x;
            }
            return Math.fround(x);
          };
          exports3.DOMString = function(V, opts) {
            if (opts === void 0) {
              opts = {};
            }
            if (opts.treatNullAsEmptyString && V === null) {
              return "";
            }
            if ((typeof V === "undefined" ? "undefined" : _typeof(V)) === "symbol") {
              throw new TypeError(_("is a symbol, which cannot be converted to a string", opts));
            }
            return String(V);
          };
          exports3.ByteString = function(V, opts) {
            var x = exports3.DOMString(V, opts);
            var c = void 0;
            for (var i = 0; (c = x.codePointAt(i)) !== void 0; ++i) {
              if (c > 255) {
                throw new TypeError(_("is not a valid ByteString", opts));
              }
            }
            return x;
          };
          exports3.USVString = function(V, opts) {
            var S = exports3.DOMString(V, opts);
            var n = S.length;
            var U = [];
            for (var i = 0; i < n; ++i) {
              var c = S.charCodeAt(i);
              if (c < 55296 || c > 57343) {
                U.push(String.fromCodePoint(c));
              } else if (56320 <= c && c <= 57343) {
                U.push(String.fromCodePoint(65533));
              } else if (i === n - 1) {
                U.push(String.fromCodePoint(65533));
              } else {
                var d = S.charCodeAt(i + 1);
                if (56320 <= d && d <= 57343) {
                  var a = c & 1023;
                  var b = d & 1023;
                  U.push(String.fromCodePoint((2 << 15) + (2 << 9) * a + b));
                  ++i;
                } else {
                  U.push(String.fromCodePoint(65533));
                }
              }
            }
            return U.join("");
          };
          exports3.object = function(V, opts) {
            if (type(V) !== "Object") {
              throw new TypeError(_("is not an object", opts));
            }
            return V;
          };
          function convertCallbackFunction(V, opts) {
            if (typeof V !== "function") {
              throw new TypeError(_("is not a function", opts));
            }
            return V;
          }
          [
            Error,
            ArrayBuffer,
            // The IsDetachedBuffer abstract operation is not exposed in JS
            DataView,
            Int8Array,
            Int16Array,
            Int32Array,
            Uint8Array,
            Uint16Array,
            Uint32Array,
            Uint8ClampedArray,
            Float32Array,
            Float64Array
          ].forEach(function(func) {
            var name = func.name;
            var article = /^[AEIOU]/.test(name) ? "an" : "a";
            exports3[name] = function(V, opts) {
              if (!(V instanceof func)) {
                throw new TypeError(_("is not " + article + " " + name + " object", opts));
              }
              return V;
            };
          });
          exports3.ArrayBufferView = function(V, opts) {
            if (!ArrayBuffer.isView(V)) {
              throw new TypeError(_("is not a view on an ArrayBuffer object", opts));
            }
            return V;
          };
          exports3.BufferSource = function(V, opts) {
            if (!(ArrayBuffer.isView(V) || V instanceof ArrayBuffer)) {
              throw new TypeError(_("is not an ArrayBuffer object or a view on one", opts));
            }
            return V;
          };
          exports3.DOMTimeStamp = exports3["unsigned long long"];
          exports3.Function = convertCallbackFunction;
          exports3.VoidFunction = convertCallbackFunction;
        }, {}] }, {}, [1])(1);
      });
    }
  });

  // node_modules/fake-indexeddb/build/lib/structuredClone.js
  var require_structuredClone = __commonJS({
    "node_modules/fake-indexeddb/build/lib/structuredClone.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var realisticStructuredClone = require_dist();
      var errors_1 = require_errors();
      var structuredClone = function(input) {
        try {
          return realisticStructuredClone(input);
        } catch (err) {
          throw new errors_1.DataCloneError();
        }
      };
      exports.default = structuredClone;
    }
  });

  // node_modules/fake-indexeddb/build/FDBCursor.js
  var require_FDBCursor = __commonJS({
    "node_modules/fake-indexeddb/build/FDBCursor.js"(exports) {
      "use strict";
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBKeyRange_1 = require_FDBKeyRange();
      var FDBObjectStore_1 = require_FDBObjectStore();
      var cmp_1 = require_cmp();
      var errors_1 = require_errors();
      var extractKey_1 = require_extractKey();
      var structuredClone_1 = require_structuredClone();
      var valueToKey_1 = require_valueToKey();
      var getEffectiveObjectStore = function(cursor) {
        if (cursor.source instanceof FDBObjectStore_1.default) {
          return cursor.source;
        }
        return cursor.source.objectStore;
      };
      var makeKeyRange = function(range, lowers, uppers) {
        var e_1, _a, e_2, _b;
        var lower = range !== void 0 ? range.lower : void 0;
        var upper = range !== void 0 ? range.upper : void 0;
        try {
          for (var lowers_1 = __values(lowers), lowers_1_1 = lowers_1.next(); !lowers_1_1.done; lowers_1_1 = lowers_1.next()) {
            var lowerTemp = lowers_1_1.value;
            if (lowerTemp === void 0) {
              continue;
            }
            if (lower === void 0 || cmp_1.default(lower, lowerTemp) === 1) {
              lower = lowerTemp;
            }
          }
        } catch (e_1_1) {
          e_1 = { error: e_1_1 };
        } finally {
          try {
            if (lowers_1_1 && !lowers_1_1.done && (_a = lowers_1.return)) _a.call(lowers_1);
          } finally {
            if (e_1) throw e_1.error;
          }
        }
        try {
          for (var uppers_1 = __values(uppers), uppers_1_1 = uppers_1.next(); !uppers_1_1.done; uppers_1_1 = uppers_1.next()) {
            var upperTemp = uppers_1_1.value;
            if (upperTemp === void 0) {
              continue;
            }
            if (upper === void 0 || cmp_1.default(upper, upperTemp) === -1) {
              upper = upperTemp;
            }
          }
        } catch (e_2_1) {
          e_2 = { error: e_2_1 };
        } finally {
          try {
            if (uppers_1_1 && !uppers_1_1.done && (_b = uppers_1.return)) _b.call(uppers_1);
          } finally {
            if (e_2) throw e_2.error;
          }
        }
        if (lower !== void 0 && upper !== void 0) {
          return FDBKeyRange_1.default.bound(lower, upper);
        }
        if (lower !== void 0) {
          return FDBKeyRange_1.default.lowerBound(lower);
        }
        if (upper !== void 0) {
          return FDBKeyRange_1.default.upperBound(upper);
        }
      };
      var FDBCursor2 = (
        /** @class */
        (function() {
          function FDBCursor3(source, range, direction, request, keyOnly) {
            if (direction === void 0) {
              direction = "next";
            }
            if (keyOnly === void 0) {
              keyOnly = false;
            }
            this._gotValue = false;
            this._position = void 0;
            this._objectStorePosition = void 0;
            this._keyOnly = false;
            this._key = void 0;
            this._primaryKey = void 0;
            this._range = range;
            this._source = source;
            this._direction = direction;
            this._request = request;
            this._keyOnly = keyOnly;
          }
          Object.defineProperty(FDBCursor3.prototype, "source", {
            // Read only properties
            get: function() {
              return this._source;
            },
            set: function(val) {
            },
            enumerable: true,
            configurable: true
          });
          Object.defineProperty(FDBCursor3.prototype, "direction", {
            get: function() {
              return this._direction;
            },
            set: function(val) {
            },
            enumerable: true,
            configurable: true
          });
          Object.defineProperty(FDBCursor3.prototype, "key", {
            get: function() {
              return this._key;
            },
            set: function(val) {
            },
            enumerable: true,
            configurable: true
          });
          Object.defineProperty(FDBCursor3.prototype, "primaryKey", {
            get: function() {
              return this._primaryKey;
            },
            set: function(val) {
            },
            enumerable: true,
            configurable: true
          });
          FDBCursor3.prototype._iterate = function(key, primaryKey) {
            var e_3, _a, e_4, _b, e_5, _c, e_6, _d;
            var sourceIsObjectStore = this.source instanceof FDBObjectStore_1.default;
            var records = this.source instanceof FDBObjectStore_1.default ? this.source._rawObjectStore.records : this.source._rawIndex.records;
            var foundRecord;
            if (this.direction === "next") {
              var range = makeKeyRange(this._range, [key, this._position], []);
              try {
                for (var _e = __values(records.values(range)), _f = _e.next(); !_f.done; _f = _e.next()) {
                  var record = _f.value;
                  var cmpResultKey = key !== void 0 ? cmp_1.default(record.key, key) : void 0;
                  var cmpResultPosition = this._position !== void 0 ? cmp_1.default(record.key, this._position) : void 0;
                  if (key !== void 0) {
                    if (cmpResultKey === -1) {
                      continue;
                    }
                  }
                  if (primaryKey !== void 0) {
                    if (cmpResultKey === -1) {
                      continue;
                    }
                    var cmpResultPrimaryKey = cmp_1.default(record.value, primaryKey);
                    if (cmpResultKey === 0 && cmpResultPrimaryKey === -1) {
                      continue;
                    }
                  }
                  if (this._position !== void 0 && sourceIsObjectStore) {
                    if (cmpResultPosition !== 1) {
                      continue;
                    }
                  }
                  if (this._position !== void 0 && !sourceIsObjectStore) {
                    if (cmpResultPosition === -1) {
                      continue;
                    }
                    if (cmpResultPosition === 0 && cmp_1.default(record.value, this._objectStorePosition) !== 1) {
                      continue;
                    }
                  }
                  if (this._range !== void 0) {
                    if (!this._range.includes(record.key)) {
                      continue;
                    }
                  }
                  foundRecord = record;
                  break;
                }
              } catch (e_3_1) {
                e_3 = { error: e_3_1 };
              } finally {
                try {
                  if (_f && !_f.done && (_a = _e.return)) _a.call(_e);
                } finally {
                  if (e_3) throw e_3.error;
                }
              }
            } else if (this.direction === "nextunique") {
              var range = makeKeyRange(this._range, [key, this._position], []);
              try {
                for (var _g = __values(records.values(range)), _h = _g.next(); !_h.done; _h = _g.next()) {
                  var record = _h.value;
                  if (key !== void 0) {
                    if (cmp_1.default(record.key, key) === -1) {
                      continue;
                    }
                  }
                  if (this._position !== void 0) {
                    if (cmp_1.default(record.key, this._position) !== 1) {
                      continue;
                    }
                  }
                  if (this._range !== void 0) {
                    if (!this._range.includes(record.key)) {
                      continue;
                    }
                  }
                  foundRecord = record;
                  break;
                }
              } catch (e_4_1) {
                e_4 = { error: e_4_1 };
              } finally {
                try {
                  if (_h && !_h.done && (_b = _g.return)) _b.call(_g);
                } finally {
                  if (e_4) throw e_4.error;
                }
              }
            } else if (this.direction === "prev") {
              var range = makeKeyRange(this._range, [], [key, this._position]);
              try {
                for (var _j = __values(records.values(range, "prev")), _k = _j.next(); !_k.done; _k = _j.next()) {
                  var record = _k.value;
                  var cmpResultKey = key !== void 0 ? cmp_1.default(record.key, key) : void 0;
                  var cmpResultPosition = this._position !== void 0 ? cmp_1.default(record.key, this._position) : void 0;
                  if (key !== void 0) {
                    if (cmpResultKey === 1) {
                      continue;
                    }
                  }
                  if (primaryKey !== void 0) {
                    if (cmpResultKey === 1) {
                      continue;
                    }
                    var cmpResultPrimaryKey = cmp_1.default(record.value, primaryKey);
                    if (cmpResultKey === 0 && cmpResultPrimaryKey === 1) {
                      continue;
                    }
                  }
                  if (this._position !== void 0 && sourceIsObjectStore) {
                    if (cmpResultPosition !== -1) {
                      continue;
                    }
                  }
                  if (this._position !== void 0 && !sourceIsObjectStore) {
                    if (cmpResultPosition === 1) {
                      continue;
                    }
                    if (cmpResultPosition === 0 && cmp_1.default(record.value, this._objectStorePosition) !== -1) {
                      continue;
                    }
                  }
                  if (this._range !== void 0) {
                    if (!this._range.includes(record.key)) {
                      continue;
                    }
                  }
                  foundRecord = record;
                  break;
                }
              } catch (e_5_1) {
                e_5 = { error: e_5_1 };
              } finally {
                try {
                  if (_k && !_k.done && (_c = _j.return)) _c.call(_j);
                } finally {
                  if (e_5) throw e_5.error;
                }
              }
            } else if (this.direction === "prevunique") {
              var tempRecord = void 0;
              var range = makeKeyRange(this._range, [], [key, this._position]);
              try {
                for (var _l = __values(records.values(range, "prev")), _m = _l.next(); !_m.done; _m = _l.next()) {
                  var record = _m.value;
                  if (key !== void 0) {
                    if (cmp_1.default(record.key, key) === 1) {
                      continue;
                    }
                  }
                  if (this._position !== void 0) {
                    if (cmp_1.default(record.key, this._position) !== -1) {
                      continue;
                    }
                  }
                  if (this._range !== void 0) {
                    if (!this._range.includes(record.key)) {
                      continue;
                    }
                  }
                  tempRecord = record;
                  break;
                }
              } catch (e_6_1) {
                e_6 = { error: e_6_1 };
              } finally {
                try {
                  if (_m && !_m.done && (_d = _l.return)) _d.call(_l);
                } finally {
                  if (e_6) throw e_6.error;
                }
              }
              if (tempRecord) {
                foundRecord = records.get(tempRecord.key);
              }
            }
            var result;
            if (!foundRecord) {
              this._key = void 0;
              if (!sourceIsObjectStore) {
                this._objectStorePosition = void 0;
              }
              if (!this._keyOnly && this.toString() === "[object IDBCursorWithValue]") {
                this.value = void 0;
              }
              result = null;
            } else {
              this._position = foundRecord.key;
              if (!sourceIsObjectStore) {
                this._objectStorePosition = foundRecord.value;
              }
              this._key = foundRecord.key;
              if (sourceIsObjectStore) {
                this._primaryKey = structuredClone_1.default(foundRecord.key);
                if (!this._keyOnly && this.toString() === "[object IDBCursorWithValue]") {
                  this.value = structuredClone_1.default(foundRecord.value);
                }
              } else {
                this._primaryKey = structuredClone_1.default(foundRecord.value);
                if (!this._keyOnly && this.toString() === "[object IDBCursorWithValue]") {
                  if (this.source instanceof FDBObjectStore_1.default) {
                    throw new Error("This should never happen");
                  }
                  var value = this.source.objectStore._rawObjectStore.getValue(foundRecord.value);
                  this.value = structuredClone_1.default(value);
                }
              }
              this._gotValue = true;
              result = this;
            }
            return result;
          };
          FDBCursor3.prototype.update = function(value) {
            if (value === void 0) {
              throw new TypeError();
            }
            var effectiveObjectStore = getEffectiveObjectStore(this);
            var effectiveKey = this.source.hasOwnProperty("_rawIndex") ? this.primaryKey : this._position;
            var transaction = effectiveObjectStore.transaction;
            if (transaction._state !== "active") {
              throw new errors_1.TransactionInactiveError();
            }
            if (transaction.mode === "readonly") {
              throw new errors_1.ReadOnlyError();
            }
            if (effectiveObjectStore._rawObjectStore.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!(this.source instanceof FDBObjectStore_1.default) && this.source._rawIndex.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!this._gotValue || !this.hasOwnProperty("value")) {
              throw new errors_1.InvalidStateError();
            }
            var clone = structuredClone_1.default(value);
            if (effectiveObjectStore.keyPath !== null) {
              var tempKey = void 0;
              try {
                tempKey = extractKey_1.default(effectiveObjectStore.keyPath, clone);
              } catch (err) {
              }
              if (cmp_1.default(tempKey, effectiveKey) !== 0) {
                throw new errors_1.DataError();
              }
            }
            var record = {
              key: effectiveKey,
              value: clone
            };
            return transaction._execRequestAsync({
              operation: effectiveObjectStore._rawObjectStore.storeRecord.bind(effectiveObjectStore._rawObjectStore, record, false, transaction._rollbackLog),
              source: this
            });
          };
          FDBCursor3.prototype.advance = function(count) {
            var _this = this;
            if (!Number.isInteger(count) || count <= 0) {
              throw new TypeError();
            }
            var effectiveObjectStore = getEffectiveObjectStore(this);
            var transaction = effectiveObjectStore.transaction;
            if (transaction._state !== "active") {
              throw new errors_1.TransactionInactiveError();
            }
            if (effectiveObjectStore._rawObjectStore.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!(this.source instanceof FDBObjectStore_1.default) && this.source._rawIndex.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!this._gotValue) {
              throw new errors_1.InvalidStateError();
            }
            if (this._request) {
              this._request.readyState = "pending";
            }
            transaction._execRequestAsync({
              operation: function() {
                var result;
                for (var i = 0; i < count; i++) {
                  result = _this._iterate();
                  if (!result) {
                    break;
                  }
                }
                return result;
              },
              request: this._request,
              source: this.source
            });
            this._gotValue = false;
          };
          FDBCursor3.prototype.continue = function(key) {
            var effectiveObjectStore = getEffectiveObjectStore(this);
            var transaction = effectiveObjectStore.transaction;
            if (transaction._state !== "active") {
              throw new errors_1.TransactionInactiveError();
            }
            if (effectiveObjectStore._rawObjectStore.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!(this.source instanceof FDBObjectStore_1.default) && this.source._rawIndex.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!this._gotValue) {
              throw new errors_1.InvalidStateError();
            }
            if (key !== void 0) {
              key = valueToKey_1.default(key);
              var cmpResult = cmp_1.default(key, this._position);
              if (cmpResult <= 0 && (this.direction === "next" || this.direction === "nextunique") || cmpResult >= 0 && (this.direction === "prev" || this.direction === "prevunique")) {
                throw new errors_1.DataError();
              }
            }
            if (this._request) {
              this._request.readyState = "pending";
            }
            transaction._execRequestAsync({
              operation: this._iterate.bind(this, key),
              request: this._request,
              source: this.source
            });
            this._gotValue = false;
          };
          FDBCursor3.prototype.continuePrimaryKey = function(key, primaryKey) {
            var effectiveObjectStore = getEffectiveObjectStore(this);
            var transaction = effectiveObjectStore.transaction;
            if (transaction._state !== "active") {
              throw new errors_1.TransactionInactiveError();
            }
            if (effectiveObjectStore._rawObjectStore.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!(this.source instanceof FDBObjectStore_1.default) && this.source._rawIndex.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (this.source instanceof FDBObjectStore_1.default || this.direction !== "next" && this.direction !== "prev") {
              throw new errors_1.InvalidAccessError();
            }
            if (!this._gotValue) {
              throw new errors_1.InvalidStateError();
            }
            if (key === void 0 || primaryKey === void 0) {
              throw new errors_1.DataError();
            }
            key = valueToKey_1.default(key);
            var cmpResult = cmp_1.default(key, this._position);
            if (cmpResult === -1 && this.direction === "next" || cmpResult === 1 && this.direction === "prev") {
              throw new errors_1.DataError();
            }
            var cmpResult2 = cmp_1.default(primaryKey, this._objectStorePosition);
            if (cmpResult === 0) {
              if (cmpResult2 <= 0 && this.direction === "next" || cmpResult2 >= 0 && this.direction === "prev") {
                throw new errors_1.DataError();
              }
            }
            if (this._request) {
              this._request.readyState = "pending";
            }
            transaction._execRequestAsync({
              operation: this._iterate.bind(this, key, primaryKey),
              request: this._request,
              source: this.source
            });
            this._gotValue = false;
          };
          FDBCursor3.prototype.delete = function() {
            var effectiveObjectStore = getEffectiveObjectStore(this);
            var effectiveKey = this.source.hasOwnProperty("_rawIndex") ? this.primaryKey : this._position;
            var transaction = effectiveObjectStore.transaction;
            if (transaction._state !== "active") {
              throw new errors_1.TransactionInactiveError();
            }
            if (transaction.mode === "readonly") {
              throw new errors_1.ReadOnlyError();
            }
            if (effectiveObjectStore._rawObjectStore.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!(this.source instanceof FDBObjectStore_1.default) && this.source._rawIndex.deleted) {
              throw new errors_1.InvalidStateError();
            }
            if (!this._gotValue || !this.hasOwnProperty("value")) {
              throw new errors_1.InvalidStateError();
            }
            return transaction._execRequestAsync({
              operation: effectiveObjectStore._rawObjectStore.deleteRecord.bind(effectiveObjectStore._rawObjectStore, effectiveKey, transaction._rollbackLog),
              source: this
            });
          };
          FDBCursor3.prototype.toString = function() {
            return "[object IDBCursor]";
          };
          return FDBCursor3;
        })()
      );
      exports.default = FDBCursor2;
    }
  });

  // node_modules/fake-indexeddb/build/FDBCursorWithValue.js
  var require_FDBCursorWithValue = __commonJS({
    "node_modules/fake-indexeddb/build/FDBCursorWithValue.js"(exports) {
      "use strict";
      var __extends = exports && exports.__extends || /* @__PURE__ */ (function() {
        var extendStatics = function(d, b) {
          extendStatics = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(d2, b2) {
            d2.__proto__ = b2;
          } || function(d2, b2) {
            for (var p in b2) if (b2.hasOwnProperty(p)) d2[p] = b2[p];
          };
          return extendStatics(d, b);
        };
        return function(d, b) {
          extendStatics(d, b);
          function __() {
            this.constructor = d;
          }
          d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
        };
      })();
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBCursor_1 = require_FDBCursor();
      var FDBCursorWithValue2 = (
        /** @class */
        (function(_super) {
          __extends(FDBCursorWithValue3, _super);
          function FDBCursorWithValue3(source, range, direction, request) {
            var _this = _super.call(this, source, range, direction, request) || this;
            _this.value = void 0;
            return _this;
          }
          FDBCursorWithValue3.prototype.toString = function() {
            return "[object IDBCursorWithValue]";
          };
          return FDBCursorWithValue3;
        })(FDBCursor_1.default)
      );
      exports.default = FDBCursorWithValue2;
    }
  });

  // node_modules/fake-indexeddb/build/lib/FakeEventTarget.js
  var require_FakeEventTarget = __commonJS({
    "node_modules/fake-indexeddb/build/lib/FakeEventTarget.js"(exports) {
      "use strict";
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var errors_1 = require_errors();
      var stopped = function(event, listener) {
        return event.immediatePropagationStopped || event.eventPhase === event.CAPTURING_PHASE && listener.capture === false || event.eventPhase === event.BUBBLING_PHASE && listener.capture === true;
      };
      var invokeEventListeners = function(event, obj) {
        var e_1, _a;
        event.currentTarget = obj;
        try {
          for (var _b = __values(obj.listeners.slice()), _c = _b.next(); !_c.done; _c = _b.next()) {
            var listener = _c.value;
            if (event.type !== listener.type || stopped(event, listener)) {
              continue;
            }
            listener.callback.call(event.currentTarget, event);
          }
        } catch (e_1_1) {
          e_1 = { error: e_1_1 };
        } finally {
          try {
            if (_c && !_c.done && (_a = _b.return)) _a.call(_b);
          } finally {
            if (e_1) throw e_1.error;
          }
        }
        var typeToProp = {
          abort: "onabort",
          blocked: "onblocked",
          complete: "oncomplete",
          error: "onerror",
          success: "onsuccess",
          upgradeneeded: "onupgradeneeded",
          versionchange: "onversionchange"
        };
        var prop = typeToProp[event.type];
        if (prop === void 0) {
          throw new Error('Unknown event type: "' + event.type + '"');
        }
        var callback = event.currentTarget[prop];
        if (callback) {
          var listener = {
            callback,
            capture: false,
            type: event.type
          };
          if (!stopped(event, listener)) {
            listener.callback.call(event.currentTarget, event);
          }
        }
      };
      var FakeEventTarget = (
        /** @class */
        (function() {
          function FakeEventTarget2() {
            this.listeners = [];
          }
          FakeEventTarget2.prototype.addEventListener = function(type, callback, capture) {
            if (capture === void 0) {
              capture = false;
            }
            this.listeners.push({
              callback,
              capture,
              type
            });
          };
          FakeEventTarget2.prototype.removeEventListener = function(type, callback, capture) {
            if (capture === void 0) {
              capture = false;
            }
            var i = this.listeners.findIndex(function(listener) {
              return listener.type === type && listener.callback === callback && listener.capture === capture;
            });
            this.listeners.splice(i, 1);
          };
          FakeEventTarget2.prototype.dispatchEvent = function(event) {
            var e_2, _a, e_3, _b;
            if (event.dispatched || !event.initialized) {
              throw new errors_1.InvalidStateError("The object is in an invalid state.");
            }
            event.isTrusted = false;
            event.dispatched = true;
            event.target = this;
            event.eventPhase = event.CAPTURING_PHASE;
            try {
              for (var _c = __values(event.eventPath), _d = _c.next(); !_d.done; _d = _c.next()) {
                var obj = _d.value;
                if (!event.propagationStopped) {
                  invokeEventListeners(event, obj);
                }
              }
            } catch (e_2_1) {
              e_2 = { error: e_2_1 };
            } finally {
              try {
                if (_d && !_d.done && (_a = _c.return)) _a.call(_c);
              } finally {
                if (e_2) throw e_2.error;
              }
            }
            event.eventPhase = event.AT_TARGET;
            if (!event.propagationStopped) {
              invokeEventListeners(event, event.target);
            }
            if (event.bubbles) {
              event.eventPath.reverse();
              event.eventPhase = event.BUBBLING_PHASE;
              try {
                for (var _e = __values(event.eventPath), _f = _e.next(); !_f.done; _f = _e.next()) {
                  var obj = _f.value;
                  if (!event.propagationStopped) {
                    invokeEventListeners(event, obj);
                  }
                }
              } catch (e_3_1) {
                e_3 = { error: e_3_1 };
              } finally {
                try {
                  if (_f && !_f.done && (_b = _e.return)) _b.call(_e);
                } finally {
                  if (e_3) throw e_3.error;
                }
              }
            }
            event.dispatched = false;
            event.eventPhase = event.NONE;
            event.currentTarget = null;
            if (event.canceled) {
              return false;
            }
            return true;
          };
          return FakeEventTarget2;
        })()
      );
      exports.default = FakeEventTarget;
    }
  });

  // node_modules/fake-indexeddb/build/FDBRequest.js
  var require_FDBRequest = __commonJS({
    "node_modules/fake-indexeddb/build/FDBRequest.js"(exports) {
      "use strict";
      var __extends = exports && exports.__extends || /* @__PURE__ */ (function() {
        var extendStatics = function(d, b) {
          extendStatics = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(d2, b2) {
            d2.__proto__ = b2;
          } || function(d2, b2) {
            for (var p in b2) if (b2.hasOwnProperty(p)) d2[p] = b2[p];
          };
          return extendStatics(d, b);
        };
        return function(d, b) {
          extendStatics(d, b);
          function __() {
            this.constructor = d;
          }
          d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
        };
      })();
      Object.defineProperty(exports, "__esModule", { value: true });
      var errors_1 = require_errors();
      var FakeEventTarget_1 = require_FakeEventTarget();
      var FDBRequest2 = (
        /** @class */
        (function(_super) {
          __extends(FDBRequest3, _super);
          function FDBRequest3() {
            var _this = _super !== null && _super.apply(this, arguments) || this;
            _this._result = null;
            _this._error = null;
            _this.source = null;
            _this.transaction = null;
            _this.readyState = "pending";
            _this.onsuccess = null;
            _this.onerror = null;
            return _this;
          }
          Object.defineProperty(FDBRequest3.prototype, "error", {
            get: function() {
              if (this.readyState === "pending") {
                throw new errors_1.InvalidStateError();
              }
              return this._error;
            },
            set: function(value) {
              this._error = value;
            },
            enumerable: true,
            configurable: true
          });
          Object.defineProperty(FDBRequest3.prototype, "result", {
            get: function() {
              if (this.readyState === "pending") {
                throw new errors_1.InvalidStateError();
              }
              return this._result;
            },
            set: function(value) {
              this._result = value;
            },
            enumerable: true,
            configurable: true
          });
          FDBRequest3.prototype.toString = function() {
            return "[object IDBRequest]";
          };
          return FDBRequest3;
        })(FakeEventTarget_1.default)
      );
      exports.default = FDBRequest2;
    }
  });

  // node_modules/fake-indexeddb/build/lib/enforceRange.js
  var require_enforceRange = __commonJS({
    "node_modules/fake-indexeddb/build/lib/enforceRange.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var enforceRange = function(num, type) {
        var min = 0;
        var max = type === "unsigned long" ? 4294967295 : 9007199254740991;
        if (isNaN(num) || num < min || num > max) {
          throw new TypeError();
        }
        if (num >= 0) {
          return Math.floor(num);
        }
      };
      exports.default = enforceRange;
    }
  });

  // node_modules/fake-indexeddb/build/lib/fakeDOMStringList.js
  var require_fakeDOMStringList = __commonJS({
    "node_modules/fake-indexeddb/build/lib/fakeDOMStringList.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var fakeDOMStringList = function(arr) {
        var arr2 = arr.slice();
        Object.defineProperty(arr2, "contains", {
          // tslint:disable-next-line object-literal-shorthand
          value: function(value) {
            return arr2.indexOf(value) >= 0;
          }
        });
        Object.defineProperty(arr2, "item", {
          // tslint:disable-next-line object-literal-shorthand
          value: function(i) {
            return arr2[i];
          }
        });
        return arr2;
      };
      exports.default = fakeDOMStringList;
    }
  });

  // node_modules/fake-indexeddb/build/lib/valueToKeyRange.js
  var require_valueToKeyRange = __commonJS({
    "node_modules/fake-indexeddb/build/lib/valueToKeyRange.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBKeyRange_1 = require_FDBKeyRange();
      var errors_1 = require_errors();
      var valueToKey_1 = require_valueToKey();
      var valueToKeyRange = function(value, nullDisallowedFlag) {
        if (nullDisallowedFlag === void 0) {
          nullDisallowedFlag = false;
        }
        if (value instanceof FDBKeyRange_1.default) {
          return value;
        }
        if (value === null || value === void 0) {
          if (nullDisallowedFlag) {
            throw new errors_1.DataError();
          }
          return new FDBKeyRange_1.default(void 0, void 0, false, false);
        }
        var key = valueToKey_1.default(value);
        return FDBKeyRange_1.default.only(key);
      };
      exports.default = valueToKeyRange;
    }
  });

  // node_modules/fake-indexeddb/build/FDBIndex.js
  var require_FDBIndex = __commonJS({
    "node_modules/fake-indexeddb/build/FDBIndex.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBCursor_1 = require_FDBCursor();
      var FDBCursorWithValue_1 = require_FDBCursorWithValue();
      var FDBKeyRange_1 = require_FDBKeyRange();
      var FDBRequest_1 = require_FDBRequest();
      var enforceRange_1 = require_enforceRange();
      var errors_1 = require_errors();
      var fakeDOMStringList_1 = require_fakeDOMStringList();
      var valueToKey_1 = require_valueToKey();
      var valueToKeyRange_1 = require_valueToKeyRange();
      var confirmActiveTransaction = function(index) {
        if (index._rawIndex.deleted || index.objectStore._rawObjectStore.deleted) {
          throw new errors_1.InvalidStateError();
        }
        if (index.objectStore.transaction._state !== "active") {
          throw new errors_1.TransactionInactiveError();
        }
      };
      var FDBIndex2 = (
        /** @class */
        (function() {
          function FDBIndex3(objectStore, rawIndex) {
            this._rawIndex = rawIndex;
            this._name = rawIndex.name;
            this.objectStore = objectStore;
            this.keyPath = rawIndex.keyPath;
            this.multiEntry = rawIndex.multiEntry;
            this.unique = rawIndex.unique;
          }
          Object.defineProperty(FDBIndex3.prototype, "name", {
            get: function() {
              return this._name;
            },
            // https://w3c.github.io/IndexedDB/#dom-idbindex-name
            set: function(name) {
              var _this = this;
              var transaction = this.objectStore.transaction;
              if (!transaction.db._runningVersionchangeTransaction) {
                throw new errors_1.InvalidStateError();
              }
              if (transaction._state !== "active") {
                throw new errors_1.TransactionInactiveError();
              }
              if (this._rawIndex.deleted || this.objectStore._rawObjectStore.deleted) {
                throw new errors_1.InvalidStateError();
              }
              name = String(name);
              if (name === this._name) {
                return;
              }
              if (this.objectStore.indexNames.indexOf(name) >= 0) {
                throw new errors_1.ConstraintError();
              }
              var oldName = this._name;
              var oldIndexNames = this.objectStore.indexNames.slice();
              this._name = name;
              this._rawIndex.name = name;
              this.objectStore._indexesCache.delete(oldName);
              this.objectStore._indexesCache.set(name, this);
              this.objectStore._rawObjectStore.rawIndexes.delete(oldName);
              this.objectStore._rawObjectStore.rawIndexes.set(name, this._rawIndex);
              this.objectStore.indexNames = fakeDOMStringList_1.default(Array.from(this.objectStore._rawObjectStore.rawIndexes.keys()).filter(function(indexName) {
                var index = _this.objectStore._rawObjectStore.rawIndexes.get(indexName);
                return index && !index.deleted;
              })).sort();
              transaction._rollbackLog.push(function() {
                _this._name = oldName;
                _this._rawIndex.name = oldName;
                _this.objectStore._indexesCache.delete(name);
                _this.objectStore._indexesCache.set(oldName, _this);
                _this.objectStore._rawObjectStore.rawIndexes.delete(name);
                _this.objectStore._rawObjectStore.rawIndexes.set(oldName, _this._rawIndex);
                _this.objectStore.indexNames = fakeDOMStringList_1.default(oldIndexNames);
              });
            },
            enumerable: true,
            configurable: true
          });
          FDBIndex3.prototype.openCursor = function(range, direction) {
            confirmActiveTransaction(this);
            if (range === null) {
              range = void 0;
            }
            if (range !== void 0 && !(range instanceof FDBKeyRange_1.default)) {
              range = FDBKeyRange_1.default.only(valueToKey_1.default(range));
            }
            var request = new FDBRequest_1.default();
            request.source = this;
            request.transaction = this.objectStore.transaction;
            var cursor = new FDBCursorWithValue_1.default(this, range, direction, request);
            return this.objectStore.transaction._execRequestAsync({
              operation: cursor._iterate.bind(cursor),
              request,
              source: this
            });
          };
          FDBIndex3.prototype.openKeyCursor = function(range, direction) {
            confirmActiveTransaction(this);
            if (range === null) {
              range = void 0;
            }
            if (range !== void 0 && !(range instanceof FDBKeyRange_1.default)) {
              range = FDBKeyRange_1.default.only(valueToKey_1.default(range));
            }
            var request = new FDBRequest_1.default();
            request.source = this;
            request.transaction = this.objectStore.transaction;
            var cursor = new FDBCursor_1.default(this, range, direction, request, true);
            return this.objectStore.transaction._execRequestAsync({
              operation: cursor._iterate.bind(cursor),
              request,
              source: this
            });
          };
          FDBIndex3.prototype.get = function(key) {
            confirmActiveTransaction(this);
            if (!(key instanceof FDBKeyRange_1.default)) {
              key = valueToKey_1.default(key);
            }
            return this.objectStore.transaction._execRequestAsync({
              operation: this._rawIndex.getValue.bind(this._rawIndex, key),
              source: this
            });
          };
          FDBIndex3.prototype.getAll = function(query, count) {
            if (arguments.length > 1 && count !== void 0) {
              count = enforceRange_1.default(count, "unsigned long");
            }
            confirmActiveTransaction(this);
            var range = valueToKeyRange_1.default(query);
            return this.objectStore.transaction._execRequestAsync({
              operation: this._rawIndex.getAllValues.bind(this._rawIndex, range, count),
              source: this
            });
          };
          FDBIndex3.prototype.getKey = function(key) {
            confirmActiveTransaction(this);
            if (!(key instanceof FDBKeyRange_1.default)) {
              key = valueToKey_1.default(key);
            }
            return this.objectStore.transaction._execRequestAsync({
              operation: this._rawIndex.getKey.bind(this._rawIndex, key),
              source: this
            });
          };
          FDBIndex3.prototype.getAllKeys = function(query, count) {
            if (arguments.length > 1 && count !== void 0) {
              count = enforceRange_1.default(count, "unsigned long");
            }
            confirmActiveTransaction(this);
            var range = valueToKeyRange_1.default(query);
            return this.objectStore.transaction._execRequestAsync({
              operation: this._rawIndex.getAllKeys.bind(this._rawIndex, range, count),
              source: this
            });
          };
          FDBIndex3.prototype.count = function(key) {
            var _this = this;
            confirmActiveTransaction(this);
            if (key === null) {
              key = void 0;
            }
            if (key !== void 0 && !(key instanceof FDBKeyRange_1.default)) {
              key = FDBKeyRange_1.default.only(valueToKey_1.default(key));
            }
            return this.objectStore.transaction._execRequestAsync({
              operation: function() {
                var count = 0;
                var cursor = new FDBCursor_1.default(_this, key);
                while (cursor._iterate() !== null) {
                  count += 1;
                }
                return count;
              },
              source: this
            });
          };
          FDBIndex3.prototype.toString = function() {
            return "[object IDBIndex]";
          };
          return FDBIndex3;
        })()
      );
      exports.default = FDBIndex2;
    }
  });

  // node_modules/fake-indexeddb/build/lib/canInjectKey.js
  var require_canInjectKey = __commonJS({
    "node_modules/fake-indexeddb/build/lib/canInjectKey.js"(exports) {
      "use strict";
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var canInjectKey = function(keyPath, value) {
        var e_1, _a;
        if (Array.isArray(keyPath)) {
          throw new Error("The key paths used in this section are always strings and never sequences, since it is not possible to create a object store which has a key generator and also has a key path that is a sequence.");
        }
        var identifiers = keyPath.split(".");
        if (identifiers.length === 0) {
          throw new Error("Assert: identifiers is not empty");
        }
        identifiers.pop();
        try {
          for (var identifiers_1 = __values(identifiers), identifiers_1_1 = identifiers_1.next(); !identifiers_1_1.done; identifiers_1_1 = identifiers_1.next()) {
            var identifier = identifiers_1_1.value;
            if (typeof value !== "object" && !Array.isArray(value)) {
              return false;
            }
            var hop = value.hasOwnProperty(identifier);
            if (!hop) {
              return true;
            }
            value = value[identifier];
          }
        } catch (e_1_1) {
          e_1 = { error: e_1_1 };
        } finally {
          try {
            if (identifiers_1_1 && !identifiers_1_1.done && (_a = identifiers_1.return)) _a.call(identifiers_1);
          } finally {
            if (e_1) throw e_1.error;
          }
        }
        return typeof value === "object" || Array.isArray(value);
      };
      exports.default = canInjectKey;
    }
  });

  // node_modules/fake-indexeddb/build/lib/binarySearch.js
  var require_binarySearch = __commonJS({
    "node_modules/fake-indexeddb/build/lib/binarySearch.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var cmp_1 = require_cmp();
      function binarySearch(records, key) {
        var low = 0;
        var high = records.length;
        var mid;
        while (low < high) {
          mid = low + high >>> 1;
          if (cmp_1.default(records[mid].key, key) < 0) {
            low = mid + 1;
          } else {
            high = mid;
          }
        }
        return low;
      }
      function getIndexByKey(records, key) {
        var idx = binarySearch(records, key);
        var record = records[idx];
        if (record && cmp_1.default(record.key, key) === 0) {
          return idx;
        }
        return -1;
      }
      exports.getIndexByKey = getIndexByKey;
      function getByKey(records, key) {
        var idx = getIndexByKey(records, key);
        return records[idx];
      }
      exports.getByKey = getByKey;
      function getIndexByKeyRange(records, keyRange) {
        var lowerIdx = typeof keyRange.lower === "undefined" ? 0 : binarySearch(records, keyRange.lower);
        var upperIdx = typeof keyRange.upper === "undefined" ? records.length - 1 : binarySearch(records, keyRange.upper);
        for (var i = lowerIdx; i <= upperIdx; i++) {
          var record = records[i];
          if (record && keyRange.includes(record.key)) {
            return i;
          }
        }
        return -1;
      }
      exports.getIndexByKeyRange = getIndexByKeyRange;
      function getByKeyRange(records, keyRange) {
        var idx = getIndexByKeyRange(records, keyRange);
        return records[idx];
      }
      exports.getByKeyRange = getByKeyRange;
      function getIndexByKeyGTE(records, key) {
        var idx = binarySearch(records, key);
        var record = records[idx];
        if (record && cmp_1.default(record.key, key) >= 0) {
          return idx;
        }
        return -1;
      }
      exports.getIndexByKeyGTE = getIndexByKeyGTE;
    }
  });

  // node_modules/fake-indexeddb/build/lib/RecordStore.js
  var require_RecordStore = __commonJS({
    "node_modules/fake-indexeddb/build/lib/RecordStore.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBKeyRange_1 = require_FDBKeyRange();
      var binarySearch_1 = require_binarySearch();
      var cmp_1 = require_cmp();
      var RecordStore = (
        /** @class */
        (function() {
          function RecordStore2() {
            this.records = [];
          }
          RecordStore2.prototype.get = function(key) {
            if (key instanceof FDBKeyRange_1.default) {
              return binarySearch_1.getByKeyRange(this.records, key);
            }
            return binarySearch_1.getByKey(this.records, key);
          };
          RecordStore2.prototype.add = function(newRecord) {
            var i;
            if (this.records.length === 0) {
              i = 0;
            } else {
              i = binarySearch_1.getIndexByKeyGTE(this.records, newRecord.key);
              if (i === -1) {
                i = this.records.length;
              } else {
                while (i < this.records.length && cmp_1.default(this.records[i].key, newRecord.key) === 0) {
                  if (cmp_1.default(this.records[i].value, newRecord.value) !== -1) {
                    break;
                  }
                  i += 1;
                }
              }
            }
            this.records.splice(i, 0, newRecord);
          };
          RecordStore2.prototype.delete = function(key) {
            var deletedRecords = [];
            var isRange = key instanceof FDBKeyRange_1.default;
            while (true) {
              var idx = isRange ? binarySearch_1.getIndexByKeyRange(this.records, key) : binarySearch_1.getIndexByKey(this.records, key);
              if (idx === -1) {
                break;
              }
              deletedRecords.push(this.records[idx]);
              this.records.splice(idx, 1);
            }
            return deletedRecords;
          };
          RecordStore2.prototype.deleteByValue = function(key) {
            var range = key instanceof FDBKeyRange_1.default ? key : FDBKeyRange_1.default.only(key);
            var deletedRecords = [];
            this.records = this.records.filter(function(record) {
              var shouldDelete = range.includes(record.value);
              if (shouldDelete) {
                deletedRecords.push(record);
              }
              return !shouldDelete;
            });
            return deletedRecords;
          };
          RecordStore2.prototype.clear = function() {
            var deletedRecords = this.records.slice();
            this.records = [];
            return deletedRecords;
          };
          RecordStore2.prototype.values = function(range, direction) {
            var _a;
            var _this = this;
            if (direction === void 0) {
              direction = "next";
            }
            return _a = {}, _a[Symbol.iterator] = function() {
              var i;
              if (direction === "next") {
                i = 0;
                if (range !== void 0 && range.lower !== void 0) {
                  while (_this.records[i] !== void 0) {
                    var cmpResult = cmp_1.default(_this.records[i].key, range.lower);
                    if (cmpResult === 1 || cmpResult === 0 && !range.lowerOpen) {
                      break;
                    }
                    i += 1;
                  }
                }
              } else {
                i = _this.records.length - 1;
                if (range !== void 0 && range.upper !== void 0) {
                  while (_this.records[i] !== void 0) {
                    var cmpResult = cmp_1.default(_this.records[i].key, range.upper);
                    if (cmpResult === -1 || cmpResult === 0 && !range.upperOpen) {
                      break;
                    }
                    i -= 1;
                  }
                }
              }
              return {
                next: function() {
                  var done;
                  var value;
                  if (direction === "next") {
                    value = _this.records[i];
                    done = i >= _this.records.length;
                    i += 1;
                    if (!done && range !== void 0 && range.upper !== void 0) {
                      var cmpResult2 = cmp_1.default(value.key, range.upper);
                      done = cmpResult2 === 1 || cmpResult2 === 0 && range.upperOpen;
                      if (done) {
                        value = void 0;
                      }
                    }
                  } else {
                    value = _this.records[i];
                    done = i < 0;
                    i -= 1;
                    if (!done && range !== void 0 && range.lower !== void 0) {
                      var cmpResult2 = cmp_1.default(value.key, range.lower);
                      done = cmpResult2 === -1 || cmpResult2 === 0 && range.lowerOpen;
                      if (done) {
                        value = void 0;
                      }
                    }
                  }
                  return {
                    done,
                    value
                  };
                }
              };
            }, _a;
          };
          return RecordStore2;
        })()
      );
      exports.default = RecordStore;
    }
  });

  // node_modules/fake-indexeddb/build/lib/Index.js
  var require_Index = __commonJS({
    "node_modules/fake-indexeddb/build/lib/Index.js"(exports) {
      "use strict";
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var errors_1 = require_errors();
      var extractKey_1 = require_extractKey();
      var RecordStore_1 = require_RecordStore();
      var structuredClone_1 = require_structuredClone();
      var valueToKey_1 = require_valueToKey();
      var Index = (
        /** @class */
        (function() {
          function Index2(rawObjectStore, name, keyPath, multiEntry, unique) {
            this.deleted = false;
            this.initialized = false;
            this.records = new RecordStore_1.default();
            this.rawObjectStore = rawObjectStore;
            this.name = name;
            this.keyPath = keyPath;
            this.multiEntry = multiEntry;
            this.unique = unique;
          }
          Index2.prototype.getKey = function(key) {
            var record = this.records.get(key);
            return record !== void 0 ? record.value : void 0;
          };
          Index2.prototype.getAllKeys = function(range, count) {
            var e_1, _a;
            if (count === void 0 || count === 0) {
              count = Infinity;
            }
            var records = [];
            try {
              for (var _b = __values(this.records.values(range)), _c = _b.next(); !_c.done; _c = _b.next()) {
                var record = _c.value;
                records.push(structuredClone_1.default(record.value));
                if (records.length >= count) {
                  break;
                }
              }
            } catch (e_1_1) {
              e_1 = { error: e_1_1 };
            } finally {
              try {
                if (_c && !_c.done && (_a = _b.return)) _a.call(_b);
              } finally {
                if (e_1) throw e_1.error;
              }
            }
            return records;
          };
          Index2.prototype.getValue = function(key) {
            var record = this.records.get(key);
            return record !== void 0 ? this.rawObjectStore.getValue(record.value) : void 0;
          };
          Index2.prototype.getAllValues = function(range, count) {
            var e_2, _a;
            if (count === void 0 || count === 0) {
              count = Infinity;
            }
            var records = [];
            try {
              for (var _b = __values(this.records.values(range)), _c = _b.next(); !_c.done; _c = _b.next()) {
                var record = _c.value;
                records.push(this.rawObjectStore.getValue(record.value));
                if (records.length >= count) {
                  break;
                }
              }
            } catch (e_2_1) {
              e_2 = { error: e_2_1 };
            } finally {
              try {
                if (_c && !_c.done && (_a = _b.return)) _a.call(_b);
              } finally {
                if (e_2) throw e_2.error;
              }
            }
            return records;
          };
          Index2.prototype.storeRecord = function(newRecord) {
            var e_3, _a, e_4, _b, e_5, _c;
            var indexKey;
            try {
              indexKey = extractKey_1.default(this.keyPath, newRecord.value);
            } catch (err) {
              if (err.name === "DataError") {
                return;
              }
              throw err;
            }
            if (!this.multiEntry || !Array.isArray(indexKey)) {
              try {
                valueToKey_1.default(indexKey);
              } catch (e) {
                return;
              }
            } else {
              var keep = [];
              try {
                for (var indexKey_1 = __values(indexKey), indexKey_1_1 = indexKey_1.next(); !indexKey_1_1.done; indexKey_1_1 = indexKey_1.next()) {
                  var part = indexKey_1_1.value;
                  if (keep.indexOf(part) < 0) {
                    try {
                      keep.push(valueToKey_1.default(part));
                    } catch (err) {
                    }
                  }
                }
              } catch (e_3_1) {
                e_3 = { error: e_3_1 };
              } finally {
                try {
                  if (indexKey_1_1 && !indexKey_1_1.done && (_a = indexKey_1.return)) _a.call(indexKey_1);
                } finally {
                  if (e_3) throw e_3.error;
                }
              }
              indexKey = keep;
            }
            if (!this.multiEntry || !Array.isArray(indexKey)) {
              if (this.unique) {
                var existingRecord = this.records.get(indexKey);
                if (existingRecord) {
                  throw new errors_1.ConstraintError();
                }
              }
            } else {
              if (this.unique) {
                try {
                  for (var indexKey_2 = __values(indexKey), indexKey_2_1 = indexKey_2.next(); !indexKey_2_1.done; indexKey_2_1 = indexKey_2.next()) {
                    var individualIndexKey = indexKey_2_1.value;
                    var existingRecord = this.records.get(individualIndexKey);
                    if (existingRecord) {
                      throw new errors_1.ConstraintError();
                    }
                  }
                } catch (e_4_1) {
                  e_4 = { error: e_4_1 };
                } finally {
                  try {
                    if (indexKey_2_1 && !indexKey_2_1.done && (_b = indexKey_2.return)) _b.call(indexKey_2);
                  } finally {
                    if (e_4) throw e_4.error;
                  }
                }
              }
            }
            if (!this.multiEntry || !Array.isArray(indexKey)) {
              this.records.add({
                key: indexKey,
                value: newRecord.key
              });
            } else {
              try {
                for (var indexKey_3 = __values(indexKey), indexKey_3_1 = indexKey_3.next(); !indexKey_3_1.done; indexKey_3_1 = indexKey_3.next()) {
                  var individualIndexKey = indexKey_3_1.value;
                  this.records.add({
                    key: individualIndexKey,
                    value: newRecord.key
                  });
                }
              } catch (e_5_1) {
                e_5 = { error: e_5_1 };
              } finally {
                try {
                  if (indexKey_3_1 && !indexKey_3_1.done && (_c = indexKey_3.return)) _c.call(indexKey_3);
                } finally {
                  if (e_5) throw e_5.error;
                }
              }
            }
          };
          Index2.prototype.initialize = function(transaction) {
            var _this = this;
            if (this.initialized) {
              throw new Error("Index already initialized");
            }
            transaction._execRequestAsync({
              operation: function() {
                var e_6, _a;
                try {
                  try {
                    for (var _b = __values(_this.rawObjectStore.records.values()), _c = _b.next(); !_c.done; _c = _b.next()) {
                      var record = _c.value;
                      _this.storeRecord(record);
                    }
                  } catch (e_6_1) {
                    e_6 = { error: e_6_1 };
                  } finally {
                    try {
                      if (_c && !_c.done && (_a = _b.return)) _a.call(_b);
                    } finally {
                      if (e_6) throw e_6.error;
                    }
                  }
                  _this.initialized = true;
                } catch (err) {
                  transaction._abort(err.name);
                }
              },
              source: null
            });
          };
          return Index2;
        })()
      );
      exports.default = Index;
    }
  });

  // node_modules/fake-indexeddb/build/lib/validateKeyPath.js
  var require_validateKeyPath = __commonJS({
    "node_modules/fake-indexeddb/build/lib/validateKeyPath.js"(exports) {
      "use strict";
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var validateKeyPath = function(keyPath, parent) {
        var e_1, _a, e_2, _b;
        if (keyPath !== void 0 && keyPath !== null && typeof keyPath !== "string" && keyPath.toString && (parent === "array" || !Array.isArray(keyPath))) {
          keyPath = keyPath.toString();
        }
        if (typeof keyPath === "string") {
          if (keyPath === "" && parent !== "string") {
            return;
          }
          try {
            var validIdentifierRegex = /^(?:[\$A-Z_a-z\xAA\xB5\xBA\xC0-\xD6\xD8-\xF6\xF8-\u02C1\u02C6-\u02D1\u02E0-\u02E4\u02EC\u02EE\u0370-\u0374\u0376\u0377\u037A-\u037D\u037F\u0386\u0388-\u038A\u038C\u038E-\u03A1\u03A3-\u03F5\u03F7-\u0481\u048A-\u052F\u0531-\u0556\u0559\u0561-\u0587\u05D0-\u05EA\u05F0-\u05F2\u0620-\u064A\u066E\u066F\u0671-\u06D3\u06D5\u06E5\u06E6\u06EE\u06EF\u06FA-\u06FC\u06FF\u0710\u0712-\u072F\u074D-\u07A5\u07B1\u07CA-\u07EA\u07F4\u07F5\u07FA\u0800-\u0815\u081A\u0824\u0828\u0840-\u0858\u08A0-\u08B2\u0904-\u0939\u093D\u0950\u0958-\u0961\u0971-\u0980\u0985-\u098C\u098F\u0990\u0993-\u09A8\u09AA-\u09B0\u09B2\u09B6-\u09B9\u09BD\u09CE\u09DC\u09DD\u09DF-\u09E1\u09F0\u09F1\u0A05-\u0A0A\u0A0F\u0A10\u0A13-\u0A28\u0A2A-\u0A30\u0A32\u0A33\u0A35\u0A36\u0A38\u0A39\u0A59-\u0A5C\u0A5E\u0A72-\u0A74\u0A85-\u0A8D\u0A8F-\u0A91\u0A93-\u0AA8\u0AAA-\u0AB0\u0AB2\u0AB3\u0AB5-\u0AB9\u0ABD\u0AD0\u0AE0\u0AE1\u0B05-\u0B0C\u0B0F\u0B10\u0B13-\u0B28\u0B2A-\u0B30\u0B32\u0B33\u0B35-\u0B39\u0B3D\u0B5C\u0B5D\u0B5F-\u0B61\u0B71\u0B83\u0B85-\u0B8A\u0B8E-\u0B90\u0B92-\u0B95\u0B99\u0B9A\u0B9C\u0B9E\u0B9F\u0BA3\u0BA4\u0BA8-\u0BAA\u0BAE-\u0BB9\u0BD0\u0C05-\u0C0C\u0C0E-\u0C10\u0C12-\u0C28\u0C2A-\u0C39\u0C3D\u0C58\u0C59\u0C60\u0C61\u0C85-\u0C8C\u0C8E-\u0C90\u0C92-\u0CA8\u0CAA-\u0CB3\u0CB5-\u0CB9\u0CBD\u0CDE\u0CE0\u0CE1\u0CF1\u0CF2\u0D05-\u0D0C\u0D0E-\u0D10\u0D12-\u0D3A\u0D3D\u0D4E\u0D60\u0D61\u0D7A-\u0D7F\u0D85-\u0D96\u0D9A-\u0DB1\u0DB3-\u0DBB\u0DBD\u0DC0-\u0DC6\u0E01-\u0E30\u0E32\u0E33\u0E40-\u0E46\u0E81\u0E82\u0E84\u0E87\u0E88\u0E8A\u0E8D\u0E94-\u0E97\u0E99-\u0E9F\u0EA1-\u0EA3\u0EA5\u0EA7\u0EAA\u0EAB\u0EAD-\u0EB0\u0EB2\u0EB3\u0EBD\u0EC0-\u0EC4\u0EC6\u0EDC-\u0EDF\u0F00\u0F40-\u0F47\u0F49-\u0F6C\u0F88-\u0F8C\u1000-\u102A\u103F\u1050-\u1055\u105A-\u105D\u1061\u1065\u1066\u106E-\u1070\u1075-\u1081\u108E\u10A0-\u10C5\u10C7\u10CD\u10D0-\u10FA\u10FC-\u1248\u124A-\u124D\u1250-\u1256\u1258\u125A-\u125D\u1260-\u1288\u128A-\u128D\u1290-\u12B0\u12B2-\u12B5\u12B8-\u12BE\u12C0\u12C2-\u12C5\u12C8-\u12D6\u12D8-\u1310\u1312-\u1315\u1318-\u135A\u1380-\u138F\u13A0-\u13F4\u1401-\u166C\u166F-\u167F\u1681-\u169A\u16A0-\u16EA\u16EE-\u16F8\u1700-\u170C\u170E-\u1711\u1720-\u1731\u1740-\u1751\u1760-\u176C\u176E-\u1770\u1780-\u17B3\u17D7\u17DC\u1820-\u1877\u1880-\u18A8\u18AA\u18B0-\u18F5\u1900-\u191E\u1950-\u196D\u1970-\u1974\u1980-\u19AB\u19C1-\u19C7\u1A00-\u1A16\u1A20-\u1A54\u1AA7\u1B05-\u1B33\u1B45-\u1B4B\u1B83-\u1BA0\u1BAE\u1BAF\u1BBA-\u1BE5\u1C00-\u1C23\u1C4D-\u1C4F\u1C5A-\u1C7D\u1CE9-\u1CEC\u1CEE-\u1CF1\u1CF5\u1CF6\u1D00-\u1DBF\u1E00-\u1F15\u1F18-\u1F1D\u1F20-\u1F45\u1F48-\u1F4D\u1F50-\u1F57\u1F59\u1F5B\u1F5D\u1F5F-\u1F7D\u1F80-\u1FB4\u1FB6-\u1FBC\u1FBE\u1FC2-\u1FC4\u1FC6-\u1FCC\u1FD0-\u1FD3\u1FD6-\u1FDB\u1FE0-\u1FEC\u1FF2-\u1FF4\u1FF6-\u1FFC\u2071\u207F\u2090-\u209C\u2102\u2107\u210A-\u2113\u2115\u2119-\u211D\u2124\u2126\u2128\u212A-\u212D\u212F-\u2139\u213C-\u213F\u2145-\u2149\u214E\u2160-\u2188\u2C00-\u2C2E\u2C30-\u2C5E\u2C60-\u2CE4\u2CEB-\u2CEE\u2CF2\u2CF3\u2D00-\u2D25\u2D27\u2D2D\u2D30-\u2D67\u2D6F\u2D80-\u2D96\u2DA0-\u2DA6\u2DA8-\u2DAE\u2DB0-\u2DB6\u2DB8-\u2DBE\u2DC0-\u2DC6\u2DC8-\u2DCE\u2DD0-\u2DD6\u2DD8-\u2DDE\u2E2F\u3005-\u3007\u3021-\u3029\u3031-\u3035\u3038-\u303C\u3041-\u3096\u309D-\u309F\u30A1-\u30FA\u30FC-\u30FF\u3105-\u312D\u3131-\u318E\u31A0-\u31BA\u31F0-\u31FF\u3400-\u4DB5\u4E00-\u9FCC\uA000-\uA48C\uA4D0-\uA4FD\uA500-\uA60C\uA610-\uA61F\uA62A\uA62B\uA640-\uA66E\uA67F-\uA69D\uA6A0-\uA6EF\uA717-\uA71F\uA722-\uA788\uA78B-\uA78E\uA790-\uA7AD\uA7B0\uA7B1\uA7F7-\uA801\uA803-\uA805\uA807-\uA80A\uA80C-\uA822\uA840-\uA873\uA882-\uA8B3\uA8F2-\uA8F7\uA8FB\uA90A-\uA925\uA930-\uA946\uA960-\uA97C\uA984-\uA9B2\uA9CF\uA9E0-\uA9E4\uA9E6-\uA9EF\uA9FA-\uA9FE\uAA00-\uAA28\uAA40-\uAA42\uAA44-\uAA4B\uAA60-\uAA76\uAA7A\uAA7E-\uAAAF\uAAB1\uAAB5\uAAB6\uAAB9-\uAABD\uAAC0\uAAC2\uAADB-\uAADD\uAAE0-\uAAEA\uAAF2-\uAAF4\uAB01-\uAB06\uAB09-\uAB0E\uAB11-\uAB16\uAB20-\uAB26\uAB28-\uAB2E\uAB30-\uAB5A\uAB5C-\uAB5F\uAB64\uAB65\uABC0-\uABE2\uAC00-\uD7A3\uD7B0-\uD7C6\uD7CB-\uD7FB\uF900-\uFA6D\uFA70-\uFAD9\uFB00-\uFB06\uFB13-\uFB17\uFB1D\uFB1F-\uFB28\uFB2A-\uFB36\uFB38-\uFB3C\uFB3E\uFB40\uFB41\uFB43\uFB44\uFB46-\uFBB1\uFBD3-\uFD3D\uFD50-\uFD8F\uFD92-\uFDC7\uFDF0-\uFDFB\uFE70-\uFE74\uFE76-\uFEFC\uFF21-\uFF3A\uFF41-\uFF5A\uFF66-\uFFBE\uFFC2-\uFFC7\uFFCA-\uFFCF\uFFD2-\uFFD7\uFFDA-\uFFDC])(?:[\$0-9A-Z_a-z\xAA\xB5\xBA\xC0-\xD6\xD8-\xF6\xF8-\u02C1\u02C6-\u02D1\u02E0-\u02E4\u02EC\u02EE\u0300-\u0374\u0376\u0377\u037A-\u037D\u037F\u0386\u0388-\u038A\u038C\u038E-\u03A1\u03A3-\u03F5\u03F7-\u0481\u0483-\u0487\u048A-\u052F\u0531-\u0556\u0559\u0561-\u0587\u0591-\u05BD\u05BF\u05C1\u05C2\u05C4\u05C5\u05C7\u05D0-\u05EA\u05F0-\u05F2\u0610-\u061A\u0620-\u0669\u066E-\u06D3\u06D5-\u06DC\u06DF-\u06E8\u06EA-\u06FC\u06FF\u0710-\u074A\u074D-\u07B1\u07C0-\u07F5\u07FA\u0800-\u082D\u0840-\u085B\u08A0-\u08B2\u08E4-\u0963\u0966-\u096F\u0971-\u0983\u0985-\u098C\u098F\u0990\u0993-\u09A8\u09AA-\u09B0\u09B2\u09B6-\u09B9\u09BC-\u09C4\u09C7\u09C8\u09CB-\u09CE\u09D7\u09DC\u09DD\u09DF-\u09E3\u09E6-\u09F1\u0A01-\u0A03\u0A05-\u0A0A\u0A0F\u0A10\u0A13-\u0A28\u0A2A-\u0A30\u0A32\u0A33\u0A35\u0A36\u0A38\u0A39\u0A3C\u0A3E-\u0A42\u0A47\u0A48\u0A4B-\u0A4D\u0A51\u0A59-\u0A5C\u0A5E\u0A66-\u0A75\u0A81-\u0A83\u0A85-\u0A8D\u0A8F-\u0A91\u0A93-\u0AA8\u0AAA-\u0AB0\u0AB2\u0AB3\u0AB5-\u0AB9\u0ABC-\u0AC5\u0AC7-\u0AC9\u0ACB-\u0ACD\u0AD0\u0AE0-\u0AE3\u0AE6-\u0AEF\u0B01-\u0B03\u0B05-\u0B0C\u0B0F\u0B10\u0B13-\u0B28\u0B2A-\u0B30\u0B32\u0B33\u0B35-\u0B39\u0B3C-\u0B44\u0B47\u0B48\u0B4B-\u0B4D\u0B56\u0B57\u0B5C\u0B5D\u0B5F-\u0B63\u0B66-\u0B6F\u0B71\u0B82\u0B83\u0B85-\u0B8A\u0B8E-\u0B90\u0B92-\u0B95\u0B99\u0B9A\u0B9C\u0B9E\u0B9F\u0BA3\u0BA4\u0BA8-\u0BAA\u0BAE-\u0BB9\u0BBE-\u0BC2\u0BC6-\u0BC8\u0BCA-\u0BCD\u0BD0\u0BD7\u0BE6-\u0BEF\u0C00-\u0C03\u0C05-\u0C0C\u0C0E-\u0C10\u0C12-\u0C28\u0C2A-\u0C39\u0C3D-\u0C44\u0C46-\u0C48\u0C4A-\u0C4D\u0C55\u0C56\u0C58\u0C59\u0C60-\u0C63\u0C66-\u0C6F\u0C81-\u0C83\u0C85-\u0C8C\u0C8E-\u0C90\u0C92-\u0CA8\u0CAA-\u0CB3\u0CB5-\u0CB9\u0CBC-\u0CC4\u0CC6-\u0CC8\u0CCA-\u0CCD\u0CD5\u0CD6\u0CDE\u0CE0-\u0CE3\u0CE6-\u0CEF\u0CF1\u0CF2\u0D01-\u0D03\u0D05-\u0D0C\u0D0E-\u0D10\u0D12-\u0D3A\u0D3D-\u0D44\u0D46-\u0D48\u0D4A-\u0D4E\u0D57\u0D60-\u0D63\u0D66-\u0D6F\u0D7A-\u0D7F\u0D82\u0D83\u0D85-\u0D96\u0D9A-\u0DB1\u0DB3-\u0DBB\u0DBD\u0DC0-\u0DC6\u0DCA\u0DCF-\u0DD4\u0DD6\u0DD8-\u0DDF\u0DE6-\u0DEF\u0DF2\u0DF3\u0E01-\u0E3A\u0E40-\u0E4E\u0E50-\u0E59\u0E81\u0E82\u0E84\u0E87\u0E88\u0E8A\u0E8D\u0E94-\u0E97\u0E99-\u0E9F\u0EA1-\u0EA3\u0EA5\u0EA7\u0EAA\u0EAB\u0EAD-\u0EB9\u0EBB-\u0EBD\u0EC0-\u0EC4\u0EC6\u0EC8-\u0ECD\u0ED0-\u0ED9\u0EDC-\u0EDF\u0F00\u0F18\u0F19\u0F20-\u0F29\u0F35\u0F37\u0F39\u0F3E-\u0F47\u0F49-\u0F6C\u0F71-\u0F84\u0F86-\u0F97\u0F99-\u0FBC\u0FC6\u1000-\u1049\u1050-\u109D\u10A0-\u10C5\u10C7\u10CD\u10D0-\u10FA\u10FC-\u1248\u124A-\u124D\u1250-\u1256\u1258\u125A-\u125D\u1260-\u1288\u128A-\u128D\u1290-\u12B0\u12B2-\u12B5\u12B8-\u12BE\u12C0\u12C2-\u12C5\u12C8-\u12D6\u12D8-\u1310\u1312-\u1315\u1318-\u135A\u135D-\u135F\u1380-\u138F\u13A0-\u13F4\u1401-\u166C\u166F-\u167F\u1681-\u169A\u16A0-\u16EA\u16EE-\u16F8\u1700-\u170C\u170E-\u1714\u1720-\u1734\u1740-\u1753\u1760-\u176C\u176E-\u1770\u1772\u1773\u1780-\u17D3\u17D7\u17DC\u17DD\u17E0-\u17E9\u180B-\u180D\u1810-\u1819\u1820-\u1877\u1880-\u18AA\u18B0-\u18F5\u1900-\u191E\u1920-\u192B\u1930-\u193B\u1946-\u196D\u1970-\u1974\u1980-\u19AB\u19B0-\u19C9\u19D0-\u19D9\u1A00-\u1A1B\u1A20-\u1A5E\u1A60-\u1A7C\u1A7F-\u1A89\u1A90-\u1A99\u1AA7\u1AB0-\u1ABD\u1B00-\u1B4B\u1B50-\u1B59\u1B6B-\u1B73\u1B80-\u1BF3\u1C00-\u1C37\u1C40-\u1C49\u1C4D-\u1C7D\u1CD0-\u1CD2\u1CD4-\u1CF6\u1CF8\u1CF9\u1D00-\u1DF5\u1DFC-\u1F15\u1F18-\u1F1D\u1F20-\u1F45\u1F48-\u1F4D\u1F50-\u1F57\u1F59\u1F5B\u1F5D\u1F5F-\u1F7D\u1F80-\u1FB4\u1FB6-\u1FBC\u1FBE\u1FC2-\u1FC4\u1FC6-\u1FCC\u1FD0-\u1FD3\u1FD6-\u1FDB\u1FE0-\u1FEC\u1FF2-\u1FF4\u1FF6-\u1FFC\u200C\u200D\u203F\u2040\u2054\u2071\u207F\u2090-\u209C\u20D0-\u20DC\u20E1\u20E5-\u20F0\u2102\u2107\u210A-\u2113\u2115\u2119-\u211D\u2124\u2126\u2128\u212A-\u212D\u212F-\u2139\u213C-\u213F\u2145-\u2149\u214E\u2160-\u2188\u2C00-\u2C2E\u2C30-\u2C5E\u2C60-\u2CE4\u2CEB-\u2CF3\u2D00-\u2D25\u2D27\u2D2D\u2D30-\u2D67\u2D6F\u2D7F-\u2D96\u2DA0-\u2DA6\u2DA8-\u2DAE\u2DB0-\u2DB6\u2DB8-\u2DBE\u2DC0-\u2DC6\u2DC8-\u2DCE\u2DD0-\u2DD6\u2DD8-\u2DDE\u2DE0-\u2DFF\u2E2F\u3005-\u3007\u3021-\u302F\u3031-\u3035\u3038-\u303C\u3041-\u3096\u3099\u309A\u309D-\u309F\u30A1-\u30FA\u30FC-\u30FF\u3105-\u312D\u3131-\u318E\u31A0-\u31BA\u31F0-\u31FF\u3400-\u4DB5\u4E00-\u9FCC\uA000-\uA48C\uA4D0-\uA4FD\uA500-\uA60C\uA610-\uA62B\uA640-\uA66F\uA674-\uA67D\uA67F-\uA69D\uA69F-\uA6F1\uA717-\uA71F\uA722-\uA788\uA78B-\uA78E\uA790-\uA7AD\uA7B0\uA7B1\uA7F7-\uA827\uA840-\uA873\uA880-\uA8C4\uA8D0-\uA8D9\uA8E0-\uA8F7\uA8FB\uA900-\uA92D\uA930-\uA953\uA960-\uA97C\uA980-\uA9C0\uA9CF-\uA9D9\uA9E0-\uA9FE\uAA00-\uAA36\uAA40-\uAA4D\uAA50-\uAA59\uAA60-\uAA76\uAA7A-\uAAC2\uAADB-\uAADD\uAAE0-\uAAEF\uAAF2-\uAAF6\uAB01-\uAB06\uAB09-\uAB0E\uAB11-\uAB16\uAB20-\uAB26\uAB28-\uAB2E\uAB30-\uAB5A\uAB5C-\uAB5F\uAB64\uAB65\uABC0-\uABEA\uABEC\uABED\uABF0-\uABF9\uAC00-\uD7A3\uD7B0-\uD7C6\uD7CB-\uD7FB\uF900-\uFA6D\uFA70-\uFAD9\uFB00-\uFB06\uFB13-\uFB17\uFB1D-\uFB28\uFB2A-\uFB36\uFB38-\uFB3C\uFB3E\uFB40\uFB41\uFB43\uFB44\uFB46-\uFBB1\uFBD3-\uFD3D\uFD50-\uFD8F\uFD92-\uFDC7\uFDF0-\uFDFB\uFE00-\uFE0F\uFE20-\uFE2D\uFE33\uFE34\uFE4D-\uFE4F\uFE70-\uFE74\uFE76-\uFEFC\uFF10-\uFF19\uFF21-\uFF3A\uFF3F\uFF41-\uFF5A\uFF66-\uFFBE\uFFC2-\uFFC7\uFFCA-\uFFCF\uFFD2-\uFFD7\uFFDA-\uFFDC])*$/;
            if (keyPath.length >= 1 && validIdentifierRegex.test(keyPath)) {
              return;
            }
          } catch (err) {
            throw new SyntaxError(err.message);
          }
          if (keyPath.indexOf(" ") >= 0) {
            throw new SyntaxError("The keypath argument contains an invalid key path (no spaces allowed).");
          }
        }
        if (Array.isArray(keyPath) && keyPath.length > 0) {
          if (parent) {
            throw new SyntaxError("The keypath argument contains an invalid key path (nested arrays).");
          }
          try {
            for (var keyPath_1 = __values(keyPath), keyPath_1_1 = keyPath_1.next(); !keyPath_1_1.done; keyPath_1_1 = keyPath_1.next()) {
              var part = keyPath_1_1.value;
              validateKeyPath(part, "array");
            }
          } catch (e_1_1) {
            e_1 = { error: e_1_1 };
          } finally {
            try {
              if (keyPath_1_1 && !keyPath_1_1.done && (_a = keyPath_1.return)) _a.call(keyPath_1);
            } finally {
              if (e_1) throw e_1.error;
            }
          }
          return;
        } else if (typeof keyPath === "string" && keyPath.indexOf(".") >= 0) {
          keyPath = keyPath.split(".");
          try {
            for (var keyPath_2 = __values(keyPath), keyPath_2_1 = keyPath_2.next(); !keyPath_2_1.done; keyPath_2_1 = keyPath_2.next()) {
              var part = keyPath_2_1.value;
              validateKeyPath(part, "string");
            }
          } catch (e_2_1) {
            e_2 = { error: e_2_1 };
          } finally {
            try {
              if (keyPath_2_1 && !keyPath_2_1.done && (_b = keyPath_2.return)) _b.call(keyPath_2);
            } finally {
              if (e_2) throw e_2.error;
            }
          }
          return;
        }
        throw new SyntaxError();
      };
      exports.default = validateKeyPath;
    }
  });

  // node_modules/fake-indexeddb/build/FDBObjectStore.js
  var require_FDBObjectStore = __commonJS({
    "node_modules/fake-indexeddb/build/FDBObjectStore.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBCursor_1 = require_FDBCursor();
      var FDBCursorWithValue_1 = require_FDBCursorWithValue();
      var FDBIndex_1 = require_FDBIndex();
      var FDBKeyRange_1 = require_FDBKeyRange();
      var FDBRequest_1 = require_FDBRequest();
      var canInjectKey_1 = require_canInjectKey();
      var enforceRange_1 = require_enforceRange();
      var errors_1 = require_errors();
      var extractKey_1 = require_extractKey();
      var fakeDOMStringList_1 = require_fakeDOMStringList();
      var Index_1 = require_Index();
      var structuredClone_1 = require_structuredClone();
      var validateKeyPath_1 = require_validateKeyPath();
      var valueToKey_1 = require_valueToKey();
      var valueToKeyRange_1 = require_valueToKeyRange();
      var confirmActiveTransaction = function(objectStore) {
        if (objectStore._rawObjectStore.deleted) {
          throw new errors_1.InvalidStateError();
        }
        if (objectStore.transaction._state !== "active") {
          throw new errors_1.TransactionInactiveError();
        }
      };
      var buildRecordAddPut = function(objectStore, value, key) {
        confirmActiveTransaction(objectStore);
        if (objectStore.transaction.mode === "readonly") {
          throw new errors_1.ReadOnlyError();
        }
        if (objectStore.keyPath !== null) {
          if (key !== void 0) {
            throw new errors_1.DataError();
          }
        }
        var clone = structuredClone_1.default(value);
        if (objectStore.keyPath !== null) {
          var tempKey = extractKey_1.default(objectStore.keyPath, clone);
          if (tempKey !== void 0) {
            valueToKey_1.default(tempKey);
          } else {
            if (!objectStore._rawObjectStore.keyGenerator) {
              throw new errors_1.DataError();
            } else if (!canInjectKey_1.default(objectStore.keyPath, clone)) {
              throw new errors_1.DataError();
            }
          }
        }
        if (objectStore.keyPath === null && objectStore._rawObjectStore.keyGenerator === null && key === void 0) {
          throw new errors_1.DataError();
        }
        if (key !== void 0) {
          key = valueToKey_1.default(key);
        }
        return {
          key,
          value: clone
        };
      };
      var FDBObjectStore2 = (
        /** @class */
        (function() {
          function FDBObjectStore3(transaction, rawObjectStore) {
            this._indexesCache = /* @__PURE__ */ new Map();
            this._rawObjectStore = rawObjectStore;
            this._name = rawObjectStore.name;
            this.keyPath = rawObjectStore.keyPath;
            this.autoIncrement = rawObjectStore.autoIncrement;
            this.transaction = transaction;
            this.indexNames = fakeDOMStringList_1.default(Array.from(rawObjectStore.rawIndexes.keys())).sort();
          }
          Object.defineProperty(FDBObjectStore3.prototype, "name", {
            get: function() {
              return this._name;
            },
            // http://w3c.github.io/IndexedDB/#dom-idbobjectstore-name
            set: function(name) {
              var _this = this;
              var transaction = this.transaction;
              if (!transaction.db._runningVersionchangeTransaction) {
                throw new errors_1.InvalidStateError();
              }
              confirmActiveTransaction(this);
              name = String(name);
              if (name === this._name) {
                return;
              }
              if (this._rawObjectStore.rawDatabase.rawObjectStores.has(name)) {
                throw new errors_1.ConstraintError();
              }
              var oldName = this._name;
              var oldObjectStoreNames = transaction.db.objectStoreNames.slice();
              this._name = name;
              this._rawObjectStore.name = name;
              this.transaction._objectStoresCache.delete(oldName);
              this.transaction._objectStoresCache.set(name, this);
              this._rawObjectStore.rawDatabase.rawObjectStores.delete(oldName);
              this._rawObjectStore.rawDatabase.rawObjectStores.set(name, this._rawObjectStore);
              transaction.db.objectStoreNames = fakeDOMStringList_1.default(Array.from(this._rawObjectStore.rawDatabase.rawObjectStores.keys()).filter(function(objectStoreName) {
                var objectStore = _this._rawObjectStore.rawDatabase.rawObjectStores.get(objectStoreName);
                return objectStore && !objectStore.deleted;
              })).sort();
              var oldScope = new Set(transaction._scope);
              var oldTransactionObjectStoreNames = transaction.objectStoreNames.slice();
              this.transaction._scope.delete(oldName);
              transaction._scope.add(name);
              transaction.objectStoreNames = fakeDOMStringList_1.default(Array.from(transaction._scope).sort());
              transaction._rollbackLog.push(function() {
                _this._name = oldName;
                _this._rawObjectStore.name = oldName;
                _this.transaction._objectStoresCache.delete(name);
                _this.transaction._objectStoresCache.set(oldName, _this);
                _this._rawObjectStore.rawDatabase.rawObjectStores.delete(name);
                _this._rawObjectStore.rawDatabase.rawObjectStores.set(oldName, _this._rawObjectStore);
                transaction.db.objectStoreNames = fakeDOMStringList_1.default(oldObjectStoreNames);
                transaction._scope = oldScope;
                transaction.objectStoreNames = fakeDOMStringList_1.default(oldTransactionObjectStoreNames);
              });
            },
            enumerable: true,
            configurable: true
          });
          FDBObjectStore3.prototype.put = function(value, key) {
            if (arguments.length === 0) {
              throw new TypeError();
            }
            var record = buildRecordAddPut(this, value, key);
            return this.transaction._execRequestAsync({
              operation: this._rawObjectStore.storeRecord.bind(this._rawObjectStore, record, false, this.transaction._rollbackLog),
              source: this
            });
          };
          FDBObjectStore3.prototype.add = function(value, key) {
            if (arguments.length === 0) {
              throw new TypeError();
            }
            var record = buildRecordAddPut(this, value, key);
            return this.transaction._execRequestAsync({
              operation: this._rawObjectStore.storeRecord.bind(this._rawObjectStore, record, true, this.transaction._rollbackLog),
              source: this
            });
          };
          FDBObjectStore3.prototype.delete = function(key) {
            if (arguments.length === 0) {
              throw new TypeError();
            }
            confirmActiveTransaction(this);
            if (this.transaction.mode === "readonly") {
              throw new errors_1.ReadOnlyError();
            }
            if (!(key instanceof FDBKeyRange_1.default)) {
              key = valueToKey_1.default(key);
            }
            return this.transaction._execRequestAsync({
              operation: this._rawObjectStore.deleteRecord.bind(this._rawObjectStore, key, this.transaction._rollbackLog),
              source: this
            });
          };
          FDBObjectStore3.prototype.get = function(key) {
            if (arguments.length === 0) {
              throw new TypeError();
            }
            confirmActiveTransaction(this);
            if (!(key instanceof FDBKeyRange_1.default)) {
              key = valueToKey_1.default(key);
            }
            return this.transaction._execRequestAsync({
              operation: this._rawObjectStore.getValue.bind(this._rawObjectStore, key),
              source: this
            });
          };
          FDBObjectStore3.prototype.getAll = function(query, count) {
            if (arguments.length > 1 && count !== void 0) {
              count = enforceRange_1.default(count, "unsigned long");
            }
            confirmActiveTransaction(this);
            var range = valueToKeyRange_1.default(query);
            return this.transaction._execRequestAsync({
              operation: this._rawObjectStore.getAllValues.bind(this._rawObjectStore, range, count),
              source: this
            });
          };
          FDBObjectStore3.prototype.getKey = function(key) {
            if (arguments.length === 0) {
              throw new TypeError();
            }
            confirmActiveTransaction(this);
            if (!(key instanceof FDBKeyRange_1.default)) {
              key = valueToKey_1.default(key);
            }
            return this.transaction._execRequestAsync({
              operation: this._rawObjectStore.getKey.bind(this._rawObjectStore, key),
              source: this
            });
          };
          FDBObjectStore3.prototype.getAllKeys = function(query, count) {
            if (arguments.length > 1 && count !== void 0) {
              count = enforceRange_1.default(count, "unsigned long");
            }
            confirmActiveTransaction(this);
            var range = valueToKeyRange_1.default(query);
            return this.transaction._execRequestAsync({
              operation: this._rawObjectStore.getAllKeys.bind(this._rawObjectStore, range, count),
              source: this
            });
          };
          FDBObjectStore3.prototype.clear = function() {
            confirmActiveTransaction(this);
            if (this.transaction.mode === "readonly") {
              throw new errors_1.ReadOnlyError();
            }
            return this.transaction._execRequestAsync({
              operation: this._rawObjectStore.clear.bind(this._rawObjectStore, this.transaction._rollbackLog),
              source: this
            });
          };
          FDBObjectStore3.prototype.openCursor = function(range, direction) {
            confirmActiveTransaction(this);
            if (range === null) {
              range = void 0;
            }
            if (range !== void 0 && !(range instanceof FDBKeyRange_1.default)) {
              range = FDBKeyRange_1.default.only(valueToKey_1.default(range));
            }
            var request = new FDBRequest_1.default();
            request.source = this;
            request.transaction = this.transaction;
            var cursor = new FDBCursorWithValue_1.default(this, range, direction, request);
            return this.transaction._execRequestAsync({
              operation: cursor._iterate.bind(cursor),
              request,
              source: this
            });
          };
          FDBObjectStore3.prototype.openKeyCursor = function(range, direction) {
            confirmActiveTransaction(this);
            if (range === null) {
              range = void 0;
            }
            if (range !== void 0 && !(range instanceof FDBKeyRange_1.default)) {
              range = FDBKeyRange_1.default.only(valueToKey_1.default(range));
            }
            var request = new FDBRequest_1.default();
            request.source = this;
            request.transaction = this.transaction;
            var cursor = new FDBCursor_1.default(this, range, direction, request, true);
            return this.transaction._execRequestAsync({
              operation: cursor._iterate.bind(cursor),
              request,
              source: this
            });
          };
          FDBObjectStore3.prototype.createIndex = function(name, keyPath, optionalParameters) {
            var _this = this;
            if (optionalParameters === void 0) {
              optionalParameters = {};
            }
            if (arguments.length < 2) {
              throw new TypeError();
            }
            var multiEntry = optionalParameters.multiEntry !== void 0 ? optionalParameters.multiEntry : false;
            var unique = optionalParameters.unique !== void 0 ? optionalParameters.unique : false;
            if (this.transaction.mode !== "versionchange") {
              throw new errors_1.InvalidStateError();
            }
            confirmActiveTransaction(this);
            if (this.indexNames.indexOf(name) >= 0) {
              throw new errors_1.ConstraintError();
            }
            validateKeyPath_1.default(keyPath);
            if (Array.isArray(keyPath) && multiEntry) {
              throw new errors_1.InvalidAccessError();
            }
            var indexNames = this.indexNames.slice();
            this.transaction._rollbackLog.push(function() {
              var index2 = _this._rawObjectStore.rawIndexes.get(name);
              if (index2) {
                index2.deleted = true;
              }
              _this.indexNames = fakeDOMStringList_1.default(indexNames);
              _this._rawObjectStore.rawIndexes.delete(name);
            });
            var index = new Index_1.default(this._rawObjectStore, name, keyPath, multiEntry, unique);
            this.indexNames.push(name);
            this.indexNames.sort();
            this._rawObjectStore.rawIndexes.set(name, index);
            index.initialize(this.transaction);
            return new FDBIndex_1.default(this, index);
          };
          FDBObjectStore3.prototype.index = function(name) {
            if (arguments.length === 0) {
              throw new TypeError();
            }
            if (this._rawObjectStore.deleted || this.transaction._state === "finished") {
              throw new errors_1.InvalidStateError();
            }
            var index = this._indexesCache.get(name);
            if (index !== void 0) {
              return index;
            }
            var rawIndex = this._rawObjectStore.rawIndexes.get(name);
            if (this.indexNames.indexOf(name) < 0 || rawIndex === void 0) {
              throw new errors_1.NotFoundError();
            }
            var index2 = new FDBIndex_1.default(this, rawIndex);
            this._indexesCache.set(name, index2);
            return index2;
          };
          FDBObjectStore3.prototype.deleteIndex = function(name) {
            var _this = this;
            if (arguments.length === 0) {
              throw new TypeError();
            }
            if (this.transaction.mode !== "versionchange") {
              throw new errors_1.InvalidStateError();
            }
            confirmActiveTransaction(this);
            var rawIndex = this._rawObjectStore.rawIndexes.get(name);
            if (rawIndex === void 0) {
              throw new errors_1.NotFoundError();
            }
            this.transaction._rollbackLog.push(function() {
              rawIndex.deleted = false;
              _this._rawObjectStore.rawIndexes.set(name, rawIndex);
              _this.indexNames.push(name);
              _this.indexNames.sort();
            });
            this.indexNames = fakeDOMStringList_1.default(this.indexNames.filter(function(indexName) {
              return indexName !== name;
            }));
            rawIndex.deleted = true;
            this.transaction._execRequestAsync({
              operation: function() {
                var rawIndex2 = _this._rawObjectStore.rawIndexes.get(name);
                if (rawIndex === rawIndex2) {
                  _this._rawObjectStore.rawIndexes.delete(name);
                }
              },
              source: this
            });
          };
          FDBObjectStore3.prototype.count = function(key) {
            var _this = this;
            confirmActiveTransaction(this);
            if (key === null) {
              key = void 0;
            }
            if (key !== void 0 && !(key instanceof FDBKeyRange_1.default)) {
              key = FDBKeyRange_1.default.only(valueToKey_1.default(key));
            }
            return this.transaction._execRequestAsync({
              operation: function() {
                var count = 0;
                var cursor = new FDBCursor_1.default(_this, key);
                while (cursor._iterate() !== null) {
                  count += 1;
                }
                return count;
              },
              source: this
            });
          };
          FDBObjectStore3.prototype.toString = function() {
            return "[object IDBObjectStore]";
          };
          return FDBObjectStore3;
        })()
      );
      exports.default = FDBObjectStore2;
    }
  });

  // node_modules/fake-indexeddb/build/lib/FakeEvent.js
  var require_FakeEvent = __commonJS({
    "node_modules/fake-indexeddb/build/lib/FakeEvent.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var Event = (
        /** @class */
        (function() {
          function Event2(type, eventInitDict) {
            if (eventInitDict === void 0) {
              eventInitDict = {};
            }
            this.eventPath = [];
            this.NONE = 0;
            this.CAPTURING_PHASE = 1;
            this.AT_TARGET = 2;
            this.BUBBLING_PHASE = 3;
            this.propagationStopped = false;
            this.immediatePropagationStopped = false;
            this.canceled = false;
            this.initialized = true;
            this.dispatched = false;
            this.target = null;
            this.currentTarget = null;
            this.eventPhase = 0;
            this.defaultPrevented = false;
            this.isTrusted = false;
            this.timeStamp = Date.now();
            this.type = type;
            this.bubbles = eventInitDict.bubbles !== void 0 ? eventInitDict.bubbles : false;
            this.cancelable = eventInitDict.cancelable !== void 0 ? eventInitDict.cancelable : false;
          }
          Event2.prototype.preventDefault = function() {
            if (this.cancelable) {
              this.canceled = true;
            }
          };
          Event2.prototype.stopPropagation = function() {
            this.propagationStopped = true;
          };
          Event2.prototype.stopImmediatePropagation = function() {
            this.propagationStopped = true;
            this.immediatePropagationStopped = true;
          };
          return Event2;
        })()
      );
      exports.default = Event;
    }
  });

  // node_modules/fake-indexeddb/build/lib/scheduling.js
  var require_scheduling = __commonJS({
    "node_modules/fake-indexeddb/build/lib/scheduling.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      function getSetImmediateFromJsdom() {
        if (typeof navigator !== "undefined" && /jsdom/.test(navigator.userAgent)) {
          var outerRealmFunctionConstructor = Node.constructor;
          return new outerRealmFunctionConstructor("return setImmediate")();
        } else {
          return void 0;
        }
      }
      var getGlobal = function() {
        if (typeof globalThis !== "undefined") {
          return globalThis;
        }
        if (typeof globalThis !== "undefined") {
          return globalThis;
        }
        if (typeof self !== "undefined") {
          return self;
        }
        if (typeof window !== "undefined") {
          return window;
        }
        throw new Error("unable to locate global object");
      };
      var globals = getGlobal();
      exports.queueTask = globals.setImmediate || getSetImmediateFromJsdom() || (function(fn) {
        return setTimeout(fn, 0);
      });
    }
  });

  // node_modules/fake-indexeddb/build/FDBTransaction.js
  var require_FDBTransaction = __commonJS({
    "node_modules/fake-indexeddb/build/FDBTransaction.js"(exports) {
      "use strict";
      var __extends = exports && exports.__extends || /* @__PURE__ */ (function() {
        var extendStatics = function(d, b) {
          extendStatics = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(d2, b2) {
            d2.__proto__ = b2;
          } || function(d2, b2) {
            for (var p in b2) if (b2.hasOwnProperty(p)) d2[p] = b2[p];
          };
          return extendStatics(d, b);
        };
        return function(d, b) {
          extendStatics(d, b);
          function __() {
            this.constructor = d;
          }
          d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
        };
      })();
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBObjectStore_1 = require_FDBObjectStore();
      var FDBRequest_1 = require_FDBRequest();
      var errors_1 = require_errors();
      var fakeDOMStringList_1 = require_fakeDOMStringList();
      var FakeEvent_1 = require_FakeEvent();
      var FakeEventTarget_1 = require_FakeEventTarget();
      var scheduling_1 = require_scheduling();
      var FDBTransaction2 = (
        /** @class */
        (function(_super) {
          __extends(FDBTransaction3, _super);
          function FDBTransaction3(storeNames, mode, db) {
            var _this = _super.call(this) || this;
            _this._state = "active";
            _this._started = false;
            _this._rollbackLog = [];
            _this._objectStoresCache = /* @__PURE__ */ new Map();
            _this.error = null;
            _this.onabort = null;
            _this.oncomplete = null;
            _this.onerror = null;
            _this._requests = [];
            _this._scope = new Set(storeNames);
            _this.mode = mode;
            _this.db = db;
            _this.objectStoreNames = fakeDOMStringList_1.default(Array.from(_this._scope).sort());
            return _this;
          }
          FDBTransaction3.prototype._abort = function(errName) {
            var e_1, _a, e_2, _b;
            var _this = this;
            try {
              for (var _c = __values(this._rollbackLog.reverse()), _d = _c.next(); !_d.done; _d = _c.next()) {
                var f = _d.value;
                f();
              }
            } catch (e_1_1) {
              e_1 = { error: e_1_1 };
            } finally {
              try {
                if (_d && !_d.done && (_a = _c.return)) _a.call(_c);
              } finally {
                if (e_1) throw e_1.error;
              }
            }
            if (errName !== null) {
              var e = new Error();
              e.name = errName;
              this.error = e;
            }
            try {
              for (var _e = __values(this._requests), _f = _e.next(); !_f.done; _f = _e.next()) {
                var request = _f.value.request;
                if (request.readyState !== "done") {
                  request.readyState = "done";
                  if (request.source) {
                    request.result = void 0;
                    request.error = new errors_1.AbortError();
                    var event_1 = new FakeEvent_1.default("error", {
                      bubbles: true,
                      cancelable: true
                    });
                    event_1.eventPath = [this.db, this];
                    request.dispatchEvent(event_1);
                  }
                }
              }
            } catch (e_2_1) {
              e_2 = { error: e_2_1 };
            } finally {
              try {
                if (_f && !_f.done && (_b = _e.return)) _b.call(_e);
              } finally {
                if (e_2) throw e_2.error;
              }
            }
            scheduling_1.queueTask(function() {
              var event = new FakeEvent_1.default("abort", {
                bubbles: true,
                cancelable: false
              });
              event.eventPath = [_this.db];
              _this.dispatchEvent(event);
            });
            this._state = "finished";
          };
          FDBTransaction3.prototype.abort = function() {
            if (this._state === "committing" || this._state === "finished") {
              throw new errors_1.InvalidStateError();
            }
            this._state = "active";
            this._abort(null);
          };
          FDBTransaction3.prototype.objectStore = function(name) {
            if (this._state !== "active") {
              throw new errors_1.InvalidStateError();
            }
            var objectStore = this._objectStoresCache.get(name);
            if (objectStore !== void 0) {
              return objectStore;
            }
            var rawObjectStore = this.db._rawDatabase.rawObjectStores.get(name);
            if (!this._scope.has(name) || rawObjectStore === void 0) {
              throw new errors_1.NotFoundError();
            }
            var objectStore2 = new FDBObjectStore_1.default(this, rawObjectStore);
            this._objectStoresCache.set(name, objectStore2);
            return objectStore2;
          };
          FDBTransaction3.prototype._execRequestAsync = function(obj) {
            var source = obj.source;
            var operation = obj.operation;
            var request = obj.hasOwnProperty("request") ? obj.request : null;
            if (this._state !== "active") {
              throw new errors_1.TransactionInactiveError();
            }
            if (!request) {
              if (!source) {
                request = new FDBRequest_1.default();
              } else {
                request = new FDBRequest_1.default();
                request.source = source;
                request.transaction = source.transaction;
              }
            }
            this._requests.push({
              operation,
              request
            });
            return request;
          };
          FDBTransaction3.prototype._start = function() {
            this._started = true;
            var operation;
            var request;
            while (this._requests.length > 0) {
              var r = this._requests.shift();
              if (r && r.request.readyState !== "done") {
                request = r.request;
                operation = r.operation;
                break;
              }
            }
            if (request && operation) {
              if (!request.source) {
                operation();
              } else {
                var defaultAction = void 0;
                var event_2;
                try {
                  var result = operation();
                  request.readyState = "done";
                  request.result = result;
                  request.error = void 0;
                  if (this._state === "inactive") {
                    this._state = "active";
                  }
                  event_2 = new FakeEvent_1.default("success", {
                    bubbles: false,
                    cancelable: false
                  });
                } catch (err) {
                  request.readyState = "done";
                  request.result = void 0;
                  request.error = err;
                  if (this._state === "inactive") {
                    this._state = "active";
                  }
                  event_2 = new FakeEvent_1.default("error", {
                    bubbles: true,
                    cancelable: true
                  });
                  defaultAction = this._abort.bind(this, err.name);
                }
                try {
                  event_2.eventPath = [this.db, this];
                  request.dispatchEvent(event_2);
                } catch (err) {
                  if (this._state !== "committing") {
                    this._abort("AbortError");
                  }
                  throw err;
                }
                if (!event_2.canceled) {
                  if (defaultAction) {
                    defaultAction();
                  }
                }
              }
              scheduling_1.queueTask(this._start.bind(this));
              return;
            }
            if (this._state !== "finished") {
              this._state = "finished";
              if (!this.error) {
                var event_3 = new FakeEvent_1.default("complete");
                this.dispatchEvent(event_3);
              }
            }
          };
          FDBTransaction3.prototype.commit = function() {
            if (this._state !== "active") {
              throw new errors_1.InvalidStateError();
            }
            this._state = "committing";
          };
          FDBTransaction3.prototype.toString = function() {
            return "[object IDBRequest]";
          };
          return FDBTransaction3;
        })(FakeEventTarget_1.default)
      );
      exports.default = FDBTransaction2;
    }
  });

  // node_modules/fake-indexeddb/build/lib/KeyGenerator.js
  var require_KeyGenerator = __commonJS({
    "node_modules/fake-indexeddb/build/lib/KeyGenerator.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var errors_1 = require_errors();
      var MAX_KEY = 9007199254740992;
      var KeyGenerator = (
        /** @class */
        (function() {
          function KeyGenerator2() {
            this.num = 0;
          }
          KeyGenerator2.prototype.next = function() {
            if (this.num >= MAX_KEY) {
              throw new errors_1.ConstraintError();
            }
            this.num += 1;
            return this.num;
          };
          KeyGenerator2.prototype.setIfLarger = function(num) {
            var value = Math.floor(Math.min(num, MAX_KEY)) - 1;
            if (value >= this.num) {
              this.num = value + 1;
            }
          };
          return KeyGenerator2;
        })()
      );
      exports.default = KeyGenerator;
    }
  });

  // node_modules/fake-indexeddb/build/lib/ObjectStore.js
  var require_ObjectStore = __commonJS({
    "node_modules/fake-indexeddb/build/lib/ObjectStore.js"(exports) {
      "use strict";
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var errors_1 = require_errors();
      var extractKey_1 = require_extractKey();
      var KeyGenerator_1 = require_KeyGenerator();
      var RecordStore_1 = require_RecordStore();
      var structuredClone_1 = require_structuredClone();
      var ObjectStore = (
        /** @class */
        (function() {
          function ObjectStore2(rawDatabase, name, keyPath, autoIncrement) {
            this.deleted = false;
            this.records = new RecordStore_1.default();
            this.rawIndexes = /* @__PURE__ */ new Map();
            this.rawDatabase = rawDatabase;
            this.keyGenerator = autoIncrement === true ? new KeyGenerator_1.default() : null;
            this.deleted = false;
            this.name = name;
            this.keyPath = keyPath;
            this.autoIncrement = autoIncrement;
          }
          ObjectStore2.prototype.getKey = function(key) {
            var record = this.records.get(key);
            return record !== void 0 ? structuredClone_1.default(record.key) : void 0;
          };
          ObjectStore2.prototype.getAllKeys = function(range, count) {
            var e_1, _a;
            if (count === void 0 || count === 0) {
              count = Infinity;
            }
            var records = [];
            try {
              for (var _b = __values(this.records.values(range)), _c = _b.next(); !_c.done; _c = _b.next()) {
                var record = _c.value;
                records.push(structuredClone_1.default(record.key));
                if (records.length >= count) {
                  break;
                }
              }
            } catch (e_1_1) {
              e_1 = { error: e_1_1 };
            } finally {
              try {
                if (_c && !_c.done && (_a = _b.return)) _a.call(_b);
              } finally {
                if (e_1) throw e_1.error;
              }
            }
            return records;
          };
          ObjectStore2.prototype.getValue = function(key) {
            var record = this.records.get(key);
            return record !== void 0 ? structuredClone_1.default(record.value) : void 0;
          };
          ObjectStore2.prototype.getAllValues = function(range, count) {
            var e_2, _a;
            if (count === void 0 || count === 0) {
              count = Infinity;
            }
            var records = [];
            try {
              for (var _b = __values(this.records.values(range)), _c = _b.next(); !_c.done; _c = _b.next()) {
                var record = _c.value;
                records.push(structuredClone_1.default(record.value));
                if (records.length >= count) {
                  break;
                }
              }
            } catch (e_2_1) {
              e_2 = { error: e_2_1 };
            } finally {
              try {
                if (_c && !_c.done && (_a = _b.return)) _a.call(_b);
              } finally {
                if (e_2) throw e_2.error;
              }
            }
            return records;
          };
          ObjectStore2.prototype.storeRecord = function(newRecord, noOverwrite, rollbackLog) {
            var e_3, _a;
            var _this = this;
            if (this.keyPath !== null) {
              var key = extractKey_1.default(this.keyPath, newRecord.value);
              if (key !== void 0) {
                newRecord.key = key;
              }
            }
            if (this.keyGenerator !== null && newRecord.key === void 0) {
              if (rollbackLog) {
                var keyGeneratorBefore_1 = this.keyGenerator.num;
                rollbackLog.push(function() {
                  if (_this.keyGenerator) {
                    _this.keyGenerator.num = keyGeneratorBefore_1;
                  }
                });
              }
              newRecord.key = this.keyGenerator.next();
              if (this.keyPath !== null) {
                if (Array.isArray(this.keyPath)) {
                  throw new Error("Cannot have an array key path in an object store with a key generator");
                }
                var remainingKeyPath = this.keyPath;
                var object = newRecord.value;
                var identifier = void 0;
                var i = 0;
                while (i >= 0) {
                  if (typeof object !== "object") {
                    throw new errors_1.DataError();
                  }
                  i = remainingKeyPath.indexOf(".");
                  if (i >= 0) {
                    identifier = remainingKeyPath.slice(0, i);
                    remainingKeyPath = remainingKeyPath.slice(i + 1);
                    if (!object.hasOwnProperty(identifier)) {
                      object[identifier] = {};
                    }
                    object = object[identifier];
                  }
                }
                identifier = remainingKeyPath;
                object[identifier] = newRecord.key;
              }
            } else if (this.keyGenerator !== null && typeof newRecord.key === "number") {
              this.keyGenerator.setIfLarger(newRecord.key);
            }
            var existingRecord = this.records.get(newRecord.key);
            if (existingRecord) {
              if (noOverwrite) {
                throw new errors_1.ConstraintError();
              }
              this.deleteRecord(newRecord.key, rollbackLog);
            }
            this.records.add(newRecord);
            if (rollbackLog) {
              rollbackLog.push(function() {
                _this.deleteRecord(newRecord.key);
              });
            }
            try {
              for (var _b = __values(this.rawIndexes.values()), _c = _b.next(); !_c.done; _c = _b.next()) {
                var rawIndex = _c.value;
                if (rawIndex.initialized) {
                  rawIndex.storeRecord(newRecord);
                }
              }
            } catch (e_3_1) {
              e_3 = { error: e_3_1 };
            } finally {
              try {
                if (_c && !_c.done && (_a = _b.return)) _a.call(_b);
              } finally {
                if (e_3) throw e_3.error;
              }
            }
            return newRecord.key;
          };
          ObjectStore2.prototype.deleteRecord = function(key, rollbackLog) {
            var e_4, _a, e_5, _b;
            var _this = this;
            var deletedRecords = this.records.delete(key);
            if (rollbackLog) {
              var _loop_1 = function(record2) {
                rollbackLog.push(function() {
                  _this.storeRecord(record2, true);
                });
              };
              try {
                for (var deletedRecords_1 = __values(deletedRecords), deletedRecords_1_1 = deletedRecords_1.next(); !deletedRecords_1_1.done; deletedRecords_1_1 = deletedRecords_1.next()) {
                  var record = deletedRecords_1_1.value;
                  _loop_1(record);
                }
              } catch (e_4_1) {
                e_4 = { error: e_4_1 };
              } finally {
                try {
                  if (deletedRecords_1_1 && !deletedRecords_1_1.done && (_a = deletedRecords_1.return)) _a.call(deletedRecords_1);
                } finally {
                  if (e_4) throw e_4.error;
                }
              }
            }
            try {
              for (var _c = __values(this.rawIndexes.values()), _d = _c.next(); !_d.done; _d = _c.next()) {
                var rawIndex = _d.value;
                rawIndex.records.deleteByValue(key);
              }
            } catch (e_5_1) {
              e_5 = { error: e_5_1 };
            } finally {
              try {
                if (_d && !_d.done && (_b = _c.return)) _b.call(_c);
              } finally {
                if (e_5) throw e_5.error;
              }
            }
          };
          ObjectStore2.prototype.clear = function(rollbackLog) {
            var e_6, _a, e_7, _b;
            var _this = this;
            var deletedRecords = this.records.clear();
            if (rollbackLog) {
              var _loop_2 = function(record2) {
                rollbackLog.push(function() {
                  _this.storeRecord(record2, true);
                });
              };
              try {
                for (var deletedRecords_2 = __values(deletedRecords), deletedRecords_2_1 = deletedRecords_2.next(); !deletedRecords_2_1.done; deletedRecords_2_1 = deletedRecords_2.next()) {
                  var record = deletedRecords_2_1.value;
                  _loop_2(record);
                }
              } catch (e_6_1) {
                e_6 = { error: e_6_1 };
              } finally {
                try {
                  if (deletedRecords_2_1 && !deletedRecords_2_1.done && (_a = deletedRecords_2.return)) _a.call(deletedRecords_2);
                } finally {
                  if (e_6) throw e_6.error;
                }
              }
            }
            try {
              for (var _c = __values(this.rawIndexes.values()), _d = _c.next(); !_d.done; _d = _c.next()) {
                var rawIndex = _d.value;
                rawIndex.records.clear();
              }
            } catch (e_7_1) {
              e_7 = { error: e_7_1 };
            } finally {
              try {
                if (_d && !_d.done && (_b = _c.return)) _b.call(_c);
              } finally {
                if (e_7) throw e_7.error;
              }
            }
          };
          return ObjectStore2;
        })()
      );
      exports.default = ObjectStore;
    }
  });

  // node_modules/fake-indexeddb/build/FDBDatabase.js
  var require_FDBDatabase = __commonJS({
    "node_modules/fake-indexeddb/build/FDBDatabase.js"(exports) {
      "use strict";
      var __extends = exports && exports.__extends || /* @__PURE__ */ (function() {
        var extendStatics = function(d, b) {
          extendStatics = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(d2, b2) {
            d2.__proto__ = b2;
          } || function(d2, b2) {
            for (var p in b2) if (b2.hasOwnProperty(p)) d2[p] = b2[p];
          };
          return extendStatics(d, b);
        };
        return function(d, b) {
          extendStatics(d, b);
          function __() {
            this.constructor = d;
          }
          d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
        };
      })();
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBTransaction_1 = require_FDBTransaction();
      var errors_1 = require_errors();
      var fakeDOMStringList_1 = require_fakeDOMStringList();
      var FakeEventTarget_1 = require_FakeEventTarget();
      var ObjectStore_1 = require_ObjectStore();
      var scheduling_1 = require_scheduling();
      var validateKeyPath_1 = require_validateKeyPath();
      var confirmActiveVersionchangeTransaction = function(database) {
        if (!database._runningVersionchangeTransaction) {
          throw new errors_1.InvalidStateError();
        }
        var transactions = database._rawDatabase.transactions.filter(function(tx) {
          return tx.mode === "versionchange";
        });
        var transaction = transactions[transactions.length - 1];
        if (!transaction || transaction._state === "finished") {
          throw new errors_1.InvalidStateError();
        }
        if (transaction._state !== "active") {
          throw new errors_1.TransactionInactiveError();
        }
        return transaction;
      };
      var closeConnection = function(connection) {
        connection._closePending = true;
        var transactionsComplete = connection._rawDatabase.transactions.every(function(transaction) {
          return transaction._state === "finished";
        });
        if (transactionsComplete) {
          connection._closed = true;
          connection._rawDatabase.connections = connection._rawDatabase.connections.filter(function(otherConnection) {
            return connection !== otherConnection;
          });
        } else {
          scheduling_1.queueTask(function() {
            closeConnection(connection);
          });
        }
      };
      var FDBDatabase2 = (
        /** @class */
        (function(_super) {
          __extends(FDBDatabase3, _super);
          function FDBDatabase3(rawDatabase) {
            var _this = _super.call(this) || this;
            _this._closePending = false;
            _this._closed = false;
            _this._runningVersionchangeTransaction = false;
            _this._rawDatabase = rawDatabase;
            _this._rawDatabase.connections.push(_this);
            _this.name = rawDatabase.name;
            _this.version = rawDatabase.version;
            _this.objectStoreNames = fakeDOMStringList_1.default(Array.from(rawDatabase.rawObjectStores.keys())).sort();
            return _this;
          }
          FDBDatabase3.prototype.createObjectStore = function(name, options) {
            var _this = this;
            if (options === void 0) {
              options = {};
            }
            if (name === void 0) {
              throw new TypeError();
            }
            var transaction = confirmActiveVersionchangeTransaction(this);
            var keyPath = options !== null && options.keyPath !== void 0 ? options.keyPath : null;
            var autoIncrement = options !== null && options.autoIncrement !== void 0 ? options.autoIncrement : false;
            if (keyPath !== null) {
              validateKeyPath_1.default(keyPath);
            }
            if (this._rawDatabase.rawObjectStores.has(name)) {
              throw new errors_1.ConstraintError();
            }
            if (autoIncrement && (keyPath === "" || Array.isArray(keyPath))) {
              throw new errors_1.InvalidAccessError();
            }
            var objectStoreNames = this.objectStoreNames.slice();
            transaction._rollbackLog.push(function() {
              var objectStore = _this._rawDatabase.rawObjectStores.get(name);
              if (objectStore) {
                objectStore.deleted = true;
              }
              _this.objectStoreNames = fakeDOMStringList_1.default(objectStoreNames);
              transaction._scope.delete(name);
              _this._rawDatabase.rawObjectStores.delete(name);
            });
            var rawObjectStore = new ObjectStore_1.default(this._rawDatabase, name, keyPath, autoIncrement);
            this.objectStoreNames.push(name);
            this.objectStoreNames.sort();
            transaction._scope.add(name);
            this._rawDatabase.rawObjectStores.set(name, rawObjectStore);
            transaction.objectStoreNames = fakeDOMStringList_1.default(this.objectStoreNames.slice());
            return transaction.objectStore(name);
          };
          FDBDatabase3.prototype.deleteObjectStore = function(name) {
            var _this = this;
            if (name === void 0) {
              throw new TypeError();
            }
            var transaction = confirmActiveVersionchangeTransaction(this);
            var store = this._rawDatabase.rawObjectStores.get(name);
            if (store === void 0) {
              throw new errors_1.NotFoundError();
            }
            this.objectStoreNames = fakeDOMStringList_1.default(this.objectStoreNames.filter(function(objectStoreName) {
              return objectStoreName !== name;
            }));
            transaction.objectStoreNames = fakeDOMStringList_1.default(this.objectStoreNames.slice());
            transaction._rollbackLog.push(function() {
              store.deleted = false;
              _this._rawDatabase.rawObjectStores.set(name, store);
              _this.objectStoreNames.push(name);
              _this.objectStoreNames.sort();
            });
            store.deleted = true;
            this._rawDatabase.rawObjectStores.delete(name);
            transaction._objectStoresCache.delete(name);
          };
          FDBDatabase3.prototype.transaction = function(storeNames, mode) {
            var e_1, _a;
            var _this = this;
            mode = mode !== void 0 ? mode : "readonly";
            if (mode !== "readonly" && mode !== "readwrite" && mode !== "versionchange") {
              throw new TypeError("Invalid mode: " + mode);
            }
            var hasActiveVersionchange = this._rawDatabase.transactions.some(function(transaction) {
              return transaction._state === "active" && transaction.mode === "versionchange" && transaction.db === _this;
            });
            if (hasActiveVersionchange) {
              throw new errors_1.InvalidStateError();
            }
            if (this._closePending) {
              throw new errors_1.InvalidStateError();
            }
            if (!Array.isArray(storeNames)) {
              storeNames = [storeNames];
            }
            if (storeNames.length === 0 && mode !== "versionchange") {
              throw new errors_1.InvalidAccessError();
            }
            try {
              for (var storeNames_1 = __values(storeNames), storeNames_1_1 = storeNames_1.next(); !storeNames_1_1.done; storeNames_1_1 = storeNames_1.next()) {
                var storeName = storeNames_1_1.value;
                if (this.objectStoreNames.indexOf(storeName) < 0) {
                  throw new errors_1.NotFoundError("No objectStore named " + storeName + " in this database");
                }
              }
            } catch (e_1_1) {
              e_1 = { error: e_1_1 };
            } finally {
              try {
                if (storeNames_1_1 && !storeNames_1_1.done && (_a = storeNames_1.return)) _a.call(storeNames_1);
              } finally {
                if (e_1) throw e_1.error;
              }
            }
            var tx = new FDBTransaction_1.default(storeNames, mode, this);
            this._rawDatabase.transactions.push(tx);
            this._rawDatabase.processTransactions();
            return tx;
          };
          FDBDatabase3.prototype.close = function() {
            closeConnection(this);
          };
          FDBDatabase3.prototype.toString = function() {
            return "[object IDBDatabase]";
          };
          return FDBDatabase3;
        })(FakeEventTarget_1.default)
      );
      exports.default = FDBDatabase2;
    }
  });

  // node_modules/fake-indexeddb/build/FDBOpenDBRequest.js
  var require_FDBOpenDBRequest = __commonJS({
    "node_modules/fake-indexeddb/build/FDBOpenDBRequest.js"(exports) {
      "use strict";
      var __extends = exports && exports.__extends || /* @__PURE__ */ (function() {
        var extendStatics = function(d, b) {
          extendStatics = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(d2, b2) {
            d2.__proto__ = b2;
          } || function(d2, b2) {
            for (var p in b2) if (b2.hasOwnProperty(p)) d2[p] = b2[p];
          };
          return extendStatics(d, b);
        };
        return function(d, b) {
          extendStatics(d, b);
          function __() {
            this.constructor = d;
          }
          d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
        };
      })();
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBRequest_1 = require_FDBRequest();
      var FDBOpenDBRequest2 = (
        /** @class */
        (function(_super) {
          __extends(FDBOpenDBRequest3, _super);
          function FDBOpenDBRequest3() {
            var _this = _super !== null && _super.apply(this, arguments) || this;
            _this.onupgradeneeded = null;
            _this.onblocked = null;
            return _this;
          }
          FDBOpenDBRequest3.prototype.toString = function() {
            return "[object IDBOpenDBRequest]";
          };
          return FDBOpenDBRequest3;
        })(FDBRequest_1.default)
      );
      exports.default = FDBOpenDBRequest2;
    }
  });

  // node_modules/fake-indexeddb/build/FDBVersionChangeEvent.js
  var require_FDBVersionChangeEvent = __commonJS({
    "node_modules/fake-indexeddb/build/FDBVersionChangeEvent.js"(exports) {
      "use strict";
      var __extends = exports && exports.__extends || /* @__PURE__ */ (function() {
        var extendStatics = function(d, b) {
          extendStatics = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(d2, b2) {
            d2.__proto__ = b2;
          } || function(d2, b2) {
            for (var p in b2) if (b2.hasOwnProperty(p)) d2[p] = b2[p];
          };
          return extendStatics(d, b);
        };
        return function(d, b) {
          extendStatics(d, b);
          function __() {
            this.constructor = d;
          }
          d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
        };
      })();
      Object.defineProperty(exports, "__esModule", { value: true });
      var FakeEvent_1 = require_FakeEvent();
      var FDBVersionChangeEvent2 = (
        /** @class */
        (function(_super) {
          __extends(FDBVersionChangeEvent3, _super);
          function FDBVersionChangeEvent3(type, parameters) {
            if (parameters === void 0) {
              parameters = {};
            }
            var _this = _super.call(this, type) || this;
            _this.newVersion = parameters.newVersion !== void 0 ? parameters.newVersion : null;
            _this.oldVersion = parameters.oldVersion !== void 0 ? parameters.oldVersion : 0;
            return _this;
          }
          FDBVersionChangeEvent3.prototype.toString = function() {
            return "[object IDBVersionChangeEvent]";
          };
          return FDBVersionChangeEvent3;
        })(FakeEvent_1.default)
      );
      exports.default = FDBVersionChangeEvent2;
    }
  });

  // node_modules/fake-indexeddb/build/lib/Database.js
  var require_Database = __commonJS({
    "node_modules/fake-indexeddb/build/lib/Database.js"(exports) {
      "use strict";
      Object.defineProperty(exports, "__esModule", { value: true });
      var scheduling_1 = require_scheduling();
      var Database = (
        /** @class */
        (function() {
          function Database2(name, version) {
            this.deletePending = false;
            this.transactions = [];
            this.rawObjectStores = /* @__PURE__ */ new Map();
            this.connections = [];
            this.name = name;
            this.version = version;
            this.processTransactions = this.processTransactions.bind(this);
          }
          Database2.prototype.processTransactions = function() {
            var _this = this;
            scheduling_1.queueTask(function() {
              var anyRunning = _this.transactions.some(function(transaction) {
                return transaction._started && transaction._state !== "finished";
              });
              if (!anyRunning) {
                var next = _this.transactions.find(function(transaction) {
                  return !transaction._started && transaction._state !== "finished";
                });
                if (next) {
                  next.addEventListener("complete", _this.processTransactions);
                  next.addEventListener("abort", _this.processTransactions);
                  next._start();
                }
              }
            });
          };
          return Database2;
        })()
      );
      exports.default = Database;
    }
  });

  // node_modules/fake-indexeddb/build/FDBFactory.js
  var require_FDBFactory = __commonJS({
    "node_modules/fake-indexeddb/build/FDBFactory.js"(exports) {
      "use strict";
      var __values = exports && exports.__values || function(o) {
        var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
        if (m) return m.call(o);
        if (o && typeof o.length === "number") return {
          next: function() {
            if (o && i >= o.length) o = void 0;
            return { value: o && o[i++], done: !o };
          }
        };
        throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
      };
      var __read = exports && exports.__read || function(o, n) {
        var m = typeof Symbol === "function" && o[Symbol.iterator];
        if (!m) return o;
        var i = m.call(o), r, ar = [], e;
        try {
          while ((n === void 0 || n-- > 0) && !(r = i.next()).done) ar.push(r.value);
        } catch (error) {
          e = { error };
        } finally {
          try {
            if (r && !r.done && (m = i["return"])) m.call(i);
          } finally {
            if (e) throw e.error;
          }
        }
        return ar;
      };
      Object.defineProperty(exports, "__esModule", { value: true });
      var FDBDatabase_1 = require_FDBDatabase();
      var FDBOpenDBRequest_1 = require_FDBOpenDBRequest();
      var FDBVersionChangeEvent_1 = require_FDBVersionChangeEvent();
      var cmp_1 = require_cmp();
      var Database_1 = require_Database();
      var enforceRange_1 = require_enforceRange();
      var errors_1 = require_errors();
      var FakeEvent_1 = require_FakeEvent();
      var scheduling_1 = require_scheduling();
      var waitForOthersClosedDelete = function(databases, name, openDatabases, cb) {
        var anyOpen = openDatabases.some(function(openDatabase2) {
          return !openDatabase2._closed && !openDatabase2._closePending;
        });
        if (anyOpen) {
          scheduling_1.queueTask(function() {
            return waitForOthersClosedDelete(databases, name, openDatabases, cb);
          });
          return;
        }
        databases.delete(name);
        cb(null);
      };
      var deleteDatabase = function(databases, name, request, cb) {
        var e_1, _a;
        try {
          var db = databases.get(name);
          if (db === void 0) {
            cb(null);
            return;
          }
          db.deletePending = true;
          var openDatabases = db.connections.filter(function(connection) {
            return !connection._closed && !connection._closePending;
          });
          try {
            for (var openDatabases_1 = __values(openDatabases), openDatabases_1_1 = openDatabases_1.next(); !openDatabases_1_1.done; openDatabases_1_1 = openDatabases_1.next()) {
              var openDatabase2 = openDatabases_1_1.value;
              if (!openDatabase2._closePending) {
                var event_1 = new FDBVersionChangeEvent_1.default("versionchange", {
                  newVersion: null,
                  oldVersion: db.version
                });
                openDatabase2.dispatchEvent(event_1);
              }
            }
          } catch (e_1_1) {
            e_1 = { error: e_1_1 };
          } finally {
            try {
              if (openDatabases_1_1 && !openDatabases_1_1.done && (_a = openDatabases_1.return)) _a.call(openDatabases_1);
            } finally {
              if (e_1) throw e_1.error;
            }
          }
          var anyOpen = openDatabases.some(function(openDatabase3) {
            return !openDatabase3._closed && !openDatabase3._closePending;
          });
          if (request && anyOpen) {
            var event_2 = new FDBVersionChangeEvent_1.default("blocked", {
              newVersion: null,
              oldVersion: db.version
            });
            request.dispatchEvent(event_2);
          }
          waitForOthersClosedDelete(databases, name, openDatabases, cb);
        } catch (err) {
          cb(err);
        }
      };
      var runVersionchangeTransaction = function(connection, version, request, cb) {
        var e_2, _a;
        connection._runningVersionchangeTransaction = true;
        var oldVersion = connection.version;
        var openDatabases = connection._rawDatabase.connections.filter(function(otherDatabase) {
          return connection !== otherDatabase;
        });
        try {
          for (var openDatabases_2 = __values(openDatabases), openDatabases_2_1 = openDatabases_2.next(); !openDatabases_2_1.done; openDatabases_2_1 = openDatabases_2.next()) {
            var openDatabase2 = openDatabases_2_1.value;
            if (!openDatabase2._closed && !openDatabase2._closePending) {
              var event_3 = new FDBVersionChangeEvent_1.default("versionchange", {
                newVersion: version,
                oldVersion
              });
              openDatabase2.dispatchEvent(event_3);
            }
          }
        } catch (e_2_1) {
          e_2 = { error: e_2_1 };
        } finally {
          try {
            if (openDatabases_2_1 && !openDatabases_2_1.done && (_a = openDatabases_2.return)) _a.call(openDatabases_2);
          } finally {
            if (e_2) throw e_2.error;
          }
        }
        var anyOpen = openDatabases.some(function(openDatabase3) {
          return !openDatabase3._closed && !openDatabase3._closePending;
        });
        if (anyOpen) {
          var event_4 = new FDBVersionChangeEvent_1.default("blocked", {
            newVersion: version,
            oldVersion
          });
          request.dispatchEvent(event_4);
        }
        var waitForOthersClosed = function() {
          var anyOpen2 = openDatabases.some(function(openDatabase22) {
            return !openDatabase22._closed && !openDatabase22._closePending;
          });
          if (anyOpen2) {
            scheduling_1.queueTask(waitForOthersClosed);
            return;
          }
          connection._rawDatabase.version = version;
          connection.version = version;
          var transaction = connection.transaction(connection.objectStoreNames, "versionchange");
          request.result = connection;
          request.readyState = "done";
          request.transaction = transaction;
          transaction._rollbackLog.push(function() {
            connection._rawDatabase.version = oldVersion;
            connection.version = oldVersion;
          });
          var event = new FDBVersionChangeEvent_1.default("upgradeneeded", {
            newVersion: version,
            oldVersion
          });
          request.dispatchEvent(event);
          transaction.addEventListener("error", function() {
            connection._runningVersionchangeTransaction = false;
          });
          transaction.addEventListener("abort", function() {
            connection._runningVersionchangeTransaction = false;
            request.transaction = null;
            scheduling_1.queueTask(function() {
              cb(new errors_1.AbortError());
            });
          });
          transaction.addEventListener("complete", function() {
            connection._runningVersionchangeTransaction = false;
            request.transaction = null;
            scheduling_1.queueTask(function() {
              if (connection._closePending) {
                cb(new errors_1.AbortError());
              } else {
                cb(null);
              }
            });
          });
        };
        waitForOthersClosed();
      };
      var openDatabase = function(databases, name, version, request, cb) {
        var db = databases.get(name);
        if (db === void 0) {
          db = new Database_1.default(name, 0);
          databases.set(name, db);
        }
        if (version === void 0) {
          version = db.version !== 0 ? db.version : 1;
        }
        if (db.version > version) {
          return cb(new errors_1.VersionError());
        }
        var connection = new FDBDatabase_1.default(db);
        if (db.version < version) {
          runVersionchangeTransaction(connection, version, request, function(err) {
            if (err) {
              return cb(err);
            }
            cb(null, connection);
          });
        } else {
          cb(null, connection);
        }
      };
      var FDBFactory2 = (
        /** @class */
        (function() {
          function FDBFactory3() {
            this.cmp = cmp_1.default;
            this._databases = /* @__PURE__ */ new Map();
          }
          FDBFactory3.prototype.deleteDatabase = function(name) {
            var _this = this;
            var request = new FDBOpenDBRequest_1.default();
            request.source = null;
            scheduling_1.queueTask(function() {
              var db = _this._databases.get(name);
              var oldVersion = db !== void 0 ? db.version : 0;
              deleteDatabase(_this._databases, name, request, function(err) {
                if (err) {
                  request.error = new Error();
                  request.error.name = err.name;
                  request.readyState = "done";
                  var event_5 = new FakeEvent_1.default("error", {
                    bubbles: true,
                    cancelable: true
                  });
                  event_5.eventPath = [];
                  request.dispatchEvent(event_5);
                  return;
                }
                request.result = void 0;
                request.readyState = "done";
                var event2 = new FDBVersionChangeEvent_1.default("success", {
                  newVersion: null,
                  oldVersion
                });
                request.dispatchEvent(event2);
              });
            });
            return request;
          };
          FDBFactory3.prototype.open = function(name, version) {
            var _this = this;
            if (arguments.length > 1 && version !== void 0) {
              version = enforceRange_1.default(version, "MAX_SAFE_INTEGER");
            }
            if (version === 0) {
              throw new TypeError();
            }
            var request = new FDBOpenDBRequest_1.default();
            request.source = null;
            scheduling_1.queueTask(function() {
              openDatabase(_this._databases, name, version, request, function(err, connection) {
                if (err) {
                  request.result = void 0;
                  request.readyState = "done";
                  request.error = new Error();
                  request.error.name = err.name;
                  var event_6 = new FakeEvent_1.default("error", {
                    bubbles: true,
                    cancelable: true
                  });
                  event_6.eventPath = [];
                  request.dispatchEvent(event_6);
                  return;
                }
                request.result = connection;
                request.readyState = "done";
                var event2 = new FakeEvent_1.default("success");
                event2.eventPath = [];
                request.dispatchEvent(event2);
              });
            });
            return request;
          };
          FDBFactory3.prototype.databases = function() {
            var _this = this;
            return new Promise(function(resolve) {
              var e_3, _a;
              var result = [];
              try {
                for (var _b = __values(_this._databases), _c = _b.next(); !_c.done; _c = _b.next()) {
                  var _d = __read(_c.value, 2), name_1 = _d[0], database = _d[1];
                  result.push({
                    name: name_1,
                    version: database.version
                  });
                }
              } catch (e_3_1) {
                e_3 = { error: e_3_1 };
              } finally {
                try {
                  if (_c && !_c.done && (_a = _b.return)) _a.call(_b);
                } finally {
                  if (e_3) throw e_3.error;
                }
              }
              resolve(result);
            });
          };
          FDBFactory3.prototype.toString = function() {
            return "[object IDBFactory]";
          };
          return FDBFactory3;
        })()
      );
      exports.default = FDBFactory2;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBFactory.js
  var require_FDBFactory2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBFactory.js"(exports, module) {
      module.exports = require_FDBFactory().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBKeyRange.js
  var require_FDBKeyRange2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBKeyRange.js"(exports, module) {
      module.exports = require_FDBKeyRange().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBDatabase.js
  var require_FDBDatabase2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBDatabase.js"(exports, module) {
      module.exports = require_FDBDatabase().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBObjectStore.js
  var require_FDBObjectStore2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBObjectStore.js"(exports, module) {
      module.exports = require_FDBObjectStore().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBTransaction.js
  var require_FDBTransaction2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBTransaction.js"(exports, module) {
      module.exports = require_FDBTransaction().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBRequest.js
  var require_FDBRequest2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBRequest.js"(exports, module) {
      module.exports = require_FDBRequest().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBOpenDBRequest.js
  var require_FDBOpenDBRequest2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBOpenDBRequest.js"(exports, module) {
      module.exports = require_FDBOpenDBRequest().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBCursor.js
  var require_FDBCursor2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBCursor.js"(exports, module) {
      module.exports = require_FDBCursor().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBCursorWithValue.js
  var require_FDBCursorWithValue2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBCursorWithValue.js"(exports, module) {
      module.exports = require_FDBCursorWithValue().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBIndex.js
  var require_FDBIndex2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBIndex.js"(exports, module) {
      module.exports = require_FDBIndex().default;
    }
  });

  // node_modules/fake-indexeddb/lib/FDBVersionChangeEvent.js
  var require_FDBVersionChangeEvent2 = __commonJS({
    "node_modules/fake-indexeddb/lib/FDBVersionChangeEvent.js"(exports, module) {
      module.exports = require_FDBVersionChangeEvent().default;
    }
  });

  // entry.mjs
  var import_FDBFactory = __toESM(require_FDBFactory2(), 1);
  var import_FDBKeyRange = __toESM(require_FDBKeyRange2(), 1);
  var import_FDBDatabase = __toESM(require_FDBDatabase2(), 1);
  var import_FDBObjectStore = __toESM(require_FDBObjectStore2(), 1);
  var import_FDBTransaction = __toESM(require_FDBTransaction2(), 1);
  var import_FDBRequest = __toESM(require_FDBRequest2(), 1);
  var import_FDBOpenDBRequest = __toESM(require_FDBOpenDBRequest2(), 1);
  var import_FDBCursor = __toESM(require_FDBCursor2(), 1);
  var import_FDBCursorWithValue = __toESM(require_FDBCursorWithValue2(), 1);
  var import_FDBIndex = __toESM(require_FDBIndex2(), 1);
  var import_FDBVersionChangeEvent = __toESM(require_FDBVersionChangeEvent2(), 1);
  var g = globalThis;
  if (typeof g.indexedDB === "undefined") {
    g.indexedDB = new import_FDBFactory.default();
  }
  g.IDBFactory = import_FDBFactory.default;
  g.IDBKeyRange = import_FDBKeyRange.default;
  g.IDBDatabase = import_FDBDatabase.default;
  g.IDBObjectStore = import_FDBObjectStore.default;
  g.IDBTransaction = import_FDBTransaction.default;
  g.IDBRequest = import_FDBRequest.default;
  g.IDBOpenDBRequest = import_FDBOpenDBRequest.default;
  g.IDBCursor = import_FDBCursor.default;
  g.IDBCursorWithValue = import_FDBCursorWithValue.default;
  g.IDBIndex = import_FDBIndex.default;
  g.IDBVersionChangeEvent = import_FDBVersionChangeEvent.default;
})();
