//
//  WebExtensionMatchPatternTests.swift
//  BrownBearTests
//
//  The webRequest `.user.js` hand-off matches the navigation URL against each listener's url filter
//  (Chrome match-patterns: <scheme>://<host><path>). This boots the real background runtime, registers
//  onBeforeRequest listeners with a spread of patterns, and dispatches URLs to assert exactly which
//  patterns match — the correctness the install-target detection depends on (a wrong matcher would
//  list, or hide, a userscript manager).
//

import XCTest
@testable import BrownBear

final class WebExtensionMatchPatternTests: XCTestCase {

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
            extensionID: extensionID, extensionName: "MP",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.mp.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: #"{"manifest_version":2,"name":"MP","version":"1.0","background":{"scripts":["bg.js"]}}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    func testMatchPatternSpread() async throws {
        let context = try makeContext(background: """
        function reg(pattern) {
          chrome.webRequest.onBeforeRequest.addListener(function () { window.__fired.push(pattern); },
            { urls: [pattern], types: ['main_frame'] });
        }
        window.__fired = [];
        reg('*://*/*.user.js');
        reg('*://*.example.com/*');
        reg('<all_urls>');
        reg('https://only.com/*');
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'mp') { return; }
          function probe(url) { window.__fired = []; __bbDispatchWebRequestUserScript(url, -1); return window.__fired.slice().sort().join(','); }
          sendResponse({
            userjs:     probe('https://x.com/a.user.js'),
            subdomain:  probe('https://sub.example.com/p'),
            apex:       probe('https://example.com/p'),
            notexample: probe('https://notexample.com/p'),
            onlycom:    probe('https://only.com/page'),
            onlysub:    probe('https://sub.only.com/page'),
            plain:      probe('http://random.org/index.html')
          });
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "mp"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the worker must register its listener")
        // `<all_urls>` matches every http(s); the others match their own shape only. (Sorted, comma-joined.)
        XCTAssertEqual(r["userjs"] as? String, "*://*/*.user.js,<all_urls>")
        XCTAssertEqual(r["subdomain"] as? String, "*://*.example.com/*,<all_urls>")
        XCTAssertEqual(r["apex"] as? String, "*://*.example.com/*,<all_urls>", "*.example.com matches the apex too")
        XCTAssertEqual(r["notexample"] as? String, "<all_urls>", "*.example.com must NOT match notexample.com")
        XCTAssertEqual(r["onlycom"] as? String, "<all_urls>,https://only.com/*")
        XCTAssertEqual(r["onlysub"] as? String, "<all_urls>", "an exact host pattern must not match a subdomain")
        XCTAssertEqual(r["plain"] as? String, "<all_urls>", "a non-.user.js, non-matching URL → only <all_urls>")
    }
}
