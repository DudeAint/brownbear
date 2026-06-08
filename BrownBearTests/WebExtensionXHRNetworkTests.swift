//
//  WebExtensionXHRNetworkTests.swift
//  BrownBearTests
//
//  The headless service-worker XMLHttpRequest is now network-capable: http(s) requests route through the
//  native-backed, host-permission-gated fetch (async), while `blob:` object URLs still resolve
//  synchronously from their bytes (the fake-indexeddb clone contract). Violentmonkey's GM_xmlhttpRequest
//  is built on XHR, so without a real network path it could construct requests but never complete them.
//  These tests cover the http path (reaching the extension scheme handler, and failing closed on an
//  un-permitted host), the blob: object-URL path + responseType handling, and Response.blob().
//

import XCTest
@testable import BrownBear

final class WebExtensionXHRNetworkTests: XCTestCase {

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
            storage: WebExtensionStorage(suiteName: "brownbear.webext.xhr.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: #"{"manifest_version":3,"name":"Test","version":"1.0"}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    /// An async XHR GET of a root-relative path resolves against the worker origin and reaches the
    /// extension scheme handler (404 for a missing packaged file) — proving the http path runs through
    /// fetch and completes with a real status, firing readystatechange→load (not error).
    func testXHRGetReachesSchemeHandlerWithStatus() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'xhrget') { return; }
          var x = new XMLHttpRequest();
          var states = [];
          x.onreadystatechange = function () { states.push(x.readyState); };
          x.onload = function () { sendResponse({ status: x.status, states: states, fired: 'load', hasText: typeof x.responseText === 'string' }); };
          x.onerror = function () { sendResponse({ status: x.status, fired: 'error' }); };
          x.open('GET', '/does-not-exist.js', true);
          x.send();
          return true;   // async response
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "xhrget"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the worker must register its listener")
        XCTAssertEqual(r["fired"] as? String, "load", "a completed HTTP exchange fires load, not error")
        XCTAssertEqual(r["status"] as? Int, 404, "missing packaged file → 404 through the scheme handler")
        XCTAssertEqual(r["hasText"] as? Bool, true)
    }

    /// An XHR to a host with no host_permissions must fail closed: fetch rejects on the gate, so XHR
    /// reports status 0 and fires error (Chrome surfaces the same for a blocked request).
    func testXHRUnpermittedHostFiresError() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'xhrhost') { return; }
          var x = new XMLHttpRequest();
          x.addEventListener('error', function () { sendResponse({ fired: 'error', status: x.status }); });
          x.addEventListener('load', function () { sendResponse({ fired: 'load', status: x.status }); });
          x.open('GET', 'https://example.com/secret', true);
          x.send();
          return true;
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "xhrhost"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["fired"] as? String, "error", "an un-permitted host must fail closed (error, not load)")
        XCTAssertEqual(r["status"] as? Int, 0)
    }

    /// The blob: object-URL path: a sync XHR with the x-user-defined override yields a byte-preserving
    /// responseText (the fake-indexeddb contract), and responseType 'arraybuffer'/'blob' deliver the
    /// right types — all without touching the network.
    func testXHRBlobObjectURLAndResponseTypes() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'xhrblob') { return; }
          var text = 'GM_xhr bytes \\u2603';
          // byte-preserving sync read (the IndexedDB clone contract)
          var u1 = URL.createObjectURL(new Blob([text]));
          var x1 = new XMLHttpRequest();
          x1.overrideMimeType('text/plain; charset=x-user-defined');
          x1.open('GET', u1, false); x1.send();
          // reconstruct bytes from the byte-preserving string, decode as UTF-8 to compare
          var bytes = new Uint8Array(x1.responseText.length);
          for (var i = 0; i < x1.responseText.length; i++) { bytes[i] = x1.responseText.charCodeAt(i) & 0xff; }
          var decoded = new TextDecoder().decode(bytes);
          // responseType arraybuffer
          var u2 = URL.createObjectURL(new Blob([text]));
          var abResult = null;
          var x2 = new XMLHttpRequest(); x2.responseType = 'arraybuffer';
          x2.onload = function () {
            abResult = (x2.response instanceof ArrayBuffer) ? new TextDecoder().decode(new Uint8Array(x2.response)) : '(not-ab)';
            // responseType blob
            var u3 = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
            var x3 = new XMLHttpRequest(); x3.responseType = 'blob';
            x3.onload = function () {
              var isBlob = (typeof Blob === 'function') && (x3.response instanceof Blob);
              sendResponse({ decoded: decoded, status1: x1.status, abResult: abResult,
                             blobIsBlob: isBlob, blobType: x3.response ? x3.response.type : null });
            };
            x3.open('GET', u3, true); x3.send();
          };
          x2.open('GET', u2, true); x2.send();
          return true;
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "xhrblob"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "logs/result: \(String(describing: response))")
        let expected = "GM_xhr bytes ☃"
        XCTAssertEqual(r["status1"] as? Int, 200, "a blob: object URL resolves with status 200")
        XCTAssertEqual(r["decoded"] as? String, expected, "x-user-defined responseText must preserve every byte")
        XCTAssertEqual(r["abResult"] as? String, expected, "responseType 'arraybuffer' delivers the raw bytes")
        XCTAssertEqual(r["blobIsBlob"] as? Bool, true, "responseType 'blob' delivers a Blob")
        XCTAssertEqual(r["blobType"] as? String, "text/plain", "the Blob carries the content-type")
    }

    /// Response.blob() returns a real Blob carrying the response's content-type.
    func testResponseBlob() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'respblob') { return; }
          fetch('/does-not-exist.js').then(function (r) {
            return r.blob().then(function (b) {
              sendResponse({ isBlob: (typeof Blob === 'function') && (b instanceof Blob),
                             tag: Object.prototype.toString.call(b) });
            });
          }).catch(function (e) { sendResponse({ error: String(e) }); });
          return true;
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "respblob"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertNil(r["error"], "no error: \(r)")
        XCTAssertEqual(r["isBlob"] as? Bool, true, "Response.blob() must return a Blob")
        XCTAssertEqual(r["tag"] as? String, "[object Blob]")
    }
}
