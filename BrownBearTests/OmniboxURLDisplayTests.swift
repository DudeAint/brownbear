//
//  OmniboxURLDisplayTests.swift
//  BrownBearTests
//
//  Table-driven tests for the omnibox's host-emphasis logic — the substring of a URL that receives
//  the primary "this is the site you're on" highlight. This is anti-spoofing-critical: the emphasis
//  must land on the real AUTHORITY host, never on a look-alike host smuggled into the userinfo, and
//  the displayed text is always the URL verbatim (no percent-decoding, no dropped components).
//

import XCTest
@testable import BrownBear

final class OmniboxURLDisplayTests: XCTestCase {

    /// Resolve a URL string to (emphasized text, byte offset of the emphasis start) via the pure
    /// `OmniboxView.hostEmphasisRange` helper, the same logic the bar renders.
    private func emphasis(_ urlString: String) -> (text: String, offset: Int)? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        let full = url.absoluteString
        guard let range = OmniboxView.hostEmphasisRange(in: full, host: host) else { return nil }
        return (String(full[range]), full.distance(from: full.startIndex, to: range.lowerBound))
    }

    func testEmphasizesRegistrableHost() {
        XCTAssertEqual(emphasis("https://example.com/")?.text, "example.com")
        XCTAssertEqual(emphasis("https://www.example.com/")?.text, "example.com")     // www. dimmed
        XCTAssertEqual(emphasis("https://example.com:8443/p")?.text, "example.com")   // port dimmed
        XCTAssertEqual(emphasis("https://example.com/a/b?q=1#f")?.text, "example.com")
    }

    func testDoesNotOverTrimWWWWhenItIsTheRegistrableLabel() {
        // "www.com" has no further dot, so "www" is not a subdomain to strip.
        XCTAssertEqual(emphasis("https://www.com/")?.text, "www.com")
    }

    func testEmphasizesAuthorityHostNotUserinfoLookalike() {
        // Anti-spoof: a userinfo crafted to contain the authority host must NOT steal the emphasis.
        let a = emphasis("https://real.com@evil.com/")
        XCTAssertEqual(a?.text, "evil.com")
        XCTAssertEqual(a?.offset, 17)   // after "https://real.com@"

        // Userinfo literally contains the authority host string; emphasis must still skip past it.
        let b = emphasis("https://a.example.com@example.com/")
        XCTAssertEqual(b?.text, "example.com")
        XCTAssertEqual(b?.offset, 22)   // the post-@ authority host, not the userinfo copy at 10

        let c = emphasis("https://evil.com.bank.com@evil.com/")
        XCTAssertEqual(c?.text, "evil.com")
        XCTAssertGreaterThan(c?.offset ?? 0, 25)   // after the userinfo + "@", not the prefix copy
    }
}
