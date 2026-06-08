//
//  WebExtensionPageRelativePathTests.swift
//  BrownBearTests
//
//  chrome.tabs.create('chrome-extension://<id>/install.html?uuid=<id>') must preserve the query (and
//  fragment) so the opened page sees window.location.search. webExtCreateTab previously passed only
//  url.path to openExtensionPageTab, so ScriptCat's install page loaded with no uuid and reported no
//  data. extensionPageRelativePath keeps the suffix; the scheme handler still resolves files by path.
//

import XCTest
@testable import BrownBear

final class WebExtensionPageRelativePathTests: XCTestCase {

    private func rel(_ s: String) -> String? {
        BrownBearBrowserViewController.extensionPageRelativePath(from: URL(string: s)!)
    }

    func testPreservesQueryAndFragment() {
        XCTAssertEqual(rel("chrome-extension://abcdefghijklmnopabcdefghijklmnop/src/install.html?uuid=abc-123#sec"),
                       "src/install.html?uuid=abc-123#sec",
                       "the install page's ?uuid must survive chrome.tabs.create")
    }

    func testPreservesQueryOnly() {
        XCTAssertEqual(rel("chrome-extension://id/install.html?uuid=x&from=link"), "install.html?uuid=x&from=link")
    }

    func testBarePathUnchanged() {
        XCTAssertEqual(rel("chrome-extension://id/options.html"), "options.html")
    }

    func testNestedPathStripsLeadingSlashKeepsQuery() {
        XCTAssertEqual(rel("chrome-extension://id/a/b/c.html?x=1"), "a/b/c.html?x=1")
    }

    func testBareOriginIsNil() {
        XCTAssertNil(rel("chrome-extension://id/"), "a bare origin has no page path")
        XCTAssertNil(rel("chrome-extension://id"))
    }
}
