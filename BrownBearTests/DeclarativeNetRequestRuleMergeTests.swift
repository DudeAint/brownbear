//
//  DeclarativeNetRequestRuleMergeTests.swift
//  BrownBearTests
//
//  Tests for the static+dynamic+session DNR rule merge that feeds the WKContentRuleList compiler.
//  Pure logic — we assert on precedence (later source wins by id), slot stability (an override keeps
//  the earlier source's position), append order for new ids, and id-less passthrough.
//

import XCTest
@testable import BrownBear

final class DeclarativeNetRequestRuleMergeTests: XCTestCase {

    func testSessionOverridesDynamicOverridesStaticById() {
        let staticRules: [[String: Any]] = [["id": 1, "src": "static"], ["id": 2, "src": "static"]]
        let dynamicRules: [[String: Any]] = [["id": 2, "src": "dynamic"], ["id": 3, "src": "dynamic"]]
        let sessionRules: [[String: Any]] = [["id": 3, "src": "session"], ["id": 4, "src": "session"]]

        let merged = DeclarativeNetRequestRuleMerge.merge(staticRules: staticRules,
                                                          dynamicRules: dynamicRules,
                                                          sessionRules: sessionRules)
        XCTAssertEqual(merged.count, 4)
        // id1 untouched, id2 taken by dynamic, id3 taken by session, id4 new from session.
        XCTAssertEqual(merged[0]["id"] as? Int, 1)
        XCTAssertEqual(merged[0]["src"] as? String, "static")
        XCTAssertEqual(merged[1]["id"] as? Int, 2)
        XCTAssertEqual(merged[1]["src"] as? String, "dynamic")
        XCTAssertEqual(merged[2]["id"] as? Int, 3)
        XCTAssertEqual(merged[2]["src"] as? String, "session")
        XCTAssertEqual(merged[3]["id"] as? Int, 4)
        XCTAssertEqual(merged[3]["src"] as? String, "session")
    }

    func testOverrideKeepsEarliestSlotButLatestBody() {
        // A session rule sharing a STATIC id must replace the body but keep the static's slot, so the
        // declared rule ordering (which drives WebKit's last-match-wins evaluation) is preserved.
        let staticRules: [[String: Any]] = [["id": 10, "src": "static"], ["id": 20, "src": "static"]]
        let sessionRules: [[String: Any]] = [["id": 10, "src": "session"], ["id": 99, "src": "session"]]

        let merged = DeclarativeNetRequestRuleMerge.merge(staticRules: staticRules,
                                                          dynamicRules: [],
                                                          sessionRules: sessionRules)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0]["id"] as? Int, 10)
        XCTAssertEqual(merged[0]["src"] as? String, "session")   // body overridden
        XCTAssertEqual(merged[1]["id"] as? Int, 20)              // slot stable
        XCTAssertEqual(merged[2]["id"] as? Int, 99)              // new id appended
    }

    func testIdLessRulesPassThroughInSourceOrderAfterIdedRules() {
        let staticRules: [[String: Any]] = [["id": 5, "src": "static"], ["src": "noid-static"]]
        let dynamicRules: [[String: Any]] = [["src": "noid-dynamic"]]

        let merged = DeclarativeNetRequestRuleMerge.merge(staticRules: staticRules,
                                                          dynamicRules: dynamicRules,
                                                          sessionRules: [])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0]["id"] as? Int, 5)
        XCTAssertEqual(merged[1]["src"] as? String, "noid-static")
        XCTAssertEqual(merged[2]["src"] as? String, "noid-dynamic")
    }

    func testEmptySourcesProduceEmptyMerge() {
        XCTAssertTrue(DeclarativeNetRequestRuleMerge.merge(staticRules: [], dynamicRules: [], sessionRules: []).isEmpty)
    }

    func testDynamicOnlyMergePreservesOrder() {
        let dynamicRules: [[String: Any]] = [["id": 3], ["id": 1], ["id": 2]]
        let merged = DeclarativeNetRequestRuleMerge.merge(staticRules: [], dynamicRules: dynamicRules, sessionRules: [])
        XCTAssertEqual(merged.map { $0["id"] as? Int }, [3, 1, 2])
    }
}
