//
//  WebExtensionBackgroundPageTests.swift
//  BrownBearTests
//
//  MV2 `background.page` script extraction (WebExtensionRuntime.scriptTags). uBlock Origin's
//  background.html is the motivating shape: classic <script src> tags (lz4 codec, vapi.js) followed by
//  a `type="module"` entry (js/start.js) — the tags ARE the background, in document order. The parser
//  must tolerate attribute-order variants, resolve src against the page's directory, treat
//  root-relative paths as package-absolute, and skip inline scripts (CSP forbids them anyway).
//

import XCTest
@testable import BrownBear

final class WebExtensionBackgroundPageTests: XCTestCase {

    func testUBlockOriginBackgroundPageShape() {
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>uBlock Origin</title></head>
        <body>
        <script src="lib/lz4/lz4-block-codec-any.js"></script>
        <script src="js/vapi.js"></script>
        <script src="js/start.js" type="module"></script>
        </body></html>
        """
        let tags = WebExtensionRuntime.scriptTags(inBackgroundPage: html, pagePath: "background.html")
        XCTAssertEqual(tags.map(\.path), ["lib/lz4/lz4-block-codec-any.js", "js/vapi.js", "js/start.js"])
        XCTAssertEqual(tags.map(\.isModule), [false, false, true])
    }

    func testModuleAttributeBeforeSrc() {
        let html = #"<script type="module" src="js/entry.js"></script>"#
        let tags = WebExtensionRuntime.scriptTags(inBackgroundPage: html, pagePath: "background.html")
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].path, "js/entry.js")
        XCTAssertTrue(tags[0].isModule)
    }

    func testSrcResolvesAgainstNestedPageDirectory() {
        let html = #"<script src="bg.js"></script><script src="/abs/x.js"></script>"#
        let tags = WebExtensionRuntime.scriptTags(inBackgroundPage: html, pagePath: "pages/background.html")
        XCTAssertEqual(tags.map(\.path), ["pages/bg.js", "abs/x.js"])
    }

    func testInlineScriptsAndSingleQuotesHandled() {
        let html = """
        <script>var inline = 1;</script>
        <script src='js/single.js'></script>
        """
        let tags = WebExtensionRuntime.scriptTags(inBackgroundPage: html, pagePath: "background.html")
        XCTAssertEqual(tags.map(\.path), ["js/single.js"])
        XCTAssertFalse(tags[0].isModule)
    }

    func testNoScriptsReturnsEmpty() {
        XCTAssertTrue(WebExtensionRuntime.scriptTags(inBackgroundPage: "<html><body/></html>",
                                                     pagePath: "background.html").isEmpty)
    }
}
