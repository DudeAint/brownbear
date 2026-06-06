//
//  WebExtensionPageTests.swift
//  BrownBearTests
//
//  Module 6 Phase 3: the chrome-extension:// scheme handler's content-type mapping (pure) and a
//  guard that the extension page runtime is actually bundled (so popups/options can load).
//

import XCTest
@testable import BrownBear

final class WebExtensionPageTests: XCTestCase {

    func testSchemeHandlerMIMETypes() {
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "popup.html"), "text/html; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "ui/options.htm"), "text/html; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "js/popup.js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "style.css"), "text/css; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "data.json"), "application/json; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "icon.png"), "image/png")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "logo.svg"), "image/svg+xml")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "font.woff2"), "font/woff2")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "blob.bin"), "application/octet-stream")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "noext"), "application/octet-stream")
    }

    func testPageRuntimeIsBundled() {
        let url = Bundle.main.url(forResource: "brownbear-webext-page", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-page", withExtension: "js")
        XCTAssertNotNil(url, "brownbear-webext-page.js must be bundled so popup/options pages get chrome.*")
    }
}
