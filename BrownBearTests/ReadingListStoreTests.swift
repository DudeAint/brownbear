//
//  ReadingListStoreTests.swift
//  BrownBearTests
//
//  Pure-logic tests for the reading-list store: dedup by normalized URL, read/unread state, unread count,
//  remove, and persistence across instances. (awaits hoisted out of XCTAssert autoclosures.)
//

import XCTest
@testable import BrownBear

final class ReadingListStoreTests: XCTestCase {

    private func makeStore() -> (ReadingListStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-rl-\(UUID().uuidString).json")
        return (ReadingListStore(fileURL: url), url)
    }

    func testAddDedupesByNormalizedURL() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await store.add(title: "A", url: URL(string: "https://example.com/page")!)
        _ = await store.add(title: "A2", url: URL(string: "https://EXAMPLE.com/page/")!)  // case + slash
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
    }

    func testNewItemsAreUnread() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = await store.add(title: "A", url: URL(string: "https://a.com")!)
        XCTAssertFalse(item.isRead)
        let unread = await store.unreadCount()
        XCTAssertEqual(unread, 1)
    }

    func testSetReadUpdatesStateAndCount() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = await store.add(title: "A", url: URL(string: "https://a.com")!)
        await store.setRead(id: item.id, true)
        let unread = await store.unreadCount()
        XCTAssertEqual(unread, 0)
        let stored = await store.all().first
        XCTAssertEqual(stored?.isRead, true)
    }

    func testMarkReadByURL() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await store.add(title: "A", url: URL(string: "https://a.com/x")!)
        await store.markRead(url: URL(string: "https://a.com/x/")!)   // trailing slash still matches
        let unread = await store.unreadCount()
        XCTAssertEqual(unread, 0)
    }

    func testRemoveByID() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = await store.add(title: "A", url: URL(string: "https://a.com")!)
        await store.remove(id: item.id)
        let count = await store.all().count
        XCTAssertEqual(count, 0)
    }

    func testPersistsAcrossInstances() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-rl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ReadingListStore(fileURL: url)
        let item = await first.add(title: "Keep", url: URL(string: "https://keep.com")!)
        await first.setRead(id: item.id, true)

        let second = ReadingListStore(fileURL: url)
        let all = await second.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Keep")
        XCTAssertEqual(all.first?.isRead, true)
    }
}
