//
//  WebExtensionMessageSenderTests.swift
//  BrownBearTests
//
//  Verifies the chrome.runtime.MessageSender shape the router hands to onMessage listeners matches
//  Chrome exactly: a content script's sender carries `tab` (so a background listener can reply via
//  chrome.tabs.sendMessage(sender.tab.id, …)), plus `frameId`, `documentId`, `url`, and `origin`; a
//  popup/options page's sender omits `tab`/`frameId`/`documentId` (Chrome attaches `tab` iff the
//  sender runs in a tab). Pure assembly logic, exercised without a host/WKWebView. Per CLAUDE.md §6.
//

import XCTest
@testable import BrownBear

@MainActor
final class WebExtensionMessageSenderTests: XCTestCase {

    func testContentScriptSenderCarriesTabFrameAndOrigin() {
        let tab: [String: Any] = ["id": 7, "url": "https://example.com/", "windowId": 1, "active": true]
        let sender = WebExtensionMessageRouter.assembleSender(
            extensionID: "abcdefghijklmnopabcdefghijklmnop",
            url: "https://example.com/page?q=1",
            tabRecord: tab, frameId: 0, documentId: "0123456789abcdef0123456789abcdef")

        XCTAssertEqual(sender["id"] as? String, "abcdefghijklmnopabcdefghijklmnop")
        XCTAssertEqual(sender["url"] as? String, "https://example.com/page?q=1")
        XCTAssertEqual(sender["origin"] as? String, "https://example.com")
        XCTAssertEqual((sender["tab"] as? [String: Any])?["id"] as? Int, 7)
        XCTAssertEqual(sender["frameId"] as? Int, 0)
        XCTAssertEqual(sender["documentId"] as? String, "0123456789abcdef0123456789abcdef")
    }

    func testSubframeSenderReportsNonZeroFrameId() {
        let tab: [String: Any] = ["id": 3, "windowId": 1]
        let sender = WebExtensionMessageRouter.assembleSender(
            extensionID: "ext", url: "https://sub.example.com/frame",
            tabRecord: tab, frameId: 12, documentId: "doc")
        XCTAssertEqual(sender["frameId"] as? Int, 12)
        XCTAssertEqual(sender["origin"] as? String, "https://sub.example.com")
    }

    func testPageSenderOmitsTabAndFrameFields() {
        // A popup/options page is not a browser tab → host resolves no tab record → no tab/frame/doc.
        let sender = WebExtensionMessageRouter.assembleSender(
            extensionID: "ext", url: "chrome-extension://ext/popup.html",
            tabRecord: nil, frameId: 0, documentId: "ignored")

        XCTAssertEqual(sender["id"] as? String, "ext")
        XCTAssertEqual(sender["url"] as? String, "chrome-extension://ext/popup.html")
        XCTAssertEqual(sender["origin"] as? String, "chrome-extension://ext")
        XCTAssertNil(sender["tab"])
        XCTAssertNil(sender["frameId"])
        XCTAssertNil(sender["documentId"])
    }

    func testOriginlessUrlYieldsNoOrigin() {
        // about:blank / data: have no host — Chrome omits `origin` rather than inventing one.
        let sender = WebExtensionMessageRouter.assembleSender(
            extensionID: "ext", url: "about:blank", tabRecord: ["id": 1], frameId: 0, documentId: "d")
        XCTAssertEqual(sender["url"] as? String, "about:blank")
        XCTAssertNil(sender["origin"])
    }

    func testOriginPreservesNonDefaultPort() {
        XCTAssertEqual(WebExtensionMessageRouter.origin(ofURLString: "http://localhost:8080/x"),
                       "http://localhost:8080")
        XCTAssertEqual(WebExtensionMessageRouter.origin(ofURLString: "https://a.test/"), "https://a.test")
        XCTAssertNil(WebExtensionMessageRouter.origin(ofURLString: "about:blank"))
    }

    func testNoUrlYieldsBareIdSender() {
        let sender = WebExtensionMessageRouter.assembleSender(
            extensionID: "ext", url: nil, tabRecord: nil, frameId: 0, documentId: nil)
        XCTAssertEqual(sender["id"] as? String, "ext")
        XCTAssertNil(sender["url"])
        XCTAssertNil(sender["origin"])
        XCTAssertNil(sender["tab"])
    }
}
