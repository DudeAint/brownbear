//
//  WebExtensionIndexedDBTransactionTests.swift
//  BrownBearTests
//
//  Regression guard for the IndexedDB scheduling fix. fake-indexeddb's transaction state machine
//  reschedules via setImmediate and assumes MACROTASK semantics (each queued request settles in its own
//  turn). Our shim mapped setImmediate to a microtask, which drained a whole transaction in one
//  checkpoint and raced multi-store / nested getAll() flows — exactly Violentmonkey's `patch-db.js`
//  legacy migration ("Upgrade database…" → t.catch / null table / destructure of an undefined getAll).
//  This boots the real background context (native setTimeout → true macrotasks) and runs that pattern:
//  a readonly transaction over four stores with three concurrent getAll()s plus a fourth issued from
//  inside an onsuccess (the patch-db shape). It must complete with every store's data intact.
//

import XCTest
@testable import BrownBear

final class WebExtensionIndexedDBTransactionTests: XCTestCase {

    struct RuntimeNotBundled: Error {}

    private func backgroundRuntimeSource() throws -> String {
        let url = Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-background", withExtension: "js")
        guard let url else { throw RuntimeNotBundled() }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeContext(background: String) throws -> WebExtensionBackgroundContext {
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let context = WebExtensionBackgroundContext(
            extensionID: extensionID,
            extensionName: "Test",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.idbtx.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: #"{"manifest_version":3,"name":"Test","version":"1.0"}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    func testMultiStoreConcurrentAndNestedGetAllCompletes() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'vmmig') { return; }
          (async function () {
            function txDone(tx) { return new Promise(function (res, rej) {
              tx.oncomplete = function () { res(); }; tx.onerror = function () { rej(tx.error); };
              tx.onabort = function () { rej(tx.error || new Error('abort')); }; }); }
            // 1. Create + populate four stores (the VM legacy DB shape: scripts/require/cache/values).
            var db = await new Promise(function (res, rej) {
              var o = indexedDB.open('vmmig', 1);
              o.onupgradeneeded = function (e) {
                var d = e.target.result;
                d.createObjectStore('scripts', { keyPath: 'uri' });
                d.createObjectStore('require', { keyPath: 'uri' });
                d.createObjectStore('cache', { keyPath: 'uri' });
                d.createObjectStore('values', { keyPath: 'uri' });
              };
              o.onsuccess = function () { res(o.result); }; o.onerror = function () { rej(o.error); };
            });
            var w = db.transaction(['scripts', 'require', 'cache', 'values'], 'readwrite');
            w.objectStore('scripts').put({ uri: 'a', name: 'A' });
            w.objectStore('scripts').put({ uri: 'b', name: 'B' });
            w.objectStore('require').put({ uri: 'r1', code: 'x' });
            w.objectStore('cache').put({ uri: 'c1' });
            w.objectStore('cache').put({ uri: 'c2' });
            w.objectStore('values').put({ uri: 'a', data: 'VAL-A' });
            await txDone(w);
            db.close();
            // 2. Reopen and run patch-db's pattern: one readonly txn over all four stores, three
            //    concurrent getAll()s + a fourth (values) issued INSIDE scripts' onsuccess.
            var db2 = await new Promise(function (res, rej) {
              var o = indexedDB.open('vmmig', 1);
              o.onsuccess = function () { res(o.result); }; o.onerror = function () { rej(o.error); };
            });
            var out = await new Promise(function (resolve, reject) {
              var r = { scripts: null, cache: null, require: null, values: null };
              var pending = 4;
              function done() { pending--; if (pending === 0) { resolve(r); } }
              var tx = db2.transaction(['scripts', 'require', 'cache', 'values'], 'readonly');
              tx.onabort = function () { reject(tx.error || new Error('tx abort')); };
              var s = tx.objectStore('scripts').getAll();
              s.onsuccess = function () {
                r.scripts = s.result.length;
                var v = tx.objectStore('values').getAll();   // nested request on the SAME live txn
                v.onsuccess = function () { r.values = v.result.length; done(); };
                v.onerror = function () { reject(v.error); };
                done();
              };
              s.onerror = function () { reject(s.error); };
              var c = tx.objectStore('cache').getAll();
              c.onsuccess = function () { r.cache = c.result.length; done(); };
              c.onerror = function () { reject(c.error); };
              var q = tx.objectStore('require').getAll();
              q.onsuccess = function () { r.require = q.result.length; done(); };
              q.onerror = function () { reject(q.error); };
            });
            sendResponse(out);
          })().catch(function (e) { sendResponse({ error: String((e && e.message) || e) }); });
          return true;   // async sendResponse
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "vmmig"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the worker must register its listener")
        XCTAssertNil(r["error"], "the multi-store concurrent+nested transaction must not wedge: \(r)")
        XCTAssertEqual(r["scripts"] as? Int, 2)
        XCTAssertEqual(r["cache"] as? Int, 2)
        XCTAssertEqual(r["require"] as? Int, 1)
        XCTAssertEqual(r["values"] as? Int, 1, "the nested getAll() on the live transaction must complete")
    }
}
