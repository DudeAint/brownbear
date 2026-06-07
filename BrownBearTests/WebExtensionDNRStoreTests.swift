//
//  WebExtensionDNRStoreTests.swift
//  BrownBearTests
//
//  Tests the runtime DNR rule store: dynamic-rule add/remove with id validation + cap, in-memory
//  session rules, and the enabled-static-ruleset override (with unknown-id rejection). Uses an
//  isolated UserDefaults suite so the test never touches real persisted state.
//

import XCTest
@testable import BrownBear

final class WebExtensionDNRStoreTests: XCTestCase {

    private func makeStore() -> WebExtensionDNRStore {
        let suite = "test.webext.dnr.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return WebExtensionDNRStore(suiteName: suite)
    }

    func testUpdateAndGetDynamicRules() async throws {
        let store = makeStore()
        let ext = "abc"
        try await store.updateDynamicRules(extensionID: ext, update: .init(
            removeRuleIDs: [], addRules: [["id": 1, "action": ["type": "block"]], ["id": 2]]))
        var rules = await store.getDynamicRules(extensionID: ext)
        XCTAssertEqual(rules.count, 2)

        // Remove id 1, add id 3 in one update.
        try await store.updateDynamicRules(extensionID: ext, update: .init(removeRuleIDs: [1], addRules: [["id": 3]]))
        rules = await store.getDynamicRules(extensionID: ext)
        XCTAssertEqual(Set(rules.compactMap { $0["id"] as? Int }), [2, 3])
    }

    func testDuplicateDynamicIdRejected() async {
        let store = makeStore()
        do {
            try await store.updateDynamicRules(extensionID: "x", update: .init(removeRuleIDs: [], addRules: [["id": 1], ["id": 1]]))
            XCTFail("expected duplicate-id rejection")
        } catch {
            // expected — fail closed
            let rules = await store.getDynamicRules(extensionID: "x")
            XCTAssertTrue(rules.isEmpty, "a rejected update must not partially commit")
        }
    }

    func testAddRuleWithoutIdRejected() async {
        let store = makeStore()
        do {
            try await store.updateDynamicRules(extensionID: "x", update: .init(removeRuleIDs: [], addRules: [["action": ["type": "block"]]]))
            XCTFail("expected missing-id rejection")
        } catch { /* expected */ }
    }

    func testSessionRulesAreSeparateFromDynamic() async throws {
        let store = makeStore()
        try await store.updateSessionRules(extensionID: "e", update: .init(removeRuleIDs: [], addRules: [["id": 7]]))
        let session = await store.getSessionRules(extensionID: "e")
        let dynamic = await store.getDynamicRules(extensionID: "e")
        XCTAssertEqual(session.count, 1)
        XCTAssertTrue(dynamic.isEmpty)
    }

    func testEnabledRulesetOverride() async throws {
        let store = makeStore()
        let ext = "r"
        // No override yet → manifest defaults.
        var enabled = await store.enabledRulesetIDs(extensionID: ext, manifestDefaults: ["a", "b"])
        XCTAssertEqual(enabled, ["a", "b"])

        try await store.updateEnabledRulesets(extensionID: ext, manifestDefaults: ["a", "b"],
                                              allRulesetIDs: ["a", "b", "c"], disable: ["a"], enable: ["c"])
        enabled = await store.enabledRulesetIDs(extensionID: ext, manifestDefaults: ["a", "b"])
        XCTAssertEqual(enabled, ["b", "c"])
    }

    func testEnabledRulesetUnknownIdRejected() async {
        let store = makeStore()
        do {
            try await store.updateEnabledRulesets(extensionID: "r", manifestDefaults: [], allRulesetIDs: ["a"], disable: [], enable: ["zzz"])
            XCTFail("expected unknown-ruleset rejection")
        } catch { /* expected */ }
    }

    func testDynamicRulesPersistAcrossInstances() async throws {
        let suite = "test.webext.dnr.persist.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let first = WebExtensionDNRStore(suiteName: suite)
        try await first.updateDynamicRules(extensionID: "p", update: .init(removeRuleIDs: [], addRules: [["id": 42]]))
        let reopened = WebExtensionDNRStore(suiteName: suite)
        let rules = await reopened.getDynamicRules(extensionID: "p")
        XCTAssertEqual(rules.first?["id"] as? Int, 42)
    }
}
