//
//  ExtensionStoreSourceTests.swift
//  BrownBearTests
//
//  Detecting installable extension store pages across Chrome, Edge, and Firefox, plus the stable
//  per-source store id used to track "already installed".
//

import XCTest
@testable import BrownBear

final class ExtensionStoreSourceTests: XCTestCase {

    private let chromeID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
    private let edgeID = "odfafepnkmbhccpbejgmiehpchacaeak"

    private func url(_ string: String) -> URL { URL(string: string) ?? URL(fileURLWithPath: "/invalid") }

    func testDetectsChrome() {
        let source = ExtensionStoreSource.detect(url("https://chromewebstore.google.com/detail/ublock-origin/\(chromeID)"))
        XCTAssertEqual(source, .chrome(id: chromeID))
        XCTAssertEqual(source?.storeID, chromeID)   // bare id, backward-compatible
    }

    func testDetectsEdge() {
        let source = ExtensionStoreSource.detect(url("https://microsoftedge.microsoft.com/addons/detail/ublock-origin/\(edgeID)"))
        XCTAssertEqual(source, .edge(id: edgeID))
        XCTAssertEqual(source?.storeID, "edge:\(edgeID)")
    }

    func testDetectsFirefox() {
        let source = ExtensionStoreSource.detect(url("https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/"))
        XCTAssertEqual(source, .firefox(slug: "ublock-origin"))
        XCTAssertEqual(source?.storeID, "firefox:ublock-origin")
    }

    func testIgnoresNonStoreAndNonDetailPages() {
        XCTAssertNil(ExtensionStoreSource.detect(url("https://example.com/\(chromeID)")))
        XCTAssertNil(ExtensionStoreSource.detect(url("https://chromewebstore.google.com/category/extensions")))
        XCTAssertNil(ExtensionStoreSource.detect(url("https://microsoftedge.microsoft.com/addons")))
        XCTAssertNil(ExtensionStoreSource.detect(url("https://addons.mozilla.org/en-US/firefox/")))
    }

    func testDetectFromInputBareChromeId() {
        XCTAssertEqual(ExtensionStoreSource.detect(fromInput: chromeID), .chrome(id: chromeID))
        XCTAssertEqual(ExtensionStoreSource.detect(fromInput: "  \(chromeID)  "), .chrome(id: chromeID))
        XCTAssertNil(ExtensionStoreSource.detect(fromInput: "not an id or link"))
    }

    func testIsStoreURL() {
        XCTAssertTrue(ExtensionStoreSource.isStoreURL(url("https://chromewebstore.google.com/category/extensions")))
        XCTAssertTrue(ExtensionStoreSource.isStoreURL(url("https://microsoftedge.microsoft.com/addons")))
        XCTAssertTrue(ExtensionStoreSource.isStoreURL(url("https://addons.mozilla.org/en-US/firefox/")))
        XCTAssertFalse(ExtensionStoreSource.isStoreURL(url("https://example.com")))
    }
}
