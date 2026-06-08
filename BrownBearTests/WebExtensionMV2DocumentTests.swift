//
//  WebExtensionMV2DocumentTests.swift
//  BrownBearTests
//
//  Violentmonkey's MV2 background (a background PAGE in Chrome) touches `document` during its IndexedDB
//  "Upgrade database…" step. Our headless context had none, so it threw "Can't find variable: document"
//  and the failure cascaded (t.catch / InitPopup / "cannot connect to the background page"). We now
//  provide a minimal non-rendering DOM document for MV2 backgrounds — and deliberately NONE for MV3
//  service workers (Chrome SWs have no document; libraries feature-detect it).
//

import XCTest
@testable import BrownBear

final class WebExtensionMV2DocumentTests: XCTestCase {

    struct RuntimeNotBundled: Error {}

    private func backgroundRuntimeSource() throws -> String {
        let url = Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-background", withExtension: "js")
        guard let url else { throw RuntimeNotBundled() }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeContext(manifestJSON: String, background: String) throws -> WebExtensionBackgroundContext {
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let context = WebExtensionBackgroundContext(
            extensionID: extensionID,
            extensionName: "Test",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.mv2doc.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: manifestJSON,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    func testMV2BackgroundHasMinimalDocument() async throws {
        let manifest = #"{"manifest_version":2,"name":"VMDoc","version":"1.0","background":{"scripts":["bg.js"]}}"#
        // Touch `document` at top level (like VM does at init); if it threw, no listener would register.
        let context = try makeContext(manifestJSON: manifest, background: """
        var topLevelTag = document.createElement('div').tagName;   // must not throw at init
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'doc') { return; }
          var el = document.createElement('div');
          el.setAttribute('data-x', '5');
          var a = document.createElement('a');
          a.href = 'https://example.com:8443/p/q?x=1#h';
          var span = document.createElement('span');
          el.appendChild(span);
          sendResponse({
            hasDoc: typeof document === 'object' && document !== null,
            topLevelTag: topLevelTag,
            readyState: document.readyState,
            attr: el.getAttribute('data-x'),
            parsed: a.hostname + '|' + a.protocol + '|' + a.port + '|' + a.pathname + '|' + a.hash,
            childCount: el.children.length,
            textNode: document.createTextNode('hi').textContent,
            qsNull: document.querySelector('.nope') === null,
            hasHeadBody: !!document.head && !!document.body,
            createHTMLDoc: !!document.implementation.createHTMLDocument(),
            windowIsGlobal: window === globalThis
          });
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "doc"], sender: [:])
        XCTAssertNotEqual(response?["__bbNoListener"] as? Bool, true,
                          "touching document at init must not abort the background (it threw before)")
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the MV2 background must register its listener")
        XCTAssertEqual(r["hasDoc"] as? Bool, true)
        XCTAssertEqual(r["topLevelTag"] as? String, "DIV", "document is usable at top-level init")
        XCTAssertEqual(r["readyState"] as? String, "complete")
        XCTAssertEqual(r["attr"] as? String, "5", "setAttribute/getAttribute round-trip")
        XCTAssertEqual(r["parsed"] as? String, "example.com|https:|8443|/p/q|#h", "<a>.href parses the URL")
        XCTAssertEqual(r["childCount"] as? Int, 1, "appendChild tracks element children")
        XCTAssertEqual(r["textNode"] as? String, "hi")
        XCTAssertEqual(r["qsNull"] as? Bool, true)
        XCTAssertEqual(r["hasHeadBody"] as? Bool, true)
        XCTAssertEqual(r["createHTMLDoc"] as? Bool, true)
        XCTAssertEqual(r["windowIsGlobal"] as? Bool, true)
    }

    func testMV3ServiceWorkerHasNoDocument() async throws {
        let manifest = #"{"manifest_version":3,"name":"MV3","version":"1.0","background":{"service_worker":"sw.js"}}"#
        let context = try makeContext(manifestJSON: manifest, background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'doc' ) { return; }
          sendResponse({ hasDocument: typeof document !== 'undefined', hasWindow: typeof window !== 'undefined' });
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "doc"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["hasDocument"] as? Bool, false, "an MV3 service worker must not have a `document`")
        XCTAssertEqual(r["hasWindow"] as? Bool, false, "nor a `window`")
    }
}
