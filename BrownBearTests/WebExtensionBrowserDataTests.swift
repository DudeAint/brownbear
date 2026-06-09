//
//  WebExtensionBrowserDataTests.swift
//  BrownBearTests
//
//  The pure Chrome-shape mappers behind chrome.bookmarks / chrome.history / chrome.sessions: the
//  permission gate, the synthetic bookmark tree, history-item shaping, recently-closed sessions, and
//  restore-index resolution. These are what turn Vimium's unguarded getTree/search/restore calls from a
//  TypeError into real data, so the shapes must match Chrome exactly.
//

import XCTest
@testable import BrownBear

final class WebExtensionBrowserDataTests: XCTestCase {

    // MARK: - Permission gate

    func testRequiredPermissionPerNamespace() {
        XCTAssertEqual(WebExtensionBrowserData.requiredPermission(forMethod: "bookmarks.getTree"), "bookmarks")
        XCTAssertEqual(WebExtensionBrowserData.requiredPermission(forMethod: "history.search"), "history")
        XCTAssertEqual(WebExtensionBrowserData.requiredPermission(forMethod: "sessions.restore"), "sessions")
        XCTAssertNil(WebExtensionBrowserData.requiredPermission(forMethod: "search.query"))
        XCTAssertNil(WebExtensionBrowserData.requiredPermission(forMethod: "tabs.query"))
    }

    // MARK: - bookmarks

    func testBookmarkTreeShape() {
        let bm = Bookmark(title: "GitHub", url: URL(string: "https://github.com/")!,
                          createdAt: Date(timeIntervalSince1970: 2))
        let tree = WebExtensionBrowserData.bookmarkTree(from: [bm])
        XCTAssertEqual(tree.count, 1)
        let root = tree[0]
        XCTAssertEqual(root["id"] as? String, "0")
        let folders = root["children"] as? [[String: Any]]
        XCTAssertEqual(folders?.count, 1)
        let leaves = folders?[0]["children"] as? [[String: Any]]
        XCTAssertEqual(leaves?.count, 1)
        let leaf = leaves?[0]
        XCTAssertEqual(leaf?["title"] as? String, "GitHub")
        XCTAssertEqual(leaf?["url"] as? String, "https://github.com/")
        XCTAssertEqual(leaf?["id"] as? String, bm.id.uuidString)
        XCTAssertEqual(leaf?["dateAdded"] as? Int, 2000)   // epoch ms
    }

    func testBookmarkTreeEmptyStillHasRootFolder() {
        let tree = WebExtensionBrowserData.bookmarkTree(from: [])
        let folders = tree.first?["children"] as? [[String: Any]]
        XCTAssertEqual(folders?.count, 1, "an empty list still yields a walkable root → folder with no children")
        XCTAssertEqual((folders?[0]["children"] as? [[String: Any]])?.count, 0)
    }

    func testBookmarkNodeShape() {
        let bm = Bookmark(title: "GH", url: URL(string: "https://github.com/")!,
                          createdAt: Date(timeIntervalSince1970: 4))
        let node = WebExtensionBrowserData.bookmarkNode(from: bm)
        XCTAssertEqual(node["id"] as? String, bm.id.uuidString)
        XCTAssertEqual(node["parentId"] as? String, "1")
        XCTAssertEqual(node["title"] as? String, "GH")
        XCTAssertEqual(node["url"] as? String, "https://github.com/")
        XCTAssertEqual(node["dateAdded"] as? Int, 4000)
    }

    func testBookmarkSearchMatchesTitleAndURLCaseInsensitively() {
        let a = Bookmark(title: "Hacker News", url: URL(string: "https://news.ycombinator.com/")!)
        let b = Bookmark(title: "Docs", url: URL(string: "https://developer.mozilla.org/")!)
        let byTitle = WebExtensionBrowserData.bookmarkSearch("hacker", in: [a, b])
        XCTAssertEqual(byTitle.map { $0["url"] as? String }, ["https://news.ycombinator.com/"])
        let byURL = WebExtensionBrowserData.bookmarkSearch("MOZILLA", in: [a, b])
        XCTAssertEqual(byURL.map { $0["title"] as? String }, ["Docs"])
        XCTAssertEqual(WebExtensionBrowserData.bookmarkSearch("   ", in: [a, b]).count, 2, "blank query → all")
    }

    // MARK: - history

    func testHistoryItemShape() {
        let entry = HistoryEntry(url: URL(string: "https://example.com/")!, title: "Example",
                                 visitCount: 5, lastVisit: Date(timeIntervalSince1970: 3))
        let items = WebExtensionBrowserData.historyItems(from: [entry])
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item["url"] as? String, "https://example.com/")
        XCTAssertEqual(item["title"] as? String, "Example")
        XCTAssertEqual(item["visitCount"] as? Int, 5)
        XCTAssertEqual(item["typedCount"] as? Int, 0)
        XCTAssertEqual(item["lastVisitTime"] as? Double, 3000)   // epoch ms
        XCTAssertEqual(item["id"] as? String, entry.id.uuidString)
    }

    // MARK: - sessions

    func testSessionRecordsShape() {
        let closed = [
            TabManager.ClosedTabRecord(url: URL(string: "https://a.com/")!, title: "A"),
            TabManager.ClosedTabRecord(url: URL(string: "https://b.com/")!, title: "B")
        ]
        let sessions = WebExtensionBrowserData.sessionRecords(from: closed)
        XCTAssertEqual(sessions.count, 2)
        let tab0 = sessions[0]["tab"] as? [String: Any]
        XCTAssertEqual(tab0?["url"] as? String, "https://a.com/")
        XCTAssertEqual(tab0?["sessionId"] as? String, "closed-0")
        XCTAssertNotNil(sessions[0]["lastModified"])
    }

    func testRestoreIndexResolution() {
        XCTAssertEqual(WebExtensionBrowserData.restoreIndex(sessionId: nil, closedCount: 3), 0, "no id → most recent")
        XCTAssertEqual(WebExtensionBrowserData.restoreIndex(sessionId: "", closedCount: 3), 0)
        XCTAssertEqual(WebExtensionBrowserData.restoreIndex(sessionId: "closed-2", closedCount: 3), 2)
        XCTAssertNil(WebExtensionBrowserData.restoreIndex(sessionId: "closed-9", closedCount: 3), "out of range")
        XCTAssertNil(WebExtensionBrowserData.restoreIndex(sessionId: nil, closedCount: 0), "nothing to restore")
    }
}
