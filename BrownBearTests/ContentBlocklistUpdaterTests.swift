//
//  ContentBlocklistUpdaterTests.swift
//  BrownBearTests
//
//  Table-driven coverage for converting a fetched domain/hosts list into WebKit content-rule-list
//  third-party block rules: plain domains, hosts-format (0.0.0.0 / 127.0.0.1) lines, comment/blank
//  skipping, inline comments, junk rejection, dedupe, and the produced trigger shape.
//

import XCTest
@testable import BrownBear

@MainActor
final class ContentBlocklistUpdaterTests: XCTestCase {

    private func filters(_ rules: [[String: Any]]) -> [String] {
        rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
    }

    func testPlainDomainsBecomeThirdPartyBlockRules() {
        let rules = ContentBlocklistUpdater.domainRules(from: "doubleclick.net\nads.example.com\n")
        XCTAssertEqual(rules.count, 2)
        let trigger = rules.first?["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual((rules.first?["action"] as? [String: Any])?["type"] as? String, "block")
        XCTAssertEqual(trigger?["url-filter"] as? String, "^https?://([^/]+\\.)?doubleclick\\.net[:/]")
    }

    func testHostsFormatLinesAreParsed() {
        let text = """
        # comment
        0.0.0.0 tracker.com
        127.0.0.1 ads.net
        ::1 telemetry.io
        """
        let f = Set(filters(ContentBlocklistUpdater.domainRules(from: text)))
        XCTAssertTrue(f.contains("^https?://([^/]+\\.)?tracker\\.com[:/]"))
        XCTAssertTrue(f.contains("^https?://([^/]+\\.)?ads\\.net[:/]"))
        XCTAssertTrue(f.contains("^https?://([^/]+\\.)?telemetry\\.io[:/]"))
    }

    func testCommentsBlanksAndJunkAreSkipped() {
        let text = """
        ! adblock-style comment
        # hosts comment

        not a domain with spaces
        https://nope.com/path
        localhost
        good-domain.example
        """
        let f = filters(ContentBlocklistUpdater.domainRules(from: text))
        XCTAssertEqual(f, ["^https?://([^/]+\\.)?good-domain\\.example[:/]"])
    }

    func testInlineCommentStripped() {
        let rules = ContentBlocklistUpdater.domainRules(from: "tracker.io # some note\n")
        XCTAssertEqual(filters(rules), ["^https?://([^/]+\\.)?tracker\\.io[:/]"])
    }

    func testDuplicatesAreDeduped() {
        let rules = ContentBlocklistUpdater.domainRules(from: "dup.com\ndup.com\n0.0.0.0 dup.com\n")
        XCTAssertEqual(rules.count, 1)
    }
}
