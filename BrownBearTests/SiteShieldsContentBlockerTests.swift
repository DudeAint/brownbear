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

    func testSubdomainHostBroadensToRegistrableDomain() {
        // Edgenuity case: the user toggles Shields off on the page's host, but the video player runs in an
        // iframe on a SIBLING subdomain (r22.core.learn.edgenuity.com). The exclusion must cover the whole
        // registrable site so the iframe's trackers (NR/GA) aren't left blocked and the player can init.
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        let out = WebExtensionContentBlocker.applyExclusions(to: json, hosts: ["core.learn.edgenuity.com"])
        let trigger = rules(out).first?["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["unless-domain"] as? [String], ["*edgenuity.com"],
                       "a subdomain host broadens to its registrable domain (covers r22.*.edgenuity.com)")
    }

    func testSiblingSubdomainsCollapseToOneEntry() {
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        let out = WebExtensionContentBlocker.applyExclusions(to: json, hosts: ["a.edgenuity.com", "b.edgenuity.com"])
        let trigger = rules(out).first?["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["unless-domain"] as? [String], ["*edgenuity.com"], "siblings dedupe to one entry")
    }

    func testRegistrableDomain() {
        XCTAssertEqual(WebExtensionContentBlocker.registrableDomain("r22.core.learn.edgenuity.com"), "edgenuity.com")
        XCTAssertEqual(WebExtensionContentBlocker.registrableDomain("edgenuity.com"), "edgenuity.com")
        XCTAssertEqual(WebExtensionContentBlocker.registrableDomain("www.example.com"), "example.com")
        XCTAssertEqual(WebExtensionContentBlocker.registrableDomain("foo.bar.co.uk"), "bar.co.uk")
        XCTAssertEqual(WebExtensionContentBlocker.registrableDomain("bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(WebExtensionContentBlocker.registrableDomain("localhost"), "localhost")
        XCTAssertEqual(WebExtensionContentBlocker.registrableDomain("192.168.1.1"), "192.168.1.1")
    }

    // MARK: - Unbreak exceptions (let a page-breaking telemetry script load, block its data endpoint)

    func testUnbreakStripsAgentBlock() {
        // A block whose url-filter matches the New Relic agent URL is REMOVED outright (order/trigger-proof).
        let json = #"[{"trigger":{"url-filter":"^https?://js-agent\\.newrelic\\.com"},"action":{"type":"block"}}]"#
        let out = rules(WebExtensionContentBlocker.applyUnbreak(to: json, includeEndpointBlocks: false))
        XCTAssertTrue(out.isEmpty, "the New Relic agent block is stripped")
    }

    func testUnbreakStripsBroadNewRelicBlockThatWouldCatchTheAgent() {
        // EasyPrivacy may block via a broad host pattern; it still matches the agent URL, so it's stripped.
        let json = #"[{"trigger":{"url-filter":"newrelic\\.com"},"action":{"type":"block"}}]"#
        let out = rules(WebExtensionContentBlocker.applyUnbreak(to: json, includeEndpointBlocks: false))
        XCTAssertTrue(out.isEmpty, "a broad newrelic.com block that would catch the agent is stripped")
    }

    func testUnbreakKeepsTelemetryBlockAndAppendsEndpoint() {
        // nr-data.net is not an agent host, so an existing block of it survives; and the built-in path
        // (includeEndpointBlocks) appends an explicit third-party nr-data block so telemetry stays blocked.
        let json = #"[{"trigger":{"url-filter":"^https?://bam\\.nr-data\\.net"},"action":{"type":"block"}}]"#
        let out = rules(WebExtensionContentBlocker.applyUnbreak(to: json, includeEndpointBlocks: true))
        let nrData = out.filter { (($0["trigger"] as? [String: Any])?["url-filter"] as? String)?.contains("nr-data") == true }
        XCTAssertGreaterThanOrEqual(nrData.count, 1, "the telemetry endpoint stays blocked")
        let appended = out.first { (($0["trigger"] as? [String: Any])?["url-filter"] as? String) == #"^https?://([^/]+\.)?nr-data\.net[:/]"# }
        XCTAssertEqual((appended?["action"] as? [String: Any])?["type"] as? String, "block")
        XCTAssertEqual((appended?["trigger"] as? [String: Any])?["load-type"] as? [String], ["third-party"])
    }

    func testUnbreakExtensionPathStripsWithoutAppending() {
        // includeEndpointBlocks:false (the per-extension path) strips the agent block but appends nothing —
        // the built-in list already carries the endpoint block.
        let json = #"[{"trigger":{"url-filter":"js-agent\\.newrelic\\.com"},"action":{"type":"block"}},"# +
                   #"{"trigger":{"url-filter":"^https?://([^/]+\\.)?example\\.com"},"action":{"type":"block"}}]"#
        let out = rules(WebExtensionContentBlocker.applyUnbreak(to: json, includeEndpointBlocks: false))
        XCTAssertEqual(out.count, 1, "agent block stripped, unrelated block kept")
        XCTAssertNil(out.first { (($0["trigger"] as? [String: Any])?["url-filter"] as? String)?.contains("nr-data") == true },
                     "no endpoint block is appended on the extension path")
    }

    func testUnbreakLeavesUnrelatedAndNonBlockRules() {
        // A block for an unrelated host AND a non-block (ignore) rule for the agent host are both untouched.
        let json = #"[{"trigger":{"url-filter":"^https?://([^/]+\\.)?example\\.com"},"action":{"type":"block"}},"# +
                   #"{"trigger":{"url-filter":"js-agent\\.newrelic\\.com"},"action":{"type":"ignore-previous-rules"}}]"#
        let out = rules(WebExtensionContentBlocker.applyUnbreak(to: json, includeEndpointBlocks: false))
        XCTAssertEqual(out.count, 2, "only matching BLOCK rules are stripped; unrelated + non-block rules stay")
    }

    func testUnbreakMalformedJSONIsReturnedUnchanged() {
        let junk = "not json at all"
        XCTAssertEqual(WebExtensionContentBlocker.applyUnbreak(to: junk, includeEndpointBlocks: true), junk)
    }
}
