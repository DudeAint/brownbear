//
//  WebExtensionSchemeHandlerTests.swift
//  BrownBearTests
//
//  The chrome-extension:// scheme handler serves extension pages/resources. These cover the pure
//  response-header mapping: own-origin CORS, content type, and — the audit fix — emitting the manifest
//  Content-Security-Policy on HTML PAGES only (and never inventing a default for CSP-less manifests).
//  The full WKURLSchemeTask response path needs a live web view, so the header logic is tested directly.
//

import XCTest
@testable import BrownBear

final class WebExtensionSchemeHandlerTests: XCTestCase {

    private let extID = "abcdefghijklmnopabcdefghijklmnop"

    func testHTMLPageCarriesDeclaredCSP() {
        let csp = "script-src 'self'; object-src 'self'"
        let h = WebExtensionSchemeHandler.responseHeaders(path: "popup.html", dataCount: 10,
                                                          extensionID: extID, csp: csp)
        XCTAssertEqual(h["Content-Security-Policy"], csp)
        XCTAssertEqual(h["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(h["Access-Control-Allow-Origin"], "chrome-extension://\(extID)")
        XCTAssertEqual(h["Content-Length"], "10")
    }

    func testCSPlessHTMLPageHasNoCSPHeader() {
        let h = WebExtensionSchemeHandler.responseHeaders(path: "options.html", dataCount: 3,
                                                          extensionID: extID, csp: nil)
        XCTAssertNil(h["Content-Security-Policy"], "no default CSP must be invented for a CSP-less manifest")
    }

    func testEmptyCSPIsNotEmitted() {
        let h = WebExtensionSchemeHandler.responseHeaders(path: "popup.html", dataCount: 1,
                                                          extensionID: extID, csp: "")
        XCTAssertNil(h["Content-Security-Policy"])
    }

    func testNonHTMLResourceNeverCarriesCSP() {
        // Even if a CSP is passed, a JS/CSS subresource response must not carry the page CSP header.
        let js = WebExtensionSchemeHandler.responseHeaders(path: "bg.js", dataCount: 5,
                                                           extensionID: extID, csp: "script-src 'self'")
        XCTAssertNil(js["Content-Security-Policy"])
        XCTAssertEqual(js["Content-Type"], "text/javascript; charset=utf-8")
    }
}
