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

    // MARK: - IPv6 literals

    func testIPv6LiteralMatchPattern() {
        let m = matcher(match: ["https://[::1]/*"])
        XCTAssertTrue(m.matches("https://[::1]/dashboard"))
        XCTAssertTrue(m.matches("https://[::1]/"))
        XCTAssertFalse(m.matches("http://[::1]/x"), "scheme must still be honored")
        XCTAssertFalse(m.matches("https://[::2]/x"), "a different address must not match")
        XCTAssertFalse(m.matches("https://example.com/x"))
    }

    func testFullIPv6AddressMatchPattern() {
        let m = matcher(match: ["*://[2001:db8::1]/*"])
        XCTAssertTrue(m.matches("https://[2001:db8::1]/app"))
        XCTAssertTrue(m.matches("http://[2001:db8::1]/"))
        XCTAssertTrue(m.matches("https://[2001:DB8::1]/x"), "IPv6 hex is case-insensitive")
        XCTAssertFalse(m.matches("https://[2001:db8::2]/"))
    }

    func testWildcardHostAndAllUrlsCoverIPv6() {
        XCTAssertTrue(matcher(match: ["*://*/*"]).matches("https://[::1]/x"))
        XCTAssertTrue(matcher(match: ["<all_urls>"]).matches("https://[fe80::1]/y"))
    }

    // MARK: - Regression: existing host classes must be UNCHANGED by the IPv6 alternation

    func testHostClassesStillMatchAfterIPv6Support() {
        XCTAssertTrue(matcher(match: ["https://example.com/*"]).matches("https://example.com/a"))
        XCTAssertTrue(matcher(match: ["https://*.example.com/*"]).matches("https://www.example.com/a"))
        XCTAssertTrue(matcher(match: ["https://127.0.0.1/*"]).matches("https://127.0.0.1/a"))
        XCTAssertTrue(matcher(match: ["http://localhost/*"]).matches("http://localhost/a"))
        XCTAssertFalse(matcher(match: ["https://example.com/*"]).matches("https://evil.com/a"))
        XCTAssertFalse(matcher(match: ["https://127.0.0.1/*"]).matches("https://127.0.0.2/a"))
    }
}
