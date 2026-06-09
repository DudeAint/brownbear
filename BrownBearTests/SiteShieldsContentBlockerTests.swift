//
//  SiteShieldsContentBlockerTests.swift
//  BrownBearTests
//
//  Pure-logic tests for the per-site Shields exclusion applied to WebKit content-rule-list JSON:
//  a shields-off host is injected as `unless-domain` (with a leading `*` for subdomain coverage) on
//  every rule that can carry one, rules already pinned with `if-domain` are left untouched (WebKit
//  forbids both in one trigger), and an empty host list is an identity transform. These run on the
//  main actor because WebExtensionContentBlocker is @MainActor-isolated.
//

import XCTest
@testable import BrownBear

@MainActor
final class SiteShieldsContentBlockerTests: XCTestCase {

    /// Decode a rule-list JSON string back to dictionaries for structural assertions.
    private func rules(_ json: String) -> [[String: Any]] {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr
    }

    func testEmptyHostsIsIdentity() {
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        XCTAssertEqual(WebExtensionContentBlocker.applyExclusions(to: json, hosts: []), json)
    }

    func testInjectsUnlessDomainWithWildcardPrefix() {
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        let out = WebExtensionContentBlocker.applyExclusions(to: json, hosts: ["example.com"])
        let trigger = rules(out).first?["trigger"] as? [String: Any]
        let unless = trigger?["unless-domain"] as? [String]
        XCTAssertEqual(unless, ["*example.com"], "host is added as a subdomain-matching exclusion")
    }

    func testMultipleHostsAndExistingExclusionMerge() {
        let json = #"[{"trigger":{"url-filter":".*","unless-domain":["*kept.com"]},"action":{"type":"block"}}]"#
        let out = WebExtensionContentBlocker.applyExclusions(to: json, hosts: ["a.com", "b.com"])
        let trigger = rules(out).first?["trigger"] as? [String: Any]
        let unless = Set((trigger?["unless-domain"] as? [String]) ?? [])
        XCTAssertEqual(unless, ["*kept.com", "*a.com", "*b.com"], "new hosts merge with the existing exclusion")
    }

    func testIfDomainRulesAreLeftUnchanged() {
        let json = #"[{"trigger":{"url-filter":".*","if-domain":["*only.com"]},"action":{"type":"block"}}]"#
        let out = WebExtensionContentBlocker.applyExclusions(to: json, hosts: ["example.com"])
        let trigger = rules(out).first?["trigger"] as? [String: Any]
        XCTAssertNil(trigger?["unless-domain"], "a rule pinned with if-domain can't also take unless-domain")
        XCTAssertEqual(trigger?["if-domain"] as? [String], ["*only.com"], "if-domain rule is untouched")
    }

    func testMalformedJSONIsReturnedUnchanged() {
        let junk = "not json at all"
        XCTAssertEqual(WebExtensionContentBlocker.applyExclusions(to: junk, hosts: ["x.com"]), junk)
    }

    func testNoDuplicateExclusionEntries() {
        let json = #"[{"trigger":{"url-filter":".*","unless-domain":["*dup.com"]},"action":{"type":"block"}}]"#
        let out = WebExtensionContentBlocker.applyExclusions(to: json, hosts: ["dup.com"])
        let trigger = rules(out).first?["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["unless-domain"] as? [String], ["*dup.com"], "an already-present host isn't duplicated")
    }

    // MARK: - Unbreak exceptions (let a page-breaking telemetry script load, block its data endpoint)

    func testUnbreakAppendsAllowAndBlockRules() {
        // Upstream list blocks the New Relic AGENT (which breaks pages). After unbreak: the agent gets an
        // ignore-previous-rules (un-blocked), and its data endpoint gets an explicit third-party block.
        let json = #"[{"trigger":{"url-filter":"^https?://js-agent\\.newrelic\\.com"},"action":{"type":"block"}}]"#
        let out = rules(WebExtensionContentBlocker.appendUnbreakRules(to: json))
        XCTAssertEqual(out.count, 3, "original block + appended endpoint-block + appended ignore")
        // The LAST rule must be the ignore for the agent (so it overrides the earlier block in-list).
        let last = out.last
        XCTAssertEqual((last?["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
        XCTAssertEqual((last?["trigger"] as? [String: Any])?["url-filter"] as? String,
                       #"^https?://([^/]+\.)?js-agent\.newrelic\.com[:/]"#)
        // An appended rule blocks the nr-data.net data endpoint, third-party only.
        let endpointBlock = out.first { r in
            ((r["trigger"] as? [String: Any])?["url-filter"] as? String)?.contains("nr-data") == true
        }
        XCTAssertEqual((endpointBlock?["action"] as? [String: Any])?["type"] as? String, "block")
        XCTAssertEqual((endpointBlock?["trigger"] as? [String: Any])?["load-type"] as? [String], ["third-party"])
    }

    func testUnbreakIgnoreComesAfterTheBlockItOverrides() {
        // WebKit applies ignore-previous-rules only to rules EARLIER in the same list, so the agent's
        // upstream block must precede the appended ignore for the un-block to take effect.
        let json = #"[{"trigger":{"url-filter":"^https?://js-agent\\.newrelic\\.com"},"action":{"type":"block"}}]"#
        let out = rules(WebExtensionContentBlocker.appendUnbreakRules(to: json))
        let agentBlockIndex = out.firstIndex { r in
            ((r["action"] as? [String: Any])?["type"] as? String) == "block"
                && ((r["trigger"] as? [String: Any])?["url-filter"] as? String)?.contains("js-agent") == true
        }
        let ignoreIndex = out.firstIndex { r in
            ((r["action"] as? [String: Any])?["type"] as? String) == "ignore-previous-rules"
        }
        XCTAssertNotNil(agentBlockIndex)
        XCTAssertNotNil(ignoreIndex)
        XCTAssertLessThan(agentBlockIndex!, ignoreIndex!, "ignore must come after the block it cancels")
    }

    func testUnbreakMalformedJSONIsReturnedUnchanged() {
        let junk = "not json at all"
        XCTAssertEqual(WebExtensionContentBlocker.appendUnbreakRules(to: junk), junk)
    }
}
