//
//  GMBridgeTests.swift
//  BrownBearTests
//
//  Security-critical tests for the GM bridge: per-script value isolation and the @connect
//  allowlist that gates GM_xmlhttpRequest.
//

import XCTest
@testable import BrownBear

final class GMValueStoreTests: XCTestCase {

    private func makeStore() -> GMValueStore {
        GMValueStore(suiteName: "brownbear.test.\(UUID().uuidString)")
    }

    func testNamespacingIsolatesScripts() async {
        let store = makeStore()
        let scriptA = UUID()
        let scriptB = UUID()

        await store.setValue(scriptID: scriptA, key: "token", jsonValue: "\"a-secret\"")
        await store.setValue(scriptID: scriptB, key: "token", jsonValue: "\"b-secret\"")

        let valueA = await store.value(scriptID: scriptA, key: "token")
        let valueB = await store.value(scriptID: scriptB, key: "token")
        XCTAssertEqual(valueA, "\"a-secret\"")
        XCTAssertEqual(valueB, "\"b-secret\"")

        // Script A cannot see B's keys and vice-versa.
        let keysA = await store.listValues(scriptID: scriptA)
        XCTAssertEqual(keysA, ["token"])
    }

    func testDeleteOnlyAffectsOneScript() async {
        let store = makeStore()
        let scriptA = UUID()
        let scriptB = UUID()
        await store.setValue(scriptID: scriptA, key: "k", jsonValue: "1")
        await store.setValue(scriptID: scriptB, key: "k", jsonValue: "2")

        await store.deleteValue(scriptID: scriptA, key: "k")

        let valueA = await store.value(scriptID: scriptA, key: "k")
        let valueB = await store.value(scriptID: scriptB, key: "k")
        XCTAssertNil(valueA)
        XCTAssertEqual(valueB, "2")
    }

    func testSnapshotReturnsWholeNamespace() async {
        let store = makeStore()
        let script = UUID()
        await store.setValues(scriptID: script, entries: ["a": "1", "b": "\"two\""])
        let snapshot = await store.snapshot(scriptID: script)
        XCTAssertEqual(snapshot["a"], "1")
        XCTAssertEqual(snapshot["b"], "\"two\"")
    }
}

final class ConnectAllowlistTests: XCTestCase {

    func testExactHostAllowed() {
        XCTAssertTrue(GMNetworkService.isConnectAllowed(host: "example.com", connects: ["example.com"], pageHost: nil))
    }

    func testSubdomainAllowed() {
        XCTAssertTrue(GMNetworkService.isConnectAllowed(host: "api.example.com", connects: ["example.com"], pageHost: nil))
    }

    func testUndeclaredHostRejected() {
        XCTAssertFalse(GMNetworkService.isConnectAllowed(host: "evil.com", connects: ["example.com"], pageHost: nil))
    }

    func testSuffixSpoofRejected() {
        // "example.com.evil.com" must NOT be allowed by an @connect of "example.com".
        XCTAssertFalse(GMNetworkService.isConnectAllowed(host: "example.com.evil.com", connects: ["example.com"], pageHost: nil))
    }

    func testWildcardAllowsAny() {
        XCTAssertTrue(GMNetworkService.isConnectAllowed(host: "anything.test", connects: ["*"], pageHost: nil))
    }

    func testPageHostAllowedWithoutDeclaration() {
        XCTAssertTrue(GMNetworkService.isConnectAllowed(host: "page.test", connects: [], pageHost: "page.test"))
    }

    func testLocalhostAllowed() {
        XCTAssertTrue(GMNetworkService.isConnectAllowed(host: "localhost", connects: ["localhost"], pageHost: nil))
    }

    func testNilHostRejected() {
        XCTAssertFalse(GMNetworkService.isConnectAllowed(host: nil, connects: ["*"], pageHost: nil))
    }
}
