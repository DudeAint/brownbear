//
//  WebExtensionContentResponseTests.swift
//  BrownBearTests
//
//  The native→content-script message correlation behind chrome.tabs.sendMessage: a pushed message
//  parks the sender until the content script answers (runtime.messageResponse) or a timeout fires.
//  These exercise WebExtContentResponseTable directly — the part of the messaging triangle that has
//  no WKWebView dependency — covering delivery, isolation against replayed/unknown ids (a content
//  script is untrusted), single-delivery (a CheckedContinuation resumed twice would crash), and drain.
//

import XCTest
@testable import BrownBear

@MainActor
final class WebExtensionContentResponseTests: XCTestCase {

    /// A MainActor-confined box so the test can read back the id minted inside `wait`.
    private final class IdBox { var id = "" }

    /// Let a just-created `wait` task run up to its suspension point (registering the continuation).
    private func waitUntilRegistered(_ table: WebExtContentResponseTable) async {
        var spins = 0
        while table.outstanding == 0 && spins < 1000 { await Task.yield(); spins += 1 }
    }

    func testResolveDeliversValueAndClears() async {
        let table = WebExtContentResponseTable()
        let box = IdBox()
        let waiter = Task { @MainActor in await table.wait { id in box.id = id } }

        await waitUntilRegistered(table)
        XCTAssertEqual(table.outstanding, 1)

        table.resolve(box.id, value: "pong")
        let value = await waiter.value
        XCTAssertEqual(value as? String, "pong")
        XCTAssertEqual(table.outstanding, 0)
    }

    func testResolveUnknownIdIsNoOp() {
        let table = WebExtContentResponseTable()
        table.resolve("not-a-real-id", value: 42)
        XCTAssertEqual(table.outstanding, 0)
    }

    func testDoubleResolveDeliversOnce() async {
        let table = WebExtContentResponseTable()
        let box = IdBox()
        let waiter = Task { @MainActor in await table.wait { id in box.id = id } }

        await waitUntilRegistered(table)
        table.resolve(box.id, value: "first")
        table.resolve(box.id, value: "second")   // no-op: id already cleared (and never double-resumes)

        let value = await waiter.value
        XCTAssertEqual(value as? String, "first")
        XCTAssertEqual(table.outstanding, 0)
    }

    func testDrainResolvesOutstandingWithNil() async {
        let table = WebExtContentResponseTable()
        let waiter = Task { @MainActor in await table.wait { _ in } }

        await waitUntilRegistered(table)
        XCTAssertEqual(table.outstanding, 1)

        table.drain()
        let value = await waiter.value
        XCTAssertNil(value)
        XCTAssertEqual(table.outstanding, 0)
    }

    func testDistinctIdsForConcurrentWaiters() async {
        let table = WebExtContentResponseTable()
        let first = IdBox()
        let second = IdBox()
        let waiterA = Task { @MainActor in await table.wait { id in first.id = id } }
        await waitUntilRegistered(table)
        let waiterB = Task { @MainActor in await table.wait { id in second.id = id } }
        var spins = 0
        while table.outstanding < 2 && spins < 1000 { await Task.yield(); spins += 1 }

        XCTAssertEqual(table.outstanding, 2)
        XCTAssertNotEqual(first.id, second.id)

        table.resolve(second.id, value: "B")
        table.resolve(first.id, value: "A")
        let valueA = await waiterA.value
        let valueB = await waiterB.value
        XCTAssertEqual(valueA as? String, "A")
        XCTAssertEqual(valueB as? String, "B")
        XCTAssertEqual(table.outstanding, 0)
    }
}
