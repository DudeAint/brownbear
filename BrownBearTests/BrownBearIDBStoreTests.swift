//
//  BrownBearIDBStoreTests.swift
//  BrownBearTests
//
//  Covers the per-namespace IndexedDB snapshot store: a round-trip, and the security-critical property
//  that one namespace can never read another's snapshot (extension A vs extension B vs a userscript).
//
//  Determinism: the store writes/clears on a private serial queue, so each mutation is followed by
//  waitForPendingWrites() (a sync barrier on that queue) instead of polling — and setUp clears all test
//  namespaces up front, so the shared singleton + on-disk files can't leak state between tests.
//

import XCTest
@testable import BrownBear

final class BrownBearIDBStoreTests: XCTestCase {

    private let store = BrownBearIDBStore.shared

    private var testNamespaces: [BrownBearIDBStore.Namespace] {
        [.ext("unit-test-ext-A"), .ext("unit-test-ext-B"), .script("unit-test-ext-A")]
    }

    override func setUp() {
        super.setUp()
        for ns in testNamespaces { store.clear(namespace: ns) }
        store.waitForPendingWrites()
    }

    override func tearDown() {
        for ns in testNamespaces { store.clear(namespace: ns) }
        store.waitForPendingWrites()
        super.tearDown()
    }

    func testSaveLoadRoundTrip() {
        let json = #"{"v":1,"databases":[{"name":"d","version":1,"stores":[]}]}"#
        store.save(json, namespace: .ext("unit-test-ext-A"))
        store.waitForPendingWrites()
        XCTAssertEqual(store.load(namespace: .ext("unit-test-ext-A")), json)
    }

    func testNamespacesAreIsolated() {
        store.save("AAA", namespace: .ext("unit-test-ext-A"))
        store.waitForPendingWrites()
        XCTAssertEqual(store.load(namespace: .ext("unit-test-ext-A")), "AAA")
        // A different extension id, and the same id in the userscript space, must NOT see A's data.
        XCTAssertNil(store.load(namespace: .ext("unit-test-ext-B")))
        XCTAssertNil(store.load(namespace: .script("unit-test-ext-A")))
    }

    func testClearRemovesSnapshot() {
        store.save("X", namespace: .ext("unit-test-ext-A"))
        store.waitForPendingWrites()
        XCTAssertEqual(store.load(namespace: .ext("unit-test-ext-A")), "X")
        store.clear(namespace: .ext("unit-test-ext-A"))
        store.waitForPendingWrites()
        XCTAssertNil(store.load(namespace: .ext("unit-test-ext-A")))
    }
}
