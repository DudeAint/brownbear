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

    // MARK: - isBlockedHost (SSRF gate)

    func testBlockedHostsRejected() {
        for host in ["127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "172.31.255.255",
                     "169.254.169.254", "localhost", "foo.local", "evil.localhost",
                     "::1", "[::1]", "fc00::1", "fd12::9", "fe80::1"] {
            XCTAssertTrue(WebExtensionFetchSecurity.isBlockedHost(host), "should block \(host)")
        }
    }

    func testPublicHostsAllowed() {
        for host in ["example.com", "8.8.8.8", "172.15.0.1", "172.32.0.1", "203.0.113.5",
                     "fcdn.example.com", "fdsa.io", "feature.dev", "2606:4700:4700::1111"] {
            XCTAssertFalse(WebExtensionFetchSecurity.isBlockedHost(host),
                           "should allow public host \(host)")
        }
        XCTAssertFalse(WebExtensionFetchSecurity.isBlockedHost(nil))
        XCTAssertFalse(WebExtensionFetchSecurity.isBlockedHost(""))
    }
}
