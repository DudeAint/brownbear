//
//  WebExtensionDNRRedirectTests.swift
//  BrownBearTests
//
//  The pure declarativeNetRequest main-frame redirect matcher. Because a FALSE match diverts NORMAL
//  browsing (the worst failure), the bulk of these tests are over-match guards: rules that must NOT
//  apply to a top-level navigation. The rest verify correct matching + each redirect target form.
//

import XCTest
@testable import BrownBear

final class WebExtensionDNRRedirectTests: XCTestCase {

    private func parse(_ raws: [[String: Any]]) -> [WebExtensionDNRRedirect.Rule] {
        WebExtensionDNRRedirect.redirectRules(from: raws, extensionID: "abcdefghijklmnopabcdefghijklmnop")
    }

    private func target(_ url: String, _ raws: [[String: Any]]) -> URL? {
        WebExtensionDNRRedirect.target(for: url, rules: parse(raws),
                                       extensionOrigin: { "chrome-extension://\($0)" })
    }

    private func rule(id: Int = 1, priority: Int = 1, condition: [String: Any], redirect: [String: Any]) -> [String: Any] {
        ["id": id, "priority": priority, "action": ["type": "redirect", "redirect": redirect], "condition": condition]
    }

    // MARK: - Over-match guards (must NOT divert normal browsing)

    func testRuleWithoutMainFrameResourceTypeIsIgnored() {
        let r = rule(condition: ["urlFilter": "||reddit.com", "resourceTypes": ["script", "image"]],
                     redirect: ["transform": ["host": "old.reddit.com"]])
        XCTAssertNil(target("https://reddit.com/r/swift", [r]), "a non-main_frame rule must never divert a navigation")
    }

    func testRuleWithoutResourceTypesIsIgnoredForMainFrame() {
        // Omitted resourceTypes does not opt into main_frame — conservative, can only under-match.
        let r = rule(condition: ["urlFilter": "||reddit.com"], redirect: ["transform": ["host": "old.reddit.com"]])
        XCTAssertNil(target("https://reddit.com/", [r]))
    }

    func testRuleWithDomainConditionsIsSkipped() {
        let r = rule(condition: ["urlFilter": "||reddit.com", "resourceTypes": ["main_frame"],
                                 "initiatorDomains": ["evil.com"]],
                     redirect: ["transform": ["host": "old.reddit.com"]])
        XCTAssertNil(target("https://reddit.com/", [r]), "a rule with a domain/initiator condition is skipped")
    }

    func testRuleWithNoURLConditionIsRefused() {
        // No urlFilter/regexFilter would match EVERY navigation — must be refused.
        let r = rule(condition: ["resourceTypes": ["main_frame"]], redirect: ["url": "https://x.com/"])
        XCTAssertTrue(parse([r]).isEmpty)
        XCTAssertNil(target("https://anything.com/", [r]))
    }

    func testNonMatchingURLIsNotDiverted() {
        let r = rule(condition: ["urlFilter": "||reddit.com", "resourceTypes": ["main_frame"]],
                     redirect: ["transform": ["host": "old.reddit.com"]])
        XCTAssertNil(target("https://github.com/", [r]), "a URL the rule doesn't match is left alone")
    }

    func testSelfRedirectIsRejected() {
        // transform that produces the same URL (host already old.reddit.com) must be a no-op, not a loop.
        let r = rule(condition: ["urlFilter": "||old.reddit.com", "resourceTypes": ["main_frame"]],
                     redirect: ["transform": ["host": "old.reddit.com"]])
        XCTAssertNil(target("https://old.reddit.com/r/swift", [r]))
    }

    func testNonHTTPTargetRejected() {
        let r = rule(condition: ["urlFilter": "||reddit.com", "resourceTypes": ["main_frame"]],
                     redirect: ["url": "javascript:alert(1)"])
        XCTAssertNil(target("https://reddit.com/", [r]), "only http(s)/chrome-extension targets are allowed")
    }

    func testUncompilableRegexFilterDropsRule() {
        let r = rule(condition: ["regexFilter": "(", "resourceTypes": ["main_frame"]],
                     redirect: ["url": "https://x.com/"])
        XCTAssertTrue(parse([r]).isEmpty)
    }

    // MARK: - Correct matches + target forms

    func testTransformHostRedirect() {
        let r = rule(condition: ["urlFilter": "||reddit.com", "resourceTypes": ["main_frame"]],
                     redirect: ["transform": ["host": "old.reddit.com"]])
        // transform.host REPLACES the whole host (DNR semantics), so the www. subdomain is dropped —
        // exactly what old-reddit-redirect does (any reddit.com host → old.reddit.com).
        XCTAssertEqual(target("https://www.reddit.com/r/swift?a=1", [r])?.absoluteString,
                       "https://old.reddit.com/r/swift?a=1")
    }

    func testStaticURLRedirect() {
        let r = rule(condition: ["urlFilter": "||tracker.example", "resourceTypes": ["main_frame"]],
                     redirect: ["url": "https://privacy.example/blocked"])
        XCTAssertEqual(target("https://tracker.example/x", [r])?.absoluteString, "https://privacy.example/blocked")
    }

    func testExtensionPathRedirect() {
        let r = rule(condition: ["urlFilter": "||ads.example", "resourceTypes": ["main_frame"]],
                     redirect: ["extensionPath": "/blocked.html"])
        XCTAssertEqual(target("https://ads.example/x", [r])?.absoluteString,
                       "chrome-extension://abcdefghijklmnopabcdefghijklmnop/blocked.html")
    }

    func testRegexSubstitutionRedirect() {
        let r = rule(condition: ["regexFilter": "^https://m\\.(.*)$", "resourceTypes": ["main_frame"]],
                     redirect: ["regexSubstitution": "https://\\1"])
        XCTAssertEqual(target("https://m.example.com/page", [r])?.absoluteString, "https://example.com/page")
    }

    func testQueryTransformRemovesParams() {
        let r = rule(condition: ["urlFilter": "||example.com", "resourceTypes": ["main_frame"]],
                     redirect: ["transform": ["queryTransform": ["removeParams": ["utm_source", "utm_medium"]]]])
        XCTAssertEqual(target("https://example.com/p?utm_source=x&keep=1&utm_medium=y", [r])?.absoluteString,
                       "https://example.com/p?keep=1")
    }

    func testPriorityOrderingHighestWins() {
        let low = rule(id: 1, priority: 1, condition: ["urlFilter": "||example.com", "resourceTypes": ["main_frame"]],
                       redirect: ["url": "https://low.example/"])
        let high = rule(id: 2, priority: 5, condition: ["urlFilter": "||example.com", "resourceTypes": ["main_frame"]],
                        redirect: ["url": "https://high.example/"])
        XCTAssertEqual(target("https://example.com/", [low, high])?.absoluteString, "https://high.example/")
    }

    func testCaseInsensitiveByDefault() {
        let r = rule(condition: ["urlFilter": "||REDDIT.com", "resourceTypes": ["main_frame"]],
                     redirect: ["transform": ["host": "old.reddit.com"]])
        XCTAssertNotNil(target("https://reddit.com/", [r]), "DNR url matching is case-insensitive by default")
    }

    func testSubstitutionTemplateConversion() {
        XCTAssertEqual(WebExtensionDNRRedirect.substitutionTemplate(from: "https://\\1/\\2"), "https://$1/$2")
        XCTAssertEqual(WebExtensionDNRRedirect.substitutionTemplate(from: "a\\\\b"), "a\\\\b")   // \\ → literal
        XCTAssertEqual(WebExtensionDNRRedirect.substitutionTemplate(from: "price$5"), "price\\$5") // literal $ escaped
    }
}
