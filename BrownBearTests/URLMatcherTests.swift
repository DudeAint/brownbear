//
//  URLMatcherTests.swift
//  BrownBearTests
//
//  Tests for Chrome match-pattern + glob/regex include/exclude semantics, including exclusion
//  precedence and the http/https-only rule for @match.
//

import XCTest
@testable import BrownBear

final class URLMatcherTests: XCTestCase {

    private func matcher(match: [String] = [], include: [String] = [],
                         exclude: [String] = [], excludeMatch: [String] = []) -> URLMatcher {
        URLMatcher(matches: match, includes: include, excludes: exclude, excludeMatches: excludeMatch)
    }

    func testSubdomainWildcardMatchesHostAndSubdomains() {
        let m = matcher(match: ["*://*.example.com/*"])
        XCTAssertTrue(m.matches("https://www.example.com/page"))
        XCTAssertTrue(m.matches("https://example.com/"))
        XCTAssertTrue(m.matches("http://a.b.example.com/x?y=1"))
        XCTAssertFalse(m.matches("https://evil.com/example.com"))
        XCTAssertFalse(m.matches("https://notexample.com/"))
    }

    func testSchemeSpecificMatch() {
        let m = matcher(match: ["https://secure.test/*"])
        XCTAssertTrue(m.matches("https://secure.test/x"))
        XCTAssertFalse(m.matches("http://secure.test/x"))
    }

    func testAllURLsMatchesHTTPOnly() {
        let m = matcher(match: ["<all_urls>"])
        XCTAssertTrue(m.matches("https://anything.example/"))
        XCTAssertTrue(m.matches("http://plain.test/path"))
        XCTAssertFalse(m.matches("file:///etc/hosts"))
        XCTAssertFalse(m.matches("about:blank"))
    }

    func testPathWildcard() {
        let m = matcher(match: ["https://example.com/foo/*"])
        XCTAssertTrue(m.matches("https://example.com/foo/bar"))
        XCTAssertTrue(m.matches("https://example.com/foo/"))
        XCTAssertFalse(m.matches("https://example.com/other"))
    }

    func testExclusionWins() {
        // @exclude-match uses Chrome match-pattern semantics (subdomain-aware), so this excludes
        // the apex host too. (@exclude on its own is a plain glob — see testExcludeGlobApex.)
        let m = matcher(match: ["*://*.example.com/*"],
                        excludeMatch: ["*://*.example.com/private/*"])
        XCTAssertTrue(m.matches("https://example.com/public"))
        XCTAssertFalse(m.matches("https://example.com/private/secret"))
        XCTAssertFalse(m.matches("https://www.example.com/private/x"))
    }

    func testExcludeGlobApex() {
        // A plain @exclude glob is matched against the full URL; this one covers the apex host.
        let m = matcher(match: ["*://*.example.com/*"],
                        exclude: ["*example.com/private/*"])
        XCTAssertTrue(m.matches("https://example.com/public"))
        XCTAssertFalse(m.matches("https://example.com/private/secret"))
    }

    func testExcludeMatchUsesMatchPatternSemantics() {
        let m = matcher(match: ["<all_urls>"],
                        excludeMatch: ["https://blocked.test/*"])
        XCTAssertTrue(m.matches("https://allowed.test/"))
        XCTAssertFalse(m.matches("https://blocked.test/anything"))
    }

    func testIncludeGlob() {
        let m = matcher(include: ["*://*.test.com/*"])
        XCTAssertTrue(m.matches("https://sub.test.com/page"))
        XCTAssertFalse(m.matches("https://test.org/"))
    }

    func testIncludeRegex() {
        let m = matcher(include: ["/^https:\\/\\/foo\\.bar\\//"])
        XCTAssertTrue(m.matches("https://foo.bar/baz"))
        XCTAssertFalse(m.matches("https://other.bar/"))
    }

    func testNoDirectivesMatchesNothing() {
        let m = matcher()
        XCTAssertFalse(m.matches("https://example.com/"))
    }

    func testMatchPatternIgnoresNonHTTP() {
        let m = matcher(match: ["*://*/*"])
        XCTAssertTrue(m.matches("https://example.com/"))
        XCTAssertFalse(m.matches("ftp://example.com/"))
    }
}
