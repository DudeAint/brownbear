//
//  GMValueStoreTests.swift
//  BrownBearTests
//
//  GMValueStore.clearReturningOld — the read-modify variant the dashboard "Clear all values" button uses to
//  broadcast deletions to open pages (live GM_getValue / value-change listeners, TM/VM cross-context
//  parity). Verifies it returns every wiped key with its old value, empties the namespace, stays isolated
//  per script, and that deleteValueReturningOld reports nil for a missing key (so the dashboard skips a
//  no-op broadcast). Pure actor logic over an isolated UserDefaults suite — no UI, no device.
//

import XCTest
@testable import BrownBear

final class GMValueStoreTests: XCTestCase {

    private func makeStore() -> (store: GMValueStore, suite: String) {
        let suite = "com.brownbear.gmstore.test.\(UUID().uuidString)"
        return (GMValueStore(suiteName: suite), suite)
    }

    private func cleanup(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testClearReturningOldReturnsWipedPairsAndEmpties() async {
        let (store, suite) = makeStore()
        defer { cleanup(suite) }
        let id = UUID()
        await store.setValue(scriptID: id, key: "a", jsonValue: "1")
        await store.setValue(scriptID: id, key: "b", jsonValue: "\"two\"")

        let removed = await store.clearReturningOld(scriptID: id)
        let asDict = Dictionary(uniqueKeysWithValues: removed.map { ($0.key, $0.old ?? "") })
        XCTAssertEqual(removed.count, 2, "every key is reported")
        XCTAssertEqual(asDict["a"], "1", "the old value is reported for broadcasting")
        XCTAssertEqual(asDict["b"], "\"two\"")

        let snapshot = await store.snapshot(scriptID: id)
        XCTAssertTrue(snapshot.isEmpty, "the namespace is wiped")
    }

    func testClearReturningOldOnEmptyNamespaceIsNoOp() async {
        let (store, suite) = makeStore()
        defer { cleanup(suite) }
        let removed = await store.clearReturningOld(scriptID: UUID())
        XCTAssertTrue(removed.isEmpty, "nothing to wipe → nothing to broadcast")
    }

    func testClearIsNamespaceIsolated() async {
        let (store, suite) = makeStore()
        defer { cleanup(suite) }
        let scriptA = UUID(), scriptB = UUID()
        await store.setValue(scriptID: scriptA, key: "k", jsonValue: "1")
        await store.setValue(scriptID: scriptB, key: "k", jsonValue: "2")

        _ = await store.clearReturningOld(scriptID: scriptA)

        let bValue = await store.value(scriptID: scriptB, key: "k")
        XCTAssertEqual(bValue, "2", "clearing script A must never touch script B (CLAUDE.md §5.3)")
    }

    func testDeleteValueReturningOldIsNilForMissingKey() async {
        let (store, suite) = makeStore()
        defer { cleanup(suite) }
        let old = await store.deleteValueReturningOld(scriptID: UUID(), key: "absent")
        XCTAssertNil(old, "deleting an unset key returns nil, so the dashboard delete path skips a no-op broadcast")
    }
}
