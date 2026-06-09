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
        // Both `scheme://` and single-colon schemes — a packaged relative path never contains a colon.
        for raw in ["https://evil.example/x", "file:///etc/passwd", "javascript:alert(1)",
                    "data:text/html,<script>1</script>", "mailto:a@b.com", "file%3a.html"] {
            XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: raw),
                         "a colon-bearing (scheme-like) path must be rejected: \(raw)")
        }
    }

    func testTraversalRejected() {
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "../secret.html"))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "a/../../b.html"))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "../../../etc/passwd"))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "a/./b.html"),
                     "a lone `.` segment is rejected")
    }

    func testPercentEncodedTraversalRejected() {
        // WebExtensionSchemeHandler reads url.path (percent-DECODED), so an encoded `..`/`/`/`\` would
        // reach the store as a traversal. The sanitizer must decode before scanning.
        for raw in ["%2e%2e/secret.html", "%2E%2E%2Fsecret.html", "..%2fsecret.html",
                    "a%2f..%2fb.html", "a%5c..%5cb.html", "%2e%2e%2f%2e%2e%2fetc%2fpasswd",
                    "%252e%252e/x.html"] {   // double-encoded
            XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: raw),
                         "percent-encoded traversal must be rejected: \(raw)")
        }
    }

    func testBackslashTraversalRejected() {
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "..\\secret.html"))
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "a\\..\\b.html"))
    }

    func testControlCharsRejected() {
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "off\u{0}.html"),
                     "embedded NUL truncates at the C-string boundary — reject")
        XCTAssertNil(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "a%00b.html"),
                     "percent-encoded NUL must be rejected too")
    }

    func testLegitEncodedFilenameAccepted() {
        // A real packaged filename with an encoded space must survive (only traversal is rejected).
        XCTAssertEqual(WebExtensionOffscreenManager.sanitizedPath(extID: extID, rawPath: "my%20file.html"),
                       "my%20file.html")
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
