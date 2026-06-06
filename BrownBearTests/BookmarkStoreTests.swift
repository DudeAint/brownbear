//
//  BookmarkStoreTests.swift
//  BrownBearTests
//
//  Pure-logic tests for the bookmark store: dedup + URL-identity normalization, toggle, remove,
//  and persistence across instances. (awaits are hoisted out of XCTAssert autoclosures, which
//  cannot host `await`.)
//

import XCTest
@testable import BrownBear

final class BookmarkStoreTests: XCTestCase {

    private func makeStore() -> (BookmarkStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-bm-\(UUID().uuidString).json")
        return (BookmarkStore(fileURL: url), url)
    }

    func testAddDedupesByNormalizedURL() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let page = URL(string: "https://example.com/page")!

        _ = await store.add(title: "A", url: page)
        _ = await store.add(title: "A again", url: URL(string: "https://example.com/page/")!)  // trailing slash
        _ = await store.add(title: "A upper", url: URL(string: "https://EXAMPLE.com/page")!)    // case

        let all = await store.all()
        XCTAssertEqual(all.count, 1, "dedup by normalized URL")
        let hasExact = await store.contains(url: page)
        XCTAssertTrue(hasExact)
        let hasSlash = await store.contains(url: URL(string: "https://example.com/page/")!)
        XCTAssertTrue(hasSlash)
    }

    func testCaseSensitivePathsAreNotMerged() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        // Path case is significant (RFC 3986): these are two distinct accounts, not a dup.
        _ = await store.add(title: "Upper", url: URL(string: "https://github.com/Octocat")!)
        _ = await store.add(title: "lower", url: URL(string: "https://github.com/octocat")!)
        let all = await store.all()
        XCTAssertEqual(all.count, 2, "case-sensitive paths must stay distinct")
    }

    func testToggleAddsThenRemoves() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let page = URL(string: "https://x.com/")!

        let on = await store.toggle(title: "X", url: page)
        XCTAssertTrue(on)
        let afterOn = await store.contains(url: page)
        XCTAssertTrue(afterOn)

        let off = await store.toggle(title: "X", url: page)
        XCTAssertFalse(off)
        let afterOff = await store.contains(url: page)
        XCTAssertFalse(afterOff)
    }

    func testRemoveByID() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmark = await store.add(title: "A", url: URL(string: "https://a.com")!)
        await store.remove(id: bookmark.id)
        let count = await store.all().count
        XCTAssertEqual(count, 0)
    }

    func testPersistsAcrossInstances() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-bm-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = BookmarkStore(fileURL: url)
        _ = await first.add(title: "Keep", url: URL(string: "https://keep.com")!)

        let second = BookmarkStore(fileURL: url)
        let all = await second.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Keep")
    }
}
