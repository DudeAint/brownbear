//
//  UserScriptInstallRouterTests.swift
//  BrownBearTests
//
//  The pure DNR-`redirect` matcher that routes a `.user.js` navigation to an installed userscript
//  manager. Centerpiece: ScriptCat's actual session rule —
//    regexFilter ^([^?#]+?\.user(\.bg|\.sub)?\.js), action redirect,
//    regexSubstitution chrome-extension://<id>/src/install.html?url=\1
//  — must yield install.html?url=<original script URL>, which ScriptCat's install page self-fetches.
//

import XCTest
@testable import BrownBear

final class UserScriptInstallRouterTests: XCTestCase {

    private let extID = "abcdefghijklmnopabcdefghijklmnop"

    /// ScriptCat's generic session redirect rule (excluding the code-host special-cases for brevity).
    private func scriptCatRule() -> [String: Any] {
        [
            "id": 1000,
            "action": ["type": "redirect",
                       "redirect": ["regexSubstitution": "chrome-extension://\(extID)/src/install.html?url=\\1"]],
            "condition": ["regexFilter": "^([^?#]+?\\.user(\\.bg|\\.sub)?\\.js)",
                          "resourceTypes": ["main_frame"],
                          "requestMethods": ["get"],
                          "isUrlFilterCaseSensitive": false,
                          "excludedRequestDomains": ["github.com", "gitlab.com"]]
        ]
    }

    private func redirect(_ urlString: String, _ rules: [[String: Any]]) -> UserScriptInstallRouter.Redirect? {
        UserScriptInstallRouter.redirect(for: URL(string: urlString)!, extensionID: extID, rules: rules)
    }

    // MARK: - ScriptCat's real rule

    func testScriptCatRuleRedirectsToInstallPageWithURL() {
        let r = redirect("https://example.com/foo.user.js", [scriptCatRule()])
        XCTAssertEqual(r?.extensionID, extID)
        XCTAssertEqual(r?.target.absoluteString,
                       "chrome-extension://\(extID)/src/install.html?url=https://example.com/foo.user.js")
        XCTAssertEqual(r?.target.query, "url=https://example.com/foo.user.js",
                       "the original script URL must ride in the ?url= param the install page reads")
    }

    func testScriptCatRuleDropsTheOriginalQuery() {
        // regexFilter's [^?#]+ stops at '?', so a versioned URL installs by its base (ScriptCat behavior).
        let r = redirect("https://example.com/foo.user.js?v=2", [scriptCatRule()])
        XCTAssertEqual(r?.target.absoluteString,
                       "chrome-extension://\(extID)/src/install.html?url=https://example.com/foo.user.js")
    }

    func testExcludedRequestDomainSkipsRule() {
        XCTAssertNil(redirect("https://github.com/u/r/raw/foo.user.js", [scriptCatRule()]),
                     "github is excluded (ScriptCat routes it via dedicated rules) → no match here")
        XCTAssertNil(redirect("https://raw.gitlab.com/foo.user.js", [scriptCatRule()]),
                     "a subdomain of an excluded domain is also excluded")
    }

    func testNonUserScriptURLDoesNotMatch() {
        XCTAssertNil(redirect("https://example.com/page.html", [scriptCatRule()]))
    }

    // MARK: - Resource type / method gates

    func testNonMainFrameResourceTypeSkips() {
        var rule = scriptCatRule()
        rule["condition"] = ["regexFilter": "\\.user\\.js$", "resourceTypes": ["sub_frame", "xmlhttprequest"]]
        XCTAssertNil(redirect("https://example.com/foo.user.js", [rule]))
    }

    func testExcludedMainFrameResourceTypeSkips() {
        var rule = scriptCatRule()
        rule["condition"] = ["regexFilter": "\\.user\\.js$", "excludedResourceTypes": ["main_frame"]]
        XCTAssertNil(redirect("https://example.com/foo.user.js", [rule]))
    }

    func testNonGetMethodSkips() {
        var rule = scriptCatRule()
        rule["condition"] = ["regexFilter": "\\.user\\.js$", "requestMethods": ["post"]]
        XCTAssertNil(redirect("https://example.com/foo.user.js", [rule]))
    }

    func testMissingResourceTypesMatchesAll() {
        let rule: [String: Any] = [
            "id": 1,
            "action": ["type": "redirect", "redirect": ["extensionPath": "/install.html"]],
            "condition": ["regexFilter": "\\.user\\.js"]
        ]
        XCTAssertEqual(redirect("https://example.com/foo.user.js", [rule])?.target.absoluteString,
                       "chrome-extension://\(extID)/install.html")
    }

    // MARK: - Redirect target forms

    func testExtensionPathRedirect() {
        let rule: [String: Any] = [
            "id": 2, "action": ["type": "redirect", "redirect": ["extensionPath": "/confirm.html"]],
            "condition": ["urlFilter": "*.user.js", "resourceTypes": ["main_frame"]]
        ]
        XCTAssertEqual(redirect("https://example.com/x.user.js", [rule])?.target.absoluteString,
                       "chrome-extension://\(extID)/confirm.html")
    }

    func testAcceptsOwnExtensionURLRedirect() {
        // redirect.url pointing at THIS extension's own page is allowed.
        let rule: [String: Any] = [
            "id": 3, "action": ["type": "redirect", "redirect": ["url": "chrome-extension://\(extID)/install.html"]],
            "condition": ["urlFilter": "*.user.js"]
        ]
        XCTAssertEqual(redirect("https://example.com/x.user.js", [rule])?.target.absoluteString,
                       "chrome-extension://\(extID)/install.html")
    }

    // MARK: - Security: target must be the rule-owning extension's own page

    func testRejectsWebOriginRedirectTarget() {
        // A redirect to a web origin must NOT be honored — it would otherwise be loaded under the
        // rule-owner's scheme handler (path/param confusion) and is never a real manager install page.
        let rule: [String: Any] = [
            "id": 30, "action": ["type": "redirect", "redirect": ["url": "https://evil.example/install"]],
            "condition": ["urlFilter": "*.user.js"]
        ]
        XCTAssertNil(redirect("https://example.com/x.user.js", [rule]))
    }

    func testRejectsCrossExtensionRedirectTarget() {
        // A regexSubstitution pointing at ANOTHER extension's id must be rejected (hijack guard).
        var rule = scriptCatRule()
        let other = "ponmlkjihgfedcbaponmlkjihgfedcba"
        rule["action"] = ["type": "redirect",
                          "redirect": ["regexSubstitution": "chrome-extension://\(other)/src/install.html?url=\\1"]]
        XCTAssertNil(redirect("https://example.com/foo.user.js", [rule]))
    }

    func testRejectsJavascriptSchemeRedirectTarget() {
        let rule: [String: Any] = [
            "id": 31, "action": ["type": "redirect", "redirect": ["url": "javascript:alert(1)"]],
            "condition": ["urlFilter": "*.user.js"]
        ]
        XCTAssertNil(redirect("https://example.com/x.user.js", [rule]))
    }

    func testRegexFilterLengthCapSkipsAbsurdPatterns() {
        var rule = scriptCatRule()
        var condition = rule["condition"] as? [String: Any] ?? [:]
        condition["regexFilter"] = String(repeating: "a", count: 1001) + "\\.user\\.js"
        rule["condition"] = condition
        XCTAssertNil(redirect("https://example.com/foo.user.js", [rule]),
                     "an absurdly long regexFilter is skipped (ReDoS defense-in-depth)")
    }

    // MARK: - Non-redirect rules ignored

    func testBlockRuleIgnored() {
        let rule: [String: Any] = [
            "id": 4, "action": ["type": "block"], "condition": ["urlFilter": "*.user.js"]
        ]
        XCTAssertNil(redirect("https://example.com/x.user.js", [rule]))
    }

    func testFirstMatchingRuleWins() {
        let first: [String: Any] = [
            "id": 5, "action": ["type": "redirect", "redirect": ["extensionPath": "/first.html"]],
            "condition": ["regexFilter": "\\.user\\.js"]
        ]
        let second: [String: Any] = [
            "id": 6, "action": ["type": "redirect", "redirect": ["extensionPath": "/second.html"]],
            "condition": ["regexFilter": "\\.user\\.js"]
        ]
        XCTAssertEqual(redirect("https://example.com/x.user.js", [first, second])?.target.absoluteString,
                       "chrome-extension://\(extID)/first.html")
    }

    // MARK: - regexSubstitution escaping

    func testRegexSubstitutionEscaping() {
        let match = try! NSRegularExpression(pattern: "^(a)(b)$")
            .firstMatch(in: "ab", range: NSRange("ab".startIndex..., in: "ab"))!
        XCTAssertEqual(UserScriptInstallRouter.applyRegexSubstitution("[\\1|\\2]", match: match, source: "ab"), "[a|b]")
        XCTAssertEqual(UserScriptInstallRouter.applyRegexSubstitution("\\\\\\1", match: match, source: "ab"), "\\a",
                       "a literal backslash (\\\\) then group 1")
        XCTAssertEqual(UserScriptInstallRouter.applyRegexSubstitution("whole=\\0", match: match, source: "ab"), "whole=ab")
    }

    // MARK: - urlFilter mini-syntax

    func testURLFilterStarAndSeparator() {
        XCTAssertTrue(UserScriptInstallRouter.urlFilterMatches("*.user.js", "https://x.com/a.user.js", caseSensitive: false))
        XCTAssertFalse(UserScriptInstallRouter.urlFilterMatches("*.user.js", "https://x.com/a.js", caseSensitive: false))
    }

    func testURLFilterDomainAnchor() {
        XCTAssertTrue(UserScriptInstallRouter.urlFilterMatches("||example.com^", "https://example.com/p", caseSensitive: false))
        XCTAssertTrue(UserScriptInstallRouter.urlFilterMatches("||example.com^", "https://sub.example.com/p", caseSensitive: false))
        XCTAssertFalse(UserScriptInstallRouter.urlFilterMatches("||example.com^", "https://notexample.com/p", caseSensitive: false))
    }
}
