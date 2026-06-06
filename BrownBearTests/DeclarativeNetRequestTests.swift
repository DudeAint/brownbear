//
//  DeclarativeNetRequestTests.swift
//  BrownBearTests
//
//  Tests for the DNR → WKContentRuleList compiler (Module 6, Phase 2). It's pure, so we can assert
//  on the exact compiled JSON: urlFilter translation, action mapping, domain/resource conditions,
//  rule ordering, and the fidelity-over-coverage skips.
//

import XCTest
@testable import BrownBear

final class DeclarativeNetRequestTests: XCTestCase {

    /// Decode the compiled JSON back into objects so assertions don't depend on key spacing.
    private func compileToObjects(_ rules: [[String: Any]]) throws -> (objects: [[String: Any]], result: DeclarativeNetRequest.CompileResult) {
        let result = DeclarativeNetRequest.compile(rules: rules)
        let data = Data(result.json.utf8)
        let objects = (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return (objects, result)
    }

    // MARK: - urlFilter translation

    func testDomainAnchorTranslation() {
        let regex = DeclarativeNetRequest.regex(fromURLFilter: "||ads.example.com^")
        XCTAssertEqual(regex, "^[^:]+://([a-z0-9_-]+\\.)*ads\\.example\\.com[^a-zA-Z0-9_.%-]")
    }

    func testStartAndEndAnchors() {
        XCTAssertEqual(DeclarativeNetRequest.regex(fromURLFilter: "|https://x.com"), "^https://x\\.com")
        XCTAssertEqual(DeclarativeNetRequest.regex(fromURLFilter: "/banner.gif|"), "/banner\\.gif$")
    }

    func testWildcardAndLiteralEscaping() {
        XCTAssertEqual(DeclarativeNetRequest.regex(fromURLFilter: "/a*b?c"), "/a.*b\\?c")
    }

    // MARK: - Actions

    func testBlockRuleCompiles() throws {
        let rules: [[String: Any]] = [[
            "id": 1, "priority": 1,
            "action": ["type": "block"],
            "condition": ["urlFilter": "||tracker.io^", "resourceTypes": ["script", "xmlhttprequest"]]
        ]]
        let (objects, result) = try compileToObjects(rules)
        XCTAssertEqual(result.compiledCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(objects.count, 1)
        let action = objects[0]["action"] as? [String: Any]
        XCTAssertEqual(action?["type"] as? String, "block")
        let trigger = objects[0]["trigger"] as? [String: Any]
        XCTAssertEqual((trigger?["resource-type"] as? [String])?.sorted(), ["fetch", "script"])
    }

    func testAllowMapsToIgnorePreviousRules() throws {
        let rules: [[String: Any]] = [[
            "id": 2, "action": ["type": "allow"], "condition": ["urlFilter": "||good.com^"]
        ]]
        let (objects, _) = try compileToObjects(rules)
        XCTAssertEqual((objects.first?["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
    }

    func testUpgradeSchemeMapsToMakeHTTPS() throws {
        let rules: [[String: Any]] = [[
            "id": 3, "action": ["type": "upgradeScheme"], "condition": ["urlFilter": "||insecure.com^"]
        ]]
        let (objects, result) = try compileToObjects(rules)
        XCTAssertEqual(result.compiledCount, 1)
        XCTAssertEqual((objects.first?["action"] as? [String: Any])?["type"] as? String, "make-https")
    }

    // MARK: - Conditions

    func testInitiatorDomainsBecomeIfDomain() throws {
        let rules: [[String: Any]] = [[
            "id": 4, "action": ["type": "block"],
            "condition": ["urlFilter": "*", "initiatorDomains": ["example.com", "*.test.org"]]
        ]]
        let (objects, _) = try compileToObjects(rules)
        let trigger = objects[0]["trigger"] as? [String: Any]
        XCTAssertEqual((trigger?["if-domain"] as? [String])?.sorted(), ["*example.com", "*test.org"])
    }

    func testExcludedInitiatorDomainsBecomeUnlessDomain() throws {
        let rules: [[String: Any]] = [[
            "id": 5, "action": ["type": "block"],
            "condition": ["urlFilter": "*", "excludedInitiatorDomains": ["safe.com"]]
        ]]
        let (objects, _) = try compileToObjects(rules)
        let trigger = objects[0]["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["unless-domain"] as? [String], ["*safe.com"])
        XCTAssertNil(trigger?["if-domain"])
    }

    func testCaseSensitivityFlagOnlyWhenRequested() throws {
        let sensitive: [[String: Any]] = [[
            "id": 6, "action": ["type": "block"],
            "condition": ["urlFilter": "/X", "isUrlFilterCaseSensitive": true]
        ]]
        let (objects, _) = try compileToObjects(sensitive)
        XCTAssertEqual((objects[0]["trigger"] as? [String: Any])?["url-filter-is-case-sensitive"] as? Bool, true)

        let insensitive: [[String: Any]] = [[
            "id": 7, "action": ["type": "block"], "condition": ["urlFilter": "/x"]
        ]]
        let (objects2, _) = try compileToObjects(insensitive)
        XCTAssertNil((objects2[0]["trigger"] as? [String: Any])?["url-filter-is-case-sensitive"])
    }

    func testEmptyUrlFilterMatchesEverything() throws {
        let rules: [[String: Any]] = [[
            "id": 8, "action": ["type": "block"], "condition": ["resourceTypes": ["image"]]
        ]]
        let (objects, _) = try compileToObjects(rules)
        XCTAssertEqual((objects[0]["trigger"] as? [String: Any])?["url-filter"] as? String, ".*")
    }

    func testDomainTypeMapsToLoadType() throws {
        let rules: [[String: Any]] = [[
            "id": 9, "action": ["type": "block"],
            "condition": ["urlFilter": "||ad.net^", "domainType": "thirdParty"]
        ]]
        let (objects, _) = try compileToObjects(rules)
        XCTAssertEqual((objects[0]["trigger"] as? [String: Any])?["load-type"] as? [String], ["third-party"])
    }

    // MARK: - Skips (fidelity over coverage)

    func testRedirectAndModifyHeadersAreSkipped() throws {
        let rules: [[String: Any]] = [
            ["id": 10, "action": ["type": "redirect", "redirect": ["url": "https://x"]], "condition": ["urlFilter": "*"]],
            ["id": 11, "action": ["type": "modifyHeaders", "requestHeaders": []], "condition": ["urlFilter": "*"]]
        ]
        let (objects, result) = try compileToObjects(rules)
        XCTAssertEqual(objects.count, 0)
        XCTAssertEqual(result.compiledCount, 0)
        XCTAssertEqual(result.skippedCount, 2)
    }

    func testRequestMethodsAndRequestDomainsAreSkipped() throws {
        let rules: [[String: Any]] = [
            ["id": 12, "action": ["type": "block"], "condition": ["urlFilter": "*", "requestMethods": ["post"]]],
            ["id": 13, "action": ["type": "block"], "condition": ["urlFilter": "*", "requestDomains": ["a.com"]]]
        ]
        let (_, result) = try compileToObjects(rules)
        XCTAssertEqual(result.compiledCount, 0)
        XCTAssertEqual(result.skippedCount, 2)
    }

    // MARK: - Ordering

    func testAllowSortsAfterBlockAtSamePriority() throws {
        // allow has a higher action rank, so it must land LAST (WebKit: last action wins).
        let rules: [[String: Any]] = [
            ["id": 20, "priority": 1, "action": ["type": "allow"], "condition": ["urlFilter": "||cdn.example.com^"]],
            ["id": 21, "priority": 1, "action": ["type": "block"], "condition": ["urlFilter": "||example.com^"]]
        ]
        let (objects, _) = try compileToObjects(rules)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual((objects[0]["action"] as? [String: Any])?["type"] as? String, "block")
        XCTAssertEqual((objects[1]["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
    }

    func testHigherPrioritySortsLast() throws {
        let rules: [[String: Any]] = [
            ["id": 30, "priority": 5, "action": ["type": "block"], "condition": ["urlFilter": "/a"]],
            ["id": 31, "priority": 1, "action": ["type": "block"], "condition": ["urlFilter": "/b"]]
        ]
        let (objects, _) = try compileToObjects(rules)
        XCTAssertEqual((objects[0]["trigger"] as? [String: Any])?["url-filter"] as? String, "/b")
        XCTAssertEqual((objects[1]["trigger"] as? [String: Any])?["url-filter"] as? String, "/a")
    }

    // MARK: - regexFilter (WebKit subset gating)

    func testSupportedRegexFilterPassesThrough() throws {
        let rules: [[String: Any]] = [[
            "id": 40, "action": ["type": "block"],
            "condition": ["regexFilter": "^https?://ads\\.example\\.com/.*"]
        ]]
        let (objects, result) = try compileToObjects(rules)
        XCTAssertEqual(result.compiledCount, 1)
        XCTAssertEqual((objects[0]["trigger"] as? [String: Any])?["url-filter"] as? String,
                       "^https?://ads\\.example\\.com/.*")
    }

    func testUnsupportedRegexFilterConstructsAreSkipped() throws {
        // RE2 constructs WebKit's url-filter compiler rejects — skipping one keeps it from failing
        // the entire compiled list.
        let unsupported = [
            "^https?://[^/]+/\\d+",   // \d shorthand class
            "ads?\\b",                // \b word boundary
            "x{2,4}",                 // counted repetition
            "a+?",                    // non-greedy quantifier
            "(?=secret)",             // lookahead
            "(?<name>x)",             // named group
            "(\\w)\\1"                // backreference
        ]
        for pattern in unsupported {
            let rules: [[String: Any]] = [[
                "id": 41, "action": ["type": "block"], "condition": ["regexFilter": pattern]
            ]]
            let (objects, result) = try compileToObjects(rules)
            XCTAssertEqual(objects.count, 0, "expected skip for \(pattern)")
            XCTAssertEqual(result.compiledCount, 0, "expected compiledCount 0 for \(pattern)")
            XCTAssertEqual(result.skippedCount, 1, "expected skippedCount 1 for \(pattern)")
        }
    }

    // MARK: - From raw data

    func testCompileFromRulesetData() {
        let json = #"[{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"||x.com^"}}]"#
        let result = DeclarativeNetRequest.compile(rulesetData: Data(json.utf8))
        XCTAssertEqual(result.compiledCount, 1)
        XCTAssertFalse(result.isEmpty)
    }

    func testCompileRejectsNonArray() {
        let result = DeclarativeNetRequest.compile(rulesetData: Data(#"{"not":"an array"}"#.utf8))
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
    }
}
