//
//  WebExtensionIndexedDBBlobTests.swift
//  BrownBearTests
//
//  Regression coverage for the ScriptCat "no data found" import bug. The bundled IndexedDB engine
//  (brownbear-indexeddb.js) clones every stored value through typeson's structured-clone, whose
//  Blob/File handlers call `new XMLHttpRequest()` over `URL.createObjectURL(blob)` on write and
//  `new File([...])`/`new Blob([...])` on read. JavaScriptCore's headless service-worker global had
//  none of those, so putting a Blob into IndexedDB threw DataCloneError and the engine SILENTLY
//  DROPPED the whole record — a userscript manager that stores an imported script as a Blob then read
//  back nothing. brownbear-webext-background.js now provides minimal, in-memory Blob/File/FileReader +
//  URL.createObjectURL + a blob:-only XMLHttpRequest, and brownbear-idb-persist.js serializes a stored
//  Blob/File through the snapshot so it survives a service-worker restart.
//
//  These boot the REAL background context (engine + persistence + the new globals all installed by
//  `boot`) in a JSContext and exercise the actual put/get and snapshot/rehydrate paths.
//

import XCTest
@testable import BrownBear

final class WebExtensionIndexedDBBlobTests: XCTestCase {

    struct RuntimeNotBundled: Error {}

    private func backgroundRuntimeSource() throws -> String {
        let url = Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-background", withExtension: "js")
        guard let url else { throw RuntimeNotBundled() }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A fixed, isolated extension id for the persistence test so the two boots share one on-disk
    /// snapshot. Cleared in setUp/tearDown so the shared BrownBearIDBStore singleton can't leak state.
    private let persistExtID = "bbblobpersisttestbbblobpersistte"

    private func makeContext(extensionID: String = "abcdefghijklmnopabcdefghijklmnop",
                             background: String) throws -> WebExtensionBackgroundContext {
        let context = WebExtensionBackgroundContext(
            extensionID: extensionID,
            extensionName: "Test",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.idbblob.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: #"{"manifest_version":3,"name":"Test","version":"1.0"}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    override func setUp() {
        super.setUp()
        BrownBearIDBStore.shared.clear(namespace: .ext(persistExtID))
        BrownBearIDBStore.shared.waitForPendingWrites()
    }

    override func tearDown() {
        BrownBearIDBStore.shared.clear(namespace: .ext(persistExtID))
        BrownBearIDBStore.shared.waitForPendingWrites()
        super.tearDown()
    }

    // MARK: - In-memory put/get round-trip (the structured-clone path that was dropping records)

    func testBlobAndFileRoundTripThroughIndexedDB() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'roundtrip') { return; }
          (async function () {
            function reqP(r) { return new Promise(function (res, rej) {
              r.onsuccess = function () { res(r.result); }; r.onerror = function () { rej(r.error); }; }); }
            function openDB() { return new Promise(function (res, rej) {
              var o = indexedDB.open('bbrt', 1);
              o.onupgradeneeded = function (e) { e.target.result.createObjectStore('s', { keyPath: 'id' }); };
              o.onsuccess = function () { res(o.result); }; o.onerror = function () { rej(o.error); }; }); }
            var text = 'imported userscript \\u2603 — body line 2';   // \\u2603 = ☃ (3 UTF-8 bytes)
            var db = await openDB();
            var store = db.transaction('s', 'readwrite').objectStore('s');
            await reqP(store.put({ id: 1,
              code: new Blob([text], { type: 'text/javascript' }),
              file: new File([text], 's.user.js', { type: 'text/javascript', lastModified: 4242 }) }));
            var got = await reqP(db.transaction('s', 'readonly').objectStore('s').get(1));
            var codeStr = (got && got.code) ? await got.code.text() : '(none)';
            var fileStr = (got && got.file) ? await got.file.text() : '(none)';
            // Exercise FileReader + createObjectURL + the blob:-only XHR directly, too.
            var frResult = await new Promise(function (res, rej) {
              var fr = new FileReader();
              fr.onload = function () { res(fr.result); }; fr.onerror = function () { rej(fr.error); };
              fr.readAsText(new Blob(['fr-' + text]));
            });
            var objURL = URL.createObjectURL(new Blob(['xhr-bytes']));
            var xhrText = await new Promise(function (res) {
              var x = new XMLHttpRequest(); x.open('GET', objURL, false); x.send();
              res(x.status === 200 ? x.responseText : '(status ' + x.status + ')');
            });
            URL.revokeObjectURL(objURL);
            sendResponse({
              hasBlob: typeof Blob === 'function', hasFile: typeof File === 'function',
              hasFileReader: typeof FileReader === 'function',
              hasCreateObjectURL: typeof URL.createObjectURL === 'function',
              codeTag: Object.prototype.toString.call(got && got.code),
              fileTag: Object.prototype.toString.call(got && got.file),
              codeStr: codeStr, fileStr: fileStr,
              fileName: (got && got.file) ? got.file.name : null,
              fileLastModified: (got && got.file) ? got.file.lastModified : null,
              frResult: frResult, xhrText: xhrText
            });
          })().catch(function (e) { sendResponse({ error: String((e && e.stack) || (e && e.message) || e) }); });
          return true;   // async sendResponse
        });
        """)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["check": "roundtrip"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the worker must register its listener")
        XCTAssertNil(r["error"], "no error in the round-trip: \(r)")
        XCTAssertEqual(r["hasBlob"] as? Bool, true)
        XCTAssertEqual(r["hasFile"] as? Bool, true)
        XCTAssertEqual(r["hasFileReader"] as? Bool, true)
        XCTAssertEqual(r["hasCreateObjectURL"] as? Bool, true)
        XCTAssertEqual(r["codeTag"] as? String, "[object Blob]", "a stored Blob must survive the clone, not be dropped")
        XCTAssertEqual(r["fileTag"] as? String, "[object File]")
        let expected = "imported userscript ☃ — body line 2"
        XCTAssertEqual(r["codeStr"] as? String, expected, "the Blob's bytes must round-trip through IndexedDB")
        XCTAssertEqual(r["fileStr"] as? String, expected)
        XCTAssertEqual(r["fileName"] as? String, "s.user.js", "File.name must survive the clone")
        XCTAssertEqual(r["fileLastModified"] as? Int, 4242, "File.lastModified must survive the clone")
        XCTAssertEqual(r["frResult"] as? String, "fr-" + expected, "FileReader.readAsText must decode the bytes")
        XCTAssertEqual(r["xhrText"] as? String, "xhr-bytes", "the blob:-only XHR must read an object-URL's bytes")
    }

    // MARK: - Survives a service-worker restart (snapshot → rehydrate persistence path)

    func testImportedBlobSurvivesContextRestart() async throws {
        // Context A: store a Blob-bearing record, then flush a snapshot to the on-disk store.
        let contextA = try makeContext(extensionID: persistExtID, background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'put') { return; }
          (async function () {
            function reqP(r) { return new Promise(function (res, rej) {
              r.onsuccess = function () { res(r.result); }; r.onerror = function () { rej(r.error); }; }); }
            var db = await new Promise(function (res, rej) {
              var o = indexedDB.open('bbpersist', 1);
              o.onupgradeneeded = function (e) { e.target.result.createObjectStore('s', { keyPath: 'id' }); };
              o.onsuccess = function () { res(o.result); }; o.onerror = function () { rej(o.error); }; });
            await reqP(db.transaction('s', 'readwrite').objectStore('s').put({ id: 7,
              code: new File(['persisted-script-\\u2603'], 'p.user.js', { type: 'text/javascript', lastModified: 99 }) }));
            __bbIDBFlush();   // synchronous snapshot → __bb_idb_save (persists to the on-disk store)
            sendResponse({ ok: true });
          })().catch(function (e) { sendResponse({ error: String((e && e.message) || e) }); });
          return true;
        });
        """)
        let putResp = await contextA.deliverRuntimeMessage(message: ["check": "put"], sender: [:])
        let putR = try XCTUnwrap(putResp?["value"] as? [String: Any], "context A must register its listener")
        XCTAssertNil(putR["error"], "no error storing the Blob: \(putR)")
        XCTAssertEqual(putR["ok"] as? Bool, true)
        BrownBearIDBStore.shared.waitForPendingWrites()   // the async disk write completes before the reboot
        contextA.shutdown()

        // Context B: same extension id → boot rehydrates the snapshot; the imported File must reappear.
        let contextB = try makeContext(extensionID: persistExtID, background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'read') { return; }
          (async function () {
            function reqP(r) { return new Promise(function (res, rej) {
              r.onsuccess = function () { res(r.result); }; r.onerror = function () { rej(r.error); }; }); }
            function openDB() { return new Promise(function (res, rej) {
              var o = indexedDB.open('bbpersist', 1);
              o.onupgradeneeded = function (e) {
                if (!e.target.result.objectStoreNames.contains('s')) {
                  e.target.result.createObjectStore('s', { keyPath: 'id' });
                } };
              o.onsuccess = function () { res(o.result); }; o.onerror = function () { rej(o.error); }; }); }
            // Rehydrate replays asynchronously at boot; poll briefly until the record reappears.
            var rec = null;
            for (var i = 0; i < 50 && !rec; i++) {
              var db = await openDB();
              rec = await reqP(db.transaction('s', 'readonly').objectStore('s').get(7)).catch(function () { return null; });
              db.close();
              if (!rec) { await new Promise(function (r) { setTimeout(r, 10); }); }
            }
            var codeStr = (rec && rec.code) ? await rec.code.text() : '(none)';
            sendResponse({ found: !!rec, codeStr: codeStr,
                           name: (rec && rec.code) ? rec.code.name : null,
                           tag: Object.prototype.toString.call(rec && rec.code) });
          })().catch(function (e) { sendResponse({ error: String((e && e.message) || e) }); });
          return true;
        });
        """)
        defer { contextB.shutdown() }
        let readResp = await contextB.deliverRuntimeMessage(message: ["check": "read"], sender: [:])
        let readR = try XCTUnwrap(readResp?["value"] as? [String: Any], "context B must register its listener")
        XCTAssertNil(readR["error"], "no error reading the rehydrated Blob: \(readR)")
        XCTAssertEqual(readR["found"] as? Bool, true, "the imported Blob must survive a service-worker restart")
        XCTAssertEqual(readR["codeStr"] as? String, "persisted-script-☃", "the Blob's bytes must survive the snapshot")
        XCTAssertEqual(readR["name"] as? String, "p.user.js", "File.name must survive the snapshot")
        XCTAssertEqual(readR["tag"] as? String, "[object File]")
    }
}
