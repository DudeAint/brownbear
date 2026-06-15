//
//  WebExtensionWARSchemeHandlerTests.swift
//  BrownBearTests
//
//  The security-critical gating for serving web_accessible_resources to normal pages: a file is served ONLY
//  when its path matches a declared `resources` glob AND the requesting page origin matches that entry's
//  `matches` (fail closed otherwise). MV2's string-array form is accessible to all origins (`<all_urls>`).
//  Pure logic — no WKWebView — so the gate that decides what leaks to a web page is fully unit-tested.
//

import XCTest
@testable import BrownBear

final class WebExtensionWARSchemeHandlerTests: XCTestCase {

    private func manifest(_ json: String) throws -> WebExtensionManifest {
        try WebExtensionManifest.parse(Data(json.utf8))
    }

    // MARK: - Path glob

    func testPathGlobMatching() {
        XCTAssertTrue(WebExtensionWARSchemeHandler.pathMatchesGlob("icons/16.png", "icons/*"))
        XCTAssertTrue(WebExtensionWARSchemeHandler.pathMatchesGlob("a/b/c.png", "*"), "* spans path separators")
        XCTAssertTrue(WebExtensionWARSchemeHandler.pathMatchesGlob("script.js", "*.js"))
        XCTAssertTrue(WebExtensionWARSchemeHandler.pathMatchesGlob("data.json", "data.json"), "literal match")
        XCTAssertFalse(WebExtensionWARSchemeHandler.pathMatchesGlob("script.css", "*.js"))
        XCTAssertFalse(WebExtensionWARSchemeHandler.pathMatchesGlob("img/a.png", "icons/*"))
        XCTAssertFalse(WebExtensionWARSchemeHandler.pathMatchesGlob("data.json.bak", "data.json"), "anchored")
    }

    // MARK: - Traversal rejection (the security gate that stops reading non-WAR files inside the dir)

    func testTraversalSegmentsAreRejected() {
        // A `*` glob would otherwise span these into a non-WAR file (manifest.json, background.js, …) that's
        // still inside the extension dir, which fileSync's outside-the-dir guard does NOT block.
        XCTAssertFalse(WebExtensionWARSchemeHandler.isTraversalFree("img/../background.js"))
        XCTAssertFalse(WebExtensionWARSchemeHandler.isTraversalFree("assets/../../manifest.json"))
        XCTAssertFalse(WebExtensionWARSchemeHandler.isTraversalFree("a/./b"))
        XCTAssertFalse(WebExtensionWARSchemeHandler.isTraversalFree(".."))
        // Confirm the glob alone IS permissive — proving the up-front reject is load-bearing, not redundant.
        XCTAssertTrue(WebExtensionWARSchemeHandler.pathMatchesGlob("img/../background.js", "img/*"))
        // Legitimate nested paths are fine.
        XCTAssertTrue(WebExtensionWARSchemeHandler.isTraversalFree("img/icons/16.png"))
        XCTAssertTrue(WebExtensionWARSchemeHandler.isTraversalFree("data.json"))
    }

    // MARK: - MV3 WAR: resources + per-origin matches

    func testMV3WebAccessibleGatesByPathAndOrigin() throws {
        let meta = try manifest("""
        {"manifest_version":3,"name":"X","version":"1.0",
         "web_accessible_resources":[{"resources":["img/*"],"matches":["*://*.example.com/*"]}]}
        """)
        // declared path + allowed origin → served
        XCTAssertTrue(WebExtensionWARSchemeHandler.isWebAccessible(
            path: "img/icon.png", pageURL: "https://a.example.com/page", manifest: meta))
        // declared path + DISALLOWED origin → blocked
        XCTAssertFalse(WebExtensionWARSchemeHandler.isWebAccessible(
            path: "img/icon.png", pageURL: "https://evil.com/page", manifest: meta),
            "a non-matching origin must not get the resource")
        // UNDECLARED path (even from an allowed origin) → blocked
        XCTAssertFalse(WebExtensionWARSchemeHandler.isWebAccessible(
            path: "secret.json", pageURL: "https://a.example.com/page", manifest: meta),
            "only declared resources are web-accessible")
        // unknowable origin + non-<all_urls> entry → fail closed
        XCTAssertFalse(WebExtensionWARSchemeHandler.isWebAccessible(
            path: "img/icon.png", pageURL: nil, manifest: meta),
            "a non-determinable page origin must fail closed for a per-origin entry")
    }

    // MARK: - MV2 WAR: string array ⇒ <all_urls>

    func testMV2WebAccessibleIsAllOrigins() throws {
        let meta = try manifest("""
        {"manifest_version":2,"name":"X","version":"1.0",
         "web_accessible_resources":["web/*.png","data.json"]}
        """)
        XCTAssertTrue(WebExtensionWARSchemeHandler.isWebAccessible(
            path: "web/a.png", pageURL: "https://anything.test/x", manifest: meta))
        // MV2 is all-origins, so even an unknowable origin is served.
        XCTAssertTrue(WebExtensionWARSchemeHandler.isWebAccessible(
            path: "data.json", pageURL: nil, manifest: meta))
        XCTAssertFalse(WebExtensionWARSchemeHandler.isWebAccessible(
            path: "background.js", pageURL: "https://anything.test/x", manifest: meta),
            "an undeclared file is never web-accessible")
    }

    func testNoWebAccessibleResourcesServesNothing() throws {
        let meta = try manifest(#"{"manifest_version":3,"name":"X","version":"1.0"}"#)
        XCTAssertFalse(WebExtensionWARSchemeHandler.isWebAccessible(
            path: "icon.png", pageURL: "https://a.example.com/x", manifest: meta),
            "no web_accessible_resources ⇒ nothing is served (status quo)")
    }
}
