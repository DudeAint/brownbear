//
//  WebExtensionBackgroundTests.swift
//  BrownBearTests
//
//  Boots a REAL extension background context (the bundled brownbear-webext-background.js running in
//  a JSContext) and drives it through the content→background message bus: synchronous sendResponse,
//  async sendResponse (return true + setTimeout), and chrome.storage round-trips against the shared
//  storage actor. This is the closest we get to a real service worker on iOS.
//

import XCTest
@testable import BrownBear

final class WebExtensionBackgroundTests: XCTestCase {

    struct RuntimeNotBundled: Error {}

    private func backgroundRuntimeSource() throws -> String {
        let url = Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-background", withExtension: "js")
        guard let url else { throw RuntimeNotBundled() }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBackgroundRuntimeIsBundled() {
        let url = Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-background", withExtension: "js")
        XCTAssertNotNil(url, "brownbear-webext-background.js must be in the app bundle")
    }

    private func makeContext(extensionID: String = "abcdefghijklmnopabcdefghijklmnop",
                             background: String,
                             storage: WebExtensionStorage) throws -> WebExtensionBackgroundContext {
        let runtime = try backgroundRuntimeSource()
        let context = WebExtensionBackgroundContext(
            extensionID: extensionID,
            extensionName: "Test",
            storage: storage,
            logSink: { _ in })
        context.boot(runtimeJS: runtime,
                     backgroundSource: background,
                     manifestJSON: #"{"manifest_version":3,"name":"Test","version":"1.0"}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    private func makeStorage() -> WebExtensionStorage {
        WebExtensionStorage(suiteName: "brownbear.webext.bgtest.\(UUID().uuidString)")
    }

    func testSynchronousSendResponse() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (msg && typeof msg.ping === 'number') { sendResponse({ pong: msg.ping + 1 }); }
        });
        """, storage: makeStorage())
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["ping": 41], sender: [:])
        let value = response?["value"] as? [String: Any]
        XCTAssertEqual(value?["pong"] as? Int, 42)
    }

    func testAsyncSendResponseViaSetTimeout() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (msg && msg.delay) {
            setTimeout(function () { sendResponse({ late: true }); }, 10);
            return true;   // keep the channel open
          }
        });
        """, storage: makeStorage())
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["delay": true], sender: [:])
        let value = response?["value"] as? [String: Any]
        XCTAssertEqual(value?["late"] as? Bool, true)
    }

    func testNoListenerReportsNoListenerMarker() async throws {
        // A worker with NO onMessage listener reports `{__bbNoListener:true}` (not nil), so the runtime
        // can raise Chrome's "Could not establish connection. Receiving end does not exist." on the
        // sender rather than silently resolving undefined. A declining listener (next test) does not.
        let context = try makeContext(background: "// no listeners here", storage: makeStorage())
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["x": 1], sender: [:])
        XCTAssertEqual(response?["__bbNoListener"] as? Bool, true)
    }

    func testDecliningListenerYieldsNilResponse() async throws {
        // A listener that exists but declines (returns undefined synchronously) is a receiving end —
        // the dispatch resolves to nil, NOT the no-listener marker (only total absence raises it).
        let context = try makeContext(
            background: "chrome.runtime.onMessage.addListener(function () { /* declines */ });",
            storage: makeStorage())
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["x": 1], sender: [:])
        XCTAssertNil(response)
    }

    func testStorageRoundTripFromBackground() async throws {
        let storage = makeStorage()
        let extID = "abcdefghijklmnopabcdefghijklmnop"
        let context = try makeContext(extensionID: extID, background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (msg && msg.store) {
            chrome.storage.local.set({ saved: msg.store }, function () {
              chrome.storage.local.get('saved', function (items) {
                sendResponse({ got: items.saved });
              });
            });
            return true;
          }
        });
        """, storage: storage)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["store": "hello"], sender: [:])
        let value = response?["value"] as? [String: Any]
        XCTAssertEqual(value?["got"] as? String, "hello")

        // It must have hit the shared storage actor (stored as a JSON-encoded string).
        let direct = await storage.get(extensionID: extID, area: .local, keys: ["saved"])
        XCTAssertEqual(direct["saved"], "\"hello\"")
    }

    func testGetManifestAndGetURL() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          sendResponse({ name: chrome.runtime.getManifest().name, url: chrome.runtime.getURL('x.js') });
        });
        """, storage: makeStorage())
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["q": 1], sender: [:])
        let value = response?["value"] as? [String: Any]
        XCTAssertEqual(value?["name"] as? String, "Test")
        XCTAssertEqual(value?["url"] as? String, "chrome-extension://abcdefghijklmnopabcdefghijklmnop/x.js")
    }
}
