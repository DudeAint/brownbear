//
//  ShieldBlockCounterTests.swift
//  BrownBearTests
//
//  Pure-logic coverage for the "N blocked" recovery path: extracting blocked HOST literals out of a
//  compiled WebKit content-rule-list JSON, and matching a request host (incl. subdomains) against that
//  set. The page-world reporter + per-tab tally are exercised on-device; these pin the parse + match,
//  which decide whether the Shields count is real or fabricated.
//

import XCTest
@testable import BrownBear

final class ShieldBlockCounterTests: XCTestCase {

    // MARK: - hostFromURLFilter

    func testExtractsHostFromOptionalSubdomainAnchor() {
        // The shape ContentBlocklistUpdater's Peter Lowe converter emits.
        XCTAssertEqual(ShieldBlockCounter.hostFromURLFilter("^https?://([^/]+\\.)?doubleclick\\.net[:/]"),
                       "doubleclick.net")
        XCTAssertEqual(ShieldBlockCounter.hostFromURLFilter("^https?://(?:[^/]+\\.)?ads\\.example\\.com[:/]"),
                       "ads.example.com")
    }

    func testExtractsHostFromBareSchemeAnchor() {
        XCTAssertEqual(ShieldBlockCounter.hostFromURLFilter("^https://tracker\\.io/"), "tracker.io")
        XCTAssertEqual(ShieldBlockCounter.hostFromURLFilter("://metrics\\.evil\\.net^"), "metrics.evil.net")
    }

    func testRejectsPathOnlyOrWildcardFilters() {
        // No clean host anchor → nil (we'd rather undercount than fabricate).
        XCTAssertNil(ShieldBlockCounter.hostFromURLFilter("/ads/banner\\.gif"))
        XCTAssertNil(ShieldBlockCounter.hostFromURLFilter("^https?://.*/track\\?"))
        XCTAssertNil(ShieldBlockCounter.hostFromURLFilter("/[a-z]+\\.js"))
        XCTAssertNil(ShieldBlockCounter.hostFromURLFilter("^https?://([^/]+\\.)?co"))   // bare TLD-ish, no dot in host
    }

    // MARK: - extractHosts

    func testExtractHostsTakesBlockRulesOnly() {
        let json = """
        [
          {"trigger": {"url-filter": "^https?://([^/]+\\\\.)?doubleclick\\\\.net[:/]"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^https?://([^/]+\\\\.)?good\\\\.example\\\\.com[:/]"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^https?://([^/]+\\\\.)?scorecardresearch\\\\.com[:/]", "load-type": ["third-party"]}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "/ad/banner"}, "action": {"type": "block"}}
        ]
        """
        let hosts = ShieldBlockCounter.extractHosts(fromContentRuleJSON: json)
        XCTAssertEqual(hosts, ["doubleclick.net", "scorecardresearch.com"])
    }

    func testExtractHostsEmptyOnMalformedJSON() {
        XCTAssertEqual(ShieldBlockCounter.extractHosts(fromContentRuleJSON: "not json"), [])
        XCTAssertEqual(ShieldBlockCounter.extractHosts(fromContentRuleJSON: "[]"), [])
    }

    // MARK: - isBlocked (subdomain matching)

    func testIsBlockedMatchesSubdomains() {
        let set: Set<String> = ["doubleclick.net", "scorecardresearch.com"]
        XCTAssertTrue(ShieldBlockCounter.isBlocked("doubleclick.net", in: set))
        XCTAssertTrue(ShieldBlockCounter.isBlocked("ad.g.doubleclick.net", in: set))
        XCTAssertTrue(ShieldBlockCounter.isBlocked("sb.scorecardresearch.com", in: set))
    }

    func testIsBlockedRejectsUnrelatedAndBareTLDWalk() {
        let set: Set<String> = ["doubleclick.net"]
        XCTAssertFalse(ShieldBlockCounter.isBlocked("example.com", in: set))
        XCTAssertFalse(ShieldBlockCounter.isBlocked("notdoubleclick.net", in: set))   // not a subdomain
        // Walking up subdomains must STOP before testing a bare TLD, so a stray "net" entry can't match
        // every .net host. (A real blocklist never contains a bare TLD; this guards the walk regardless.)
        XCTAssertFalse(ShieldBlockCounter.isBlocked("ads.foo.net", in: ["net"]))
        XCTAssertTrue(ShieldBlockCounter.isBlocked("doubleclick.net", in: ["doubleclick.net"]))
    }
}
