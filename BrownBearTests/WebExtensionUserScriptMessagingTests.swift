//
//  WebExtensionUserScriptMessagingTests.swift
//  BrownBearTests
//
//  The MV3 User Scripts messaging channel: a USER_SCRIPT-world script's chrome.runtime.sendMessage lands
//  on chrome.runtime.onUserScriptMessage in the worker (NOT onMessage), with the normal request/response
//  + async-sendResponse contract. ScriptCat/Tampermonkey require this to run injected scripts. This boots
//  a worker, registers both listeners, and asserts a userScript message reaches onUserScriptMessage only.
//

import XCTest
@testable import BrownBear

final class WebExtensionUserScriptMessagingTests: XCTestCase {

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
            extensionID: extensionID, extensionName: "US",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.usmsg.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: #"{"manifest_version":3,"name":"US","version":"1.0","permissions":["userScripts"]}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    func testUserScriptMessageReachesOnUserScriptMessageOnly() async throws {
        let context = try makeContext(background: """
        self.__hitOnMessage = false;
        chrome.runtime.onMessage.addListener(function () { self.__hitOnMessage = true; });
        chrome.runtime.onUserScriptMessage.addListener(function (msg, sender, sendResponse) {
          // async sendResponse (the ScriptCat handshake shape).
          Promise.resolve().then(function () {
            sendResponse({ echo: msg && msg.x, channel: 'userScript', sawOnMessage: self.__hitOnMessage,
                           events: (typeof chrome.runtime.onUserScriptConnect === 'object') });
          });
          return true;
        });
        """)
        defer { context.shutdown() }

        let response = await context.fireUserScriptMessage(message: ["x": 42], sender: ["id": "abc"])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "onUserScriptMessage must answer")
        XCTAssertEqual(r["echo"] as? Int, 42, "the message reaches onUserScriptMessage")
        XCTAssertEqual(r["channel"] as? String, "userScript")
        XCTAssertEqual(r["sawOnMessage"] as? Bool, false, "a userScript message must NOT fire onMessage")
        XCTAssertEqual(r["events"] as? Bool, true, "chrome.runtime.onUserScriptConnect must exist (available)")
    }

    func testNoUserScriptListenerSignalsNoReceiver() async throws {
        // A worker with no onUserScriptMessage listener → the no-listener sentinel (so the sender can
        // surface "Receiving end does not exist."), exactly like onMessage.
        let context = try makeContext(background: "/* no listeners */ void 0;")
        defer { context.shutdown() }
        let response = await context.fireUserScriptMessage(message: ["x": 1], sender: [:])
        XCTAssertEqual(response?["__bbNoListener"] as? Bool, true)
    }
}
