//
//  ConnectGrantStoreTests.swift
//  BrownBearTests
//
//  Per-script @connect grants (the ScriptCat "allow always for this script" decision): exact + parent
//  -domain matching, revocation with pruning, per-script isolation, and persistence across instances.
//

import XCTest
@testable import BrownBear

final class ConnectGrantStoreTests: XCTestCase {

    private func tempStore() -> (ConnectGrantStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-grants-\(UUID().uuidString).json")
        return (ConnectGrantStore(fileURL: url), url)
    }

    func testDefaultDenyThenAllow() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let script = UUID()

        var allowed = await store.isAllowed(scriptID: script, host: "api.example.com")
        XCTAssertFalse(allowed, "fail closed until granted")

        await store.allow(scriptID: script, host: "api.example.com")
        allowed = await store.isAllowed(scriptID: script, host: "api.example.com")
        XCTAssertTrue(allowed)
    }

    func testGrantCoversSubdomains() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let script = UUID()
        await store.allow(scriptID: script, host: "Example.com")   // case-insensitive

        let sub = await store.isAllowed(scriptID: script, host: "cdn.example.com")
        let exact = await store.isAllowed(scriptID: script, host: "example.com")
        let other = await store.isAllowed(scriptID: script, host: "evil.com")
        XCTAssertTrue(sub)
        XCTAssertTrue(exact)
        XCTAssertFalse(other)
    }

    func testGrantsArePerScript() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let scriptA = UUID(), scriptB = UUID()
        await store.allow(scriptID: scriptA, host: "a.com")

        let leaks = await store.isAllowed(scriptID: scriptB, host: "a.com")
        XCTAssertFalse(leaks, "one script's grant must not apply to another")
    }

    func testRevokeAndClearPrune() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let script = UUID()
        await store.allow(scriptID: script, host: "a.com")
        await store.allow(scriptID: script, host: "b.com")

        await store.revoke(scriptID: script, host: "a.com")
        let hosts = await store.allowedHosts(scriptID: script)
        XCTAssertEqual(hosts, ["b.com"])

        await store.clear(scriptID: script)
        let after = await store.allowedHosts(scriptID: script)
        XCTAssertTrue(after.isEmpty)
    }

    func testPersistsAcrossInstances() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-grants-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let script = UUID()

        let first = ConnectGrantStore(fileURL: url)
        await first.allow(scriptID: script, host: "kept.com")

        let second = ConnectGrantStore(fileURL: url)
        let allowed = await second.isAllowed(scriptID: script, host: "kept.com")
        XCTAssertTrue(allowed)
    }
}
