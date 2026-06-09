//
//  WebExtensionOffscreenManagerTests.swift
//  BrownBearTests
//
//  chrome.offscreen hosts a hidden real-DOM WKWebView at a PACKAGED extension URL. The path the worker
//  passes to createDocument is untrusted, so sanitizedPath must keep it inside this extension's package:
//  no traversal, no other extension's origin, no foreign scheme. Plus the createDocument precondition
//  gates (reasons / justification / single-document / host window) — all checkable without a web view.
//

import XCTest
@testable import BrownBear

final class WebExtensionOffscreenManagerTests: XCTestCase {

    private let extID = "abcdefghijklmnopabcdefghijklmnop"

    // MARK: - Path sanitation (the security boundary)

    func testRelativePathsAreAccepted() {
        XCTAssertEqual(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "offscreen.html"),
                       "offscreen.html")
        XCTAssertEqual(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "pages/off.html"),
                       "pages/off.html")
    }

    func testLeadingSlashesAndWhitespaceStripped() {
        XCTAssertEqual(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "  /off.html  "),
                       "off.html")
        XCTAssertEqual(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "///a/b.html"),
                       "a/b.html")
    }

    func testOwnAbsoluteExtensionURLIsReducedToRelative() {
        let abs = "chrome-extension://\(extID)/dir/off.html?x=1#frag"
        XCTAssertEqual(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: abs), "dir/off.html",
                       "this extension's own absolute URL → relative path, query/fragment dropped")
    }

    func testCrossExtensionURLRejected() {
        let other = "chrome-extension://zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/off.html"
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: other),
                     "another extension's origin must never be served as our offscreen doc")
    }

    func testForeignSchemesRejected() {
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "https://evil.example/x"))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "file:///etc/passwd"))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "javascript:alert(1)"))
    }

    func testTraversalRejected() {
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "../secret.html"))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "a/../../b.html"))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "../../../etc/passwd"))
    }

    func testTraversalHiddenAfterQueryStillRejected() {
        // The query is dropped first, but a traversal in the PATH portion before `?` must still fail.
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "../x.html?a=b"))
        // A literal "../" that only appears inside the query is harmless once the query is dropped.
        XCTAssertEqual(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "ok.html?to=../x"),
                       "ok.html")
    }

    func testEmptyRejected() {
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: ""))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "   "))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "/"))
    }

    // MARK: - createDocument preconditions (no web view needed — these gates run before hosting)

    @MainActor
    func testCreateDocumentValidationGates() async throws {
        let manager = WebExtensionOffscreenManager()
        guard let ext = Self.makeExtension(id: extID) else {
            throw XCTSkip("WebExtension is not trivially constructible in this test target")
        }

        let noReasons = await manager.createDocument(ext: ext, path: "off.html", reasons: [],
                                                     justification: "j", container: nil)
        XCTAssertNotNil(noReasons["error"], "missing reasons must reject")

        let noJustification = await manager.createDocument(ext: ext, path: "off.html", reasons: ["DOM_PARSER"],
                                                           justification: "  ", container: nil)
        XCTAssertNotNil(noJustification["error"], "missing justification must reject")

        // Valid request but no host window (container nil) — rejects, and creates nothing.
        let noWindow = await manager.createDocument(ext: ext, path: "off.html", reasons: ["DOM_PARSER"],
                                                    justification: "parse html", container: nil)
        XCTAssertNotNil(noWindow["error"])
        XCTAssertFalse(manager.hasDocument(extensionID: extID))
        XCTAssertFalse(manager.closeDocument(extensionID: extID), "nothing was created, so nothing to close")
    }

    /// Best-effort construction of a minimal WebExtension for the gate test; returns nil (→ skip) if the
    /// type can't be decoded from a manifest in this target.
    private static func makeExtension(id: String) -> WebExtension? {
        let manifest = #"{"manifest_version":3,"name":"Off","version":"1.0"}"#
        return WebExtension(id: id, manifestJSON: manifest)
    }
}
