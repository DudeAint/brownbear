//
//  BrownBearIDBStoreTests.swift
//  BrownBearTests
//
//  Covers the per-namespace IndexedDB snapshot store: a round-trip, and the security-critical property
//  that one namespace can never read another's snapshot (extension A vs extension B vs a userscript).
//

import XCTest
@testable import BrownBear

final class BrownBearIDBStoreTests: XCTestCase {

    private let store = BrownBearIDBStore.shared

    override func tearDown() {
        for ns in testNamespaces { store.clear(namespace: ns) }
        super.tearDown()
    }

    private var testNamespaces: [BrownBearIDBStore.Namespace] {
        [.ext("unit-test-ext-A"), .ext("unit-test-ext-B"), .script("unit-test-ext-A")]
    }

    /// Poll `load` until it matches (save is async on a private queue).
    private func waitForLoad(_ ns: BrownBearIDBStore.Namespace, expected: String?, timeout: TimeInterval = 3) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var value = store.load(namespace: ns)
        while value != expected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            value = store.load(namespace: ns)
        }
        return value
    }

    func testSaveLoadRoundTrip() {
        let json = #"{"v":1,"databases":[{"name":"d","version":1,"stores":[]}]}"#
        store.save(json, namespace: .ext("unit-test-ext-A"))
        XCTAssertEqual(waitForLoad(.ext("unit-test-ext-A"), expected: json), json)
    }

    func testNamespacesAreIsolated() {
        store.save("AAA", namespace: .ext("unit-test-ext-A"))
        XCTAssertEqual(waitForLoad(.ext("unit-test-ext-A"), expected: "AAA"), "AAA")
        // A different extension id, and the same id in the userscript space, must NOT see A's data.
        XCTAssertNil(store.load(namespace: .ext("unit-test-ext-B")))
        XCTAssertNil(store.load(namespace: .script("unit-test-ext-A")))
    }

    func testClearRemovesSnapshot() {
        store.save("X", namespace: .ext("unit-test-ext-A"))
        XCTAssertEqual(waitForLoad(.ext("unit-test-ext-A"), expected: "X"), "X")
        store.clear(namespace: .ext("unit-test-ext-A"))
        XCTAssertNil(waitForLoad(.ext("unit-test-ext-A"), expected: nil))
    }
}
