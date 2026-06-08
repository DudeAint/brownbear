//
//  WebExtensionWebRequestUserScriptTests.swift
//  BrownBearTests
//
//  Violentmonkey (MV2) claims `.user.js` navigations with a blocking webRequest.onBeforeRequest listener
//  filtered to `*://*/*.user.js` — but WebKit never fires webRequest, so VM's install never ran. The
//  runtime now RECORDS that listener with its url/type filter and exposes __bbDispatchWebRequestUserScript
//  so the native navigation delegate can synthesize a main-frame onBeforeRequest for a `.user.js` URL,
//  invoking the manager's own confirm flow. This boots the real background context and verifies the
//  dispatcher: a matching listener fires with a correct details object; a non-matching URL does not.
//

import XCTest
@testable import BrownBear

final class WebExtensionWebRequestUserScriptTests: XCTestCase {

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
            storage: WebExtensionStorage(suiteName: "brownbear.webext.webreq.\(UUID().uuidString)"),
            logSink: { _ in })
        // MV2 manifest: VM-style background page that registers a blocking webRequest listener.
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: #"{"manifest_version":2,"name":"VM","version":"1.0","background":{"scripts":["bg.js"]}}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    func testOnBeforeRequestFilterIsRecordedAndDispatched() async throws {
        let context = try makeContext(background: """
        var captured = null, calls = 0;
        chrome.webRequest.onBeforeRequest.addListener(function (details) {
          calls++; captured = details;
          return { cancel: true };   // VM returns a blocking response; we don't act on it
        }, { urls: ['*://*/*.user.js', '*://*/*.user.js?*'], types: ['main_frame'] }, ['blocking']);
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'webreq') { return; }
          var handledMatch = __bbDispatchWebRequestUserScript('https://greasyfork.org/scripts/1/code/foo.user.js', -1);
          var d = captured;
          captured = null;
          var handledNonMatch = __bbDispatchWebRequestUserScript('https://example.com/page.html', -1);
          sendResponse({
            handledMatch: handledMatch,
            url: d ? d.url : null,
            type: d ? d.type : null,
            method: d ? d.method : null,
            tabId: d ? d.tabId : null,
            handledNonMatch: handledNonMatch,
            nonMatchFired: captured !== null,
            totalCalls: calls
          });
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "webreq"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the worker must register its listener")
        XCTAssertEqual(r["handledMatch"] as? Bool, true, "a .user.js URL matching the filter must invoke the listener")
        XCTAssertEqual(r["url"] as? String, "https://greasyfork.org/scripts/1/code/foo.user.js")
        XCTAssertEqual(r["type"] as? String, "main_frame")
        XCTAssertEqual(r["method"] as? String, "GET")
        XCTAssertEqual(r["tabId"] as? Int, -1)
        XCTAssertEqual(r["handledNonMatch"] as? Bool, false, "a non-.user.js URL must NOT match the filter")
        XCTAssertEqual(r["nonMatchFired"] as? Bool, false)
        XCTAssertEqual(r["totalCalls"] as? Int, 1, "the listener fired exactly once (only for the matching URL)")
    }

    /// A listener with no main_frame in its types must not be invoked for a main-frame navigation.
    func testNonMainFrameListenerNotDispatched() async throws {
        let context = try makeContext(background: """
        var fired = false;
        chrome.webRequest.onBeforeRequest.addListener(function () { fired = true; },
          { urls: ['*://*/*.user.js'], types: ['xmlhttprequest'] });
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'webreq2') { return; }
          var handled = __bbDispatchWebRequestUserScript('https://x.com/a.user.js', -1);
          sendResponse({ handled: handled, fired: fired });
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "webreq2"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["handled"] as? Bool, false, "a non-main_frame filter must not match a main-frame nav")
        XCTAssertEqual(r["fired"] as? Bool, false)
    }
}
