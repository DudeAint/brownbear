//
//  NetworkLogEntryTests.swift
//  BrownBearTests
//
//  Pure-logic tests for the Network inspector's row model — host extraction, the path+query subtitle,
//  the failure classification used for the status-badge color, and the network store's cap/order.
//

import XCTest
@testable import BrownBear

final class NetworkLogEntryTests: XCTestCase {

    private func entry(url: String, status: Int = 200, error: String? = nil) -> NetworkLogEntry {
        NetworkLogEntry(kind: .gmXHR, method: "get", url: url, statusCode: status, error: error)
    }

    func testHostFromAbsoluteURL() {
        XCTAssertEqual(entry(url: "https://api.example.com/v1/items?q=1").host, "api.example.com")
        XCTAssertEqual(entry(url: "http://r22.core.learn.edgenuity.com/Player").host, "r22.core.learn.edgenuity.com")
    }

    func testHostFallsBackToRawForOpaqueURL() {
        // A relative or non-standard URL has no host — show the raw string rather than nothing.
        XCTAssertEqual(entry(url: "/relative/path").host, "/relative/path")
    }

    func testPathAndQuery() {
        XCTAssertEqual(entry(url: "https://x.com/a/b?c=d&e=f").pathAndQuery, "/a/b?c=d&e=f")
        XCTAssertEqual(entry(url: "https://x.com/just/path").pathAndQuery, "/just/path")
        XCTAssertEqual(entry(url: "https://x.com").pathAndQuery, "")
    }

    func testMethodIsUppercased() {
        XCTAssertEqual(entry(url: "https://x.com").method, "GET")
    }

    func testFailureClassification() {
        XCTAssertFalse(entry(url: "https://x.com", status: 200).isFailure)
        XCTAssertFalse(entry(url: "https://x.com", status: 304).isFailure)
        XCTAssertTrue(entry(url: "https://x.com", status: 404).isFailure)
        XCTAssertTrue(entry(url: "https://x.com", status: 500).isFailure)
        XCTAssertTrue(entry(url: "https://x.com", status: 0, error: "offline").isFailure)
    }

    func testKindDisplayNames() {
        XCTAssertEqual(NetworkLogEntry.Kind.gmXHR.displayName, "GM_xmlhttpRequest")
        XCTAssertEqual(NetworkLogEntry.Kind.fetch.displayName, "fetch")
        XCTAssertEqual(NetworkLogEntry.Kind.xhr.displayName, "XHR")
    }

    func testStoreCapsAndOrdersNewestFirst() async {
        let store = NetworkLogStore(capacity: 3)
        for index in 0..<5 {
            await store.append(entry(url: "https://x.com/\(index)"))
        }
        let recent = await store.recent()
        XCTAssertEqual(recent.count, 3, "evicts beyond capacity")
        // Newest first: the last appended (/4) leads, oldest retained (/2) trails.
        XCTAssertEqual(recent.first?.url, "https://x.com/4")
        XCTAssertEqual(recent.last?.url, "https://x.com/2")
    }

    func testStoreClear() async {
        let store = NetworkLogStore()
        await store.append(entry(url: "https://x.com/1"))
        await store.clear()
        let count = await store.count
        XCTAssertEqual(count, 0)
    }
}
