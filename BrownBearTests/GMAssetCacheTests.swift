//
//  GMAssetCacheTests.swift
//  BrownBearTests
//
//  The @require/@resource disk cache: an entry round-trips (bytes + ETag/Last-Modified validators +
//  mime), distinct URLs never collide while the same URL overwrites, a never-stored URL reads as nil,
//  and clear() empties the store. This is the persistence half of the offline-safe require behavior;
//  the conditional-GET network logic lives in ScriptMessageRouter.fetchAsset and needs a runtime test.
//

import XCTest
@testable import BrownBear

final class GMAssetCacheTests: XCTestCase {

    private var directory: URL!
    private var cache: GMAssetCache!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GMAssetCacheTests-\(UUID().uuidString)", isDirectory: true)
        cache = GMAssetCache(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testStoreThenEntryRoundTrips() async {
        let entry = GMAssetCache.Entry(
            data: Data("(function(){})()".utf8),
            etag: "\"abc123\"",
            lastModified: "Wed, 21 Oct 2025 07:28:00 GMT",
            mimeType: "application/javascript")
        let u = url("https://cdn.example.com/jquery.min.js")
        await cache.store(entry, for: u)
        let loaded = await cache.entry(for: u)
        XCTAssertEqual(loaded, entry, "data + validators + mime survive a disk round-trip")
    }

    func testEntryWithoutValidatorsRoundTrips() async {
        // A server can omit both ETag and Last-Modified; the optional validators must encode as nil.
        let entry = GMAssetCache.Entry(
            data: Data([0x00, 0x01, 0xFF]), etag: nil, lastModified: nil, mimeType: "image/png")
        let u = url("https://example.com/icon.png")
        await cache.store(entry, for: u)
        let loaded = await cache.entry(for: u)
        XCTAssertEqual(loaded, entry)
        XCTAssertNil(loaded?.etag)
        XCTAssertNil(loaded?.lastModified)
    }

    func testMissingURLReadsAsNil() async {
        let loaded = await cache.entry(for: url("https://example.com/never-stored.js"))
        XCTAssertNil(loaded, "an asset that was never stored reads as nil (cache miss)")
    }

    func testDistinctURLsDoNotCollide() async {
        let a = GMAssetCache.Entry(data: Data("A".utf8), etag: nil, lastModified: nil, mimeType: "text/plain")
        let b = GMAssetCache.Entry(data: Data("B".utf8), etag: nil, lastModified: nil, mimeType: "text/plain")
        await cache.store(a, for: url("https://example.com/a.js"))
        await cache.store(b, for: url("https://example.com/b.js"))
        let loadedA = await cache.entry(for: url("https://example.com/a.js"))
        let loadedB = await cache.entry(for: url("https://example.com/b.js"))
        XCTAssertEqual(loadedA, a)
        XCTAssertEqual(loadedB, b, "different URLs map to different cache files")
    }

    func testSameURLOverwrites() async {
        let u = url("https://example.com/lib.js")
        let v1 = GMAssetCache.Entry(data: Data("v1".utf8), etag: "\"1\"", lastModified: nil, mimeType: "text/plain")
        let v2 = GMAssetCache.Entry(data: Data("v2".utf8), etag: "\"2\"", lastModified: nil, mimeType: "text/plain")
        await cache.store(v1, for: u)
        await cache.store(v2, for: u)
        let loaded = await cache.entry(for: u)
        XCTAssertEqual(loaded, v2, "re-storing the same URL replaces the prior entry")
    }

    func testClearEmptiesTheStore() async {
        let entry = GMAssetCache.Entry(data: Data("x".utf8), etag: nil, lastModified: nil, mimeType: "text/plain")
        await cache.store(entry, for: url("https://example.com/one.js"))
        await cache.store(entry, for: url("https://example.com/two.js"))
        // `await` can't live inside an XCTAssert autoclosure (it doesn't support concurrency); bind first.
        let precondition = await cache.entry(for: url("https://example.com/one.js"))
        XCTAssertNotNil(precondition, "precondition: stored")
        await cache.clear()
        let loaded = await cache.entry(for: url("https://example.com/one.js"))
        XCTAssertNil(loaded, "clear() removes every cached asset")
    }
}
