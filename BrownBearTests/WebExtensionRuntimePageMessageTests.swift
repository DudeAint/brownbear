//
//  WebExtensionRuntimePageMessageTests.swift
//  BrownBearTests
//
//  Verifies the runtime.sendMessage fan-out into open extension PAGES (popups/options) — the fix for
//  "extension page chrome.runtime.onMessage never fires". Exercised against a fake event receiver so
//  the assertions are pure logic (no WKWebView): the runtime must deliver to a registered page of the
//  same extension, return its response, skip the sending page (no self-broadcast), and ignore pages of
//  a different extension. Per CLAUDE.md §6.
//

import XCTest
@testable import BrownBear

@MainActor
final class WebExtensionRuntimePageMessageTests: XCTestCase {

    /// Stands in for a live extension page session (which would push into a WKWebView). Records what it
    /// received and answers with a fixed response, mirroring the real page's self-broadcast exclusion.
    private final class FakePageReceiver: WebExtensionEventReceiver {
        let extID: String
        let token: String
        let answer: [String: Any]?
        private(set) var received: [(message: Any, senderToken: String?)] = []

        init(extID: String, token: String, answer: [String: Any]?) {
            self.extID = extID
            self.token = token
            self.answer = answer
        }

        var receiverExtensionID: String { extID }
        var receiverPermissions: Set<String> { [] }
        func dispatchExtEvent(name: String, argsJSON: String) {}

        func deliverRuntimeMessage(message: Any, sender: [String: Any],
                                   senderToken: String?) async -> [String: Any]? {
            if senderToken == token { return nil }   // a page never receives its own broadcast
            received.append((message, senderToken))
            return answer
        }
    }

    func testFansOutToPageAndReturnsResponse() async {
        let runtime = WebExtensionRuntime()
        let page = FakePageReceiver(extID: "extA", token: "pageA", answer: ["value": "pong"])
        runtime.registerEventReceiver(page)
        defer { runtime.unregisterEventReceiver(page) }

        let response = await runtime.sendRuntimeMessage(["ping": true], sender: ["id": "extA"],
                                                        to: "extA", senderToken: "content-token")
        XCTAssertEqual(response?["value"] as? String, "pong")
        XCTAssertEqual(page.received.count, 1)
        XCTAssertEqual((page.received.first?.message as? [String: Any])?["ping"] as? Bool, true)
    }

    func testSenderPageDoesNotReceiveItsOwnMessage() async {
        let runtime = WebExtensionRuntime()
        let page = FakePageReceiver(extID: "extA", token: "pageA", answer: ["value": "should-not-happen"])
        runtime.registerEventReceiver(page)
        defer { runtime.unregisterEventReceiver(page) }

        // The sender IS pageA, so it must be skipped — and with no other context, nothing answers.
        let response = await runtime.sendRuntimeMessage(["x": 1], sender: ["id": "extA"],
                                                        to: "extA", senderToken: "pageA")
        XCTAssertNil(response)
        XCTAssertTrue(page.received.isEmpty)
    }

    func testPagesOfOtherExtensionsAreNotDelivered() async {
        let runtime = WebExtensionRuntime()
        let other = FakePageReceiver(extID: "extB", token: "pageB", answer: ["value": "leak"])
        runtime.registerEventReceiver(other)
        defer { runtime.unregisterEventReceiver(other) }

        let response = await runtime.sendRuntimeMessage(["x": 1], sender: ["id": "extA"],
                                                        to: "extA", senderToken: nil)
        XCTAssertNil(response)
        XCTAssertTrue(other.received.isEmpty)
    }

    func testFirstAnsweringPageWins() async {
        let runtime = WebExtensionRuntime()
        let answering = FakePageReceiver(extID: "extA", token: "p1", answer: ["value": "first"])
        let silent = FakePageReceiver(extID: "extA", token: "p2", answer: nil)
        runtime.registerEventReceiver(answering)
        runtime.registerEventReceiver(silent)
        defer { runtime.unregisterEventReceiver(answering); runtime.unregisterEventReceiver(silent) }

        let response = await runtime.sendRuntimeMessage(["x": 1], sender: ["id": "extA"],
                                                        to: "extA", senderToken: nil)
        // Exactly one of the two answers; the non-nil one must win (a nil-answering page is skipped over).
        XCTAssertEqual(response?["value"] as? String, "first")
    }
}
