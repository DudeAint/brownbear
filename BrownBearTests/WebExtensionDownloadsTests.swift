//
//  WebExtensionDownloadsTests.swift
//  BrownBearTests
//
//  chrome.downloads security helpers: the suggested filename is attacker-controlled (it must collapse to
//  a single safe path component — no traversal), and request headers must reject CRLF/NUL injection and
//  the connection-control headers URLSession owns.
//

import XCTest
@testable import BrownBear

final class WebExtensionDownloadsTests: XCTestCase {

    // MARK: - sanitizedFilename

    func testFilenameStripsPathToLastComponent() {
        XCTAssertEqual(WebExtensionDownloadsManager.sanitizedFilename("report.pdf", fallback: "x"), "report.pdf")
        XCTAssertEqual(WebExtensionDownloadsManager.sanitizedFilename("a/b/c.zip", fallback: "x"), "c.zip")
        XCTAssertEqual(WebExtensionDownloadsManager.sanitizedFilename("../../etc/passwd", fallback: "x"), "passwd")
    }

    func testFilenameFallsBackWhenEmptyOrDotty() {
        XCTAssertEqual(WebExtensionDownloadsManager.sanitizedFilename("", fallback: "host.com"), "host.com")
        XCTAssertEqual(WebExtensionDownloadsManager.sanitizedFilename("   ", fallback: "host.com"), "host.com")
        XCTAssertEqual(WebExtensionDownloadsManager.sanitizedFilename("..", fallback: "host.com"), "host.com")
        // A fallback that is itself path-like collapses too; an empty fallback degrades to "download".
        XCTAssertEqual(WebExtensionDownloadsManager.sanitizedFilename("", fallback: ""), "download")
    }

    func testFilenameStripsNulAndSlashes() {
        XCTAssertFalse(WebExtensionDownloadsManager.sanitizedFilename("a\u{0}b.txt", fallback: "x").contains("\u{0}"))
        XCTAssertFalse(WebExtensionDownloadsManager.sanitizedFilename("weird/name.txt", fallback: "x").contains("/"))
    }

    // MARK: - isSafeHeader

    func testSafeHeaderAcceptsNormal() {
        XCTAssertTrue(WebExtensionDownloadsManager.isSafeHeader(name: "Authorization", value: "Bearer abc"))
        XCTAssertTrue(WebExtensionDownloadsManager.isSafeHeader(name: "X-Custom", value: "value-123"))
    }

    func testSafeHeaderRejectsInjectionAndControlled() {
        XCTAssertFalse(WebExtensionDownloadsManager.isSafeHeader(name: "X-Bad", value: "a\r\nInjected: 1"),
                       "CRLF in a value is header injection")
        XCTAssertFalse(WebExtensionDownloadsManager.isSafeHeader(name: "X-Bad", value: "a\u{0}b"),
                       "NUL in a value is rejected")
        XCTAssertFalse(WebExtensionDownloadsManager.isSafeHeader(name: "Bad Name", value: "v"),
                       "a non-token header name (space) is rejected")
        XCTAssertFalse(WebExtensionDownloadsManager.isSafeHeader(name: "Host", value: "evil.com"),
                       "Host is owned by URLSession")
        XCTAssertFalse(WebExtensionDownloadsManager.isSafeHeader(name: "content-length", value: "0"),
                       "Content-Length is owned by URLSession")
        XCTAssertFalse(WebExtensionDownloadsManager.isSafeHeader(name: "", value: "v"))
    }
}
