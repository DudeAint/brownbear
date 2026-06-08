//
//  WebExtensionFetchRequestAbortTests.swift
//  BrownBearTests
//
//  Coverage for the fetch-family web globals a headless service worker previously lacked: AbortController/
//  AbortSignal and the Request constructor, plus fetch() honoring a Request input and an AbortSignal.
//  Extensions and fetch wrappers (uBlock Origin, ScriptCat, Grammarly) construct `new AbortController()`
//  and `new Request(...)` at init; their absence threw "Can't find variable: AbortController / Request".
//

import XCTest
@testable import BrownBear

final class WebExtensionFetchRequestAbortTests: XCTestCase {

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
            storage: WebExtensionStorage(suiteName: "brownbear.webext.fetchabort.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: #"{"manifest_version":3,"name":"Test","version":"1.0"}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    func testAbortControllerAndSignalSemantics() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'abort') { return; }
          var c = new AbortController();
          var firedListener = false, firedOnabort = false;
          c.signal.addEventListener('abort', function () { firedListener = true; });
          c.signal.onabort = function () { firedOnabort = true; };
          var abortedBefore = c.signal.aborted;
          c.abort();
          var threw = false, reasonName = '';
          try { c.signal.throwIfAborted(); } catch (e) { threw = true; reasonName = e && e.name; }
          var pre = AbortSignal.abort();
          sendResponse({
            hasController: typeof AbortController === 'function',
            hasSignal: typeof AbortSignal === 'function',
            abortedBefore: abortedBefore,
            abortedAfter: c.signal.aborted,
            firedListener: firedListener,
            firedOnabort: firedOnabort,
            threw: threw,
            reasonName: reasonName,
            staticAbortAborted: pre.aborted,
            hasTimeout: typeof AbortSignal.timeout === 'function'
          });
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "abort"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the worker must register its listener")
        XCTAssertEqual(r["hasController"] as? Bool, true)
        XCTAssertEqual(r["hasSignal"] as? Bool, true)
        XCTAssertEqual(r["abortedBefore"] as? Bool, false)
        XCTAssertEqual(r["abortedAfter"] as? Bool, true, "abort() must set signal.aborted")
        XCTAssertEqual(r["firedListener"] as? Bool, true, "addEventListener('abort') must fire")
        XCTAssertEqual(r["firedOnabort"] as? Bool, true, "onabort must fire")
        XCTAssertEqual(r["threw"] as? Bool, true, "throwIfAborted must throw once aborted")
        XCTAssertEqual(r["reasonName"] as? String, "AbortError", "the abort reason is an AbortError")
        XCTAssertEqual(r["staticAbortAborted"] as? Bool, true, "AbortSignal.abort() returns an already-aborted signal")
        XCTAssertEqual(r["hasTimeout"] as? Bool, true)
    }

    func testRequestConstructorAndClone() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'request') { return; }
          var r = new Request('https://example.com/api', {
            method: 'post', headers: { 'X-Test': 'yes', 'Content-Type': 'application/json' }, body: '{"a":1}'
          });
          var r2 = new Request(r);                       // construct from a Request copies its fields
          var c = r.clone();
          sendResponse({
            hasRequest: typeof Request === 'function',
            url: r.url,
            method: r.method,                            // normalized to upper-case
            header: r.headers.get('X-Test'),
            fromRequestUrl: r2.url,
            fromRequestMethod: r2.method,
            cloneUrl: c.url,
            cloneHeader: c.headers.get('content-type'),
            tag: Object.prototype.toString.call(r)
          });
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "request"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["hasRequest"] as? Bool, true)
        XCTAssertEqual(r["url"] as? String, "https://example.com/api")
        XCTAssertEqual(r["method"] as? String, "POST", "method must be upper-cased per spec")
        XCTAssertEqual(r["header"] as? String, "yes")
        XCTAssertEqual(r["fromRequestUrl"] as? String, "https://example.com/api", "new Request(req) copies the url")
        XCTAssertEqual(r["fromRequestMethod"] as? String, "POST")
        XCTAssertEqual(r["cloneUrl"] as? String, "https://example.com/api")
        XCTAssertEqual(r["cloneHeader"] as? String, "application/json", "clone preserves headers")
        XCTAssertEqual(r["tag"] as? String, "[object Request]")
    }

    /// fetch() must reject with an AbortError when handed an already-aborted signal, BEFORE touching the
    /// network — exactly like Chrome. This is deterministic (no native request is made).
    func testFetchWithAbortedSignalRejectsImmediately() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'abortfetch') { return; }
          var c = new AbortController();
          c.abort();
          fetch('https://example.com/x', { signal: c.signal }).then(
            function () { sendResponse({ rejected: false }); },
            function (e) { sendResponse({ rejected: true, name: e && e.name }); });
          return true;   // async response
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "abortfetch"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["rejected"] as? Bool, true, "fetch with a pre-aborted signal must reject")
        XCTAssertEqual(r["name"] as? String, "AbortError", "the rejection is an AbortError")
    }

    /// fetch(new Request(...)) must carry the Request's method through to the native gate — proven here by
    /// the host-permission failure path: a Request to an un-permitted host still fails closed (so the
    /// Request input was honored, not ignored).
    func testFetchAcceptsRequestInputAndStillGatesHost() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'reqfetch') { return; }
          fetch(new Request('https://example.com/data', { method: 'PUT' })).then(
            function () { sendResponse({ rejected: false }); },
            function (e) { sendResponse({ rejected: true, message: String(e) }); });
          return true;
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "reqfetch"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["rejected"] as? Bool, true, "a Request to an un-permitted host must fail closed")
        XCTAssertTrue((r["message"] as? String ?? "").contains("host permission"),
                      "fetch(Request) reached the host gate: \(r["message"] ?? "")")
    }
}
