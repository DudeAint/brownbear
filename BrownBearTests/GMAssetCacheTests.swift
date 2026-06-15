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

    // MARK: - Size cap + LRU eviction

    /// ~20 KB of data encodes to ~27 KB on disk (base64). A cap that fits two such entries but not three
    /// makes the eviction behavior deterministic without depending on exact byte counts.
    private func bigEntry(_ tag: UInt8) -> GMAssetCache.Entry {
        GMAssetCache.Entry(data: Data(repeating: tag, count: 20_000),
                           etag: nil, lastModified: nil, mimeType: "text/plain")
    }

    func testTotalBytesCountsTheOnDiskEntry() async {
        let cache = GMAssetCache(directory: directory, maxBytes: 10_000_000)
        let empty = await cache.totalBytes()
        XCTAssertEqual(empty, 0, "an empty cache is zero bytes")
        await cache.store(bigEntry(0x11), for: url("https://example.com/a.js"))
        let bytes = await cache.totalBytes()
        XCTAssertGreaterThan(bytes, 20_000, "totalBytes reflects the stored (base64-encoded) entry on disk")
    }

    func testStoringPastTheCapEvictsBackUnderIt() async {
        let cache = GMAssetCache(directory: directory, maxBytes: 75_000)   // fits ~two 27 KB entries, not three
        await cache.store(bigEntry(0x01), for: url("https://example.com/1.js"))
        await cache.store(bigEntry(0x02), for: url("https://example.com/2.js"))
        await cache.store(bigEntry(0x03), for: url("https://example.com/3.js"))
        let total = await cache.totalBytes()
        XCTAssertLessThanOrEqual(total, 75_000, "the third store evicts the cache back under the cap")
        XCTAssertGreaterThan(total, 0, "eviction trims to the target, it doesn't wipe the cache")
    }

    func testLoneOversizedEntryIsKeptNotWiped() async {
        // A single @require bigger than the whole cap must survive — eviction must never empty the cache,
        // or the heavy library the cache exists to protect would be wiped by the store that wrote it.
        let cache = GMAssetCache(directory: directory, maxBytes: 30_000)   // smaller than one ~27 KB entry? no — make it tiny
        let huge = GMAssetCache.Entry(data: Data(repeating: 0x7E, count: 50_000),   // ~67 KB on disk, > the 30 KB cap
                                      etag: nil, lastModified: nil, mimeType: "application/javascript")
        let u = url("https://cdn.example.com/huge-lib.js")
        await cache.store(huge, for: u)
        let loaded = await cache.entry(for: u)
        XCTAssertEqual(loaded, huge, "the lone oversized entry is kept (cache never evicts to empty)")
        XCTAssertGreaterThan(await cache.totalBytes(), 30_000, "the cache may exceed the cap by one large survivor")
    }

    func testEvictionIsLRU_recentlyReadEntrySurvives() async {
        let cache = GMAssetCache(directory: directory, maxBytes: 75_000)
        let a = url("https://example.com/a.js")
        let b = url("https://example.com/b.js")
        let c = url("https://example.com/c.js")
        await cache.store(bigEntry(0xAA), for: a)
        await cache.store(bigEntry(0xBB), for: b)
        // Read A so it's the most-recently-used; B becomes the least-recently-used.
        _ = await cache.entry(for: a)
        await cache.store(bigEntry(0xCC), for: c)   // pushes over the cap → evicts the LRU entry
        let survivesA = await cache.entry(for: a)
        let evictedB = await cache.entry(for: b)
        let survivesC = await cache.entry(for: c)
        XCTAssertNotNil(survivesA, "the recently-read entry (jQuery-on-every-nav pattern) is kept")
        XCTAssertNil(evictedB, "the least-recently-used entry is evicted first")
        XCTAssertNotNil(survivesC, "the just-stored entry is kept")
    }
}
