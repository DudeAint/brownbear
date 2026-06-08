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

    // MARK: - onInstalled reason state machine (consumeInstallReason)

    /// The version-comparison state machine that drives chrome.runtime.onInstalled: first boot = install,
    /// a later boot at a new version = update (with previousVersion), same version again = no event.
    func testConsumeInstallReasonTransitions() {
        let id = "install-reason-\(UUID().uuidString)"   // unique id → clean UserDefaults slot

        let first = WebExtensionRuntime.consumeInstallReason(id, currentVersion: "1.0")
        XCTAssertEqual(first.reason, "install")
        XCTAssertNil(first.previousVersion)

        // Same version again on a later boot — no onInstalled (so first-run setup doesn't re-run).
        let reboot = WebExtensionRuntime.consumeInstallReason(id, currentVersion: "1.0")
        XCTAssertNil(reboot.reason)
        XCTAssertNil(reboot.previousVersion)

        // Bumped version — update, carrying the version it replaced.
        let updated = WebExtensionRuntime.consumeInstallReason(id, currentVersion: "2.0")
        XCTAssertEqual(updated.reason, "update")
        XCTAssertEqual(updated.previousVersion, "1.0")

        // Stable again at the new version — no further event.
        let settled = WebExtensionRuntime.consumeInstallReason(id, currentVersion: "2.0")
        XCTAssertNil(settled.reason)

        // Clean up the test's UserDefaults keys so it leaves no residue.
        UserDefaults.standard.removeObject(forKey: "brownbear.webext.installedVersion.\(id)")
        UserDefaults.standard.removeObject(forKey: "brownbear.webext.installedFired.\(id)")
    }

    /// An extension already installed under the pre-version scheme (legacy `installedFired` flag set,
    /// no stored version) must NOT spuriously re-fire `install` on its first post-upgrade boot.
    func testConsumeInstallReasonHonorsLegacyInstalledFlag() {
        let id = "legacy-\(UUID().uuidString)"
        UserDefaults.standard.set(true, forKey: "brownbear.webext.installedFired.\(id)")

        let result = WebExtensionRuntime.consumeInstallReason(id, currentVersion: "3.0")
        XCTAssertNil(result.reason, "a pre-versioning install must not re-fire onInstalled")

        // And now that the version is recorded, a real bump still produces an update.
        let bumped = WebExtensionRuntime.consumeInstallReason(id, currentVersion: "3.1")
        XCTAssertEqual(bumped.reason, "update")
        XCTAssertEqual(bumped.previousVersion, "3.0")

        UserDefaults.standard.removeObject(forKey: "brownbear.webext.installedVersion.\(id)")
        UserDefaults.standard.removeObject(forKey: "brownbear.webext.installedFired.\(id)")
    }
}
