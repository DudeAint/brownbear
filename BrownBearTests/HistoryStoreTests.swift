//
//  HistoryStoreTests.swift
//  BrownBearTests
//
//  Pure-logic tests for the history store: visit dedup + count bumping, URL-identity normalization
//  (matching BookmarkStore), frecency ranking for top sites, substring search with host-prefix
//  priority, inline best-completion, and persistence across instances. (awaits are hoisted out of
//  XCTAssert autoclosures, which cannot host `await`.)
//

import XCTest
@testable import BrownBear

final class HistoryStoreTests: XCTestCase {

    private func makeStore() -> (HistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-hist-\(UUID().uuidString).json")
        return (HistoryStore(fileURL: url), url)
    }

    func testRevisitBumpsCountNotDuplicate() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let page = URL(string: "https://example.com/page")!

        await store.record(url: page, title: "Example")
        await store.record(url: URL(string: "https://example.com/page/")!, title: "Example")   // trailing slash
        await store.record(url: URL(string: "https://EXAMPLE.com/page#frag")!, title: "")        // case + fragment

        let all = await store.all()
        XCTAssertEqual(all.count, 1, "one normalized entry")
        XCTAssertEqual(all.first?.visitCount, 3, "every visit bumps the count")
        XCTAssertEqual(all.first?.title, "Example", "empty revisit title doesn't clobber a good one")
    }

    func testCaseSensitivePathsStayDistinct() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await store.record(url: URL(string: "https://github.com/Octocat")!, title: "Upper")
        await store.record(url: URL(string: "https://github.com/octocat")!, title: "lower")
        let all = await store.all()
        XCTAssertEqual(all.count, 2, "case-sensitive paths must not merge")
    }

    func testTopSitesRankByFrecency() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        // Three visits to news beats one visit to blog, today.
        await store.record(url: URL(string: "https://news.com")!, title: "News")
        await store.record(url: URL(string: "https://news.com")!, title: "News")
        await store.record(url: URL(string: "https://news.com")!, title: "News")
        await store.record(url: URL(string: "https://blog.com")!, title: "Blog")

        let top = await store.topSites(limit: 5)
        XCTAssertEqual(top.first?.url.host, "news.com", "most-visited recent site ranks first")
        XCTAssertEqual(top.count, 2)
    }

    func testSearchPrefersHostPrefixMatches() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await store.record(url: URL(string: "https://github.com/explore")!, title: "Explore")
        await store.record(url: URL(string: "https://example.com/git-tutorial")!, title: "Git Tutorial")

        let results = await store.search("git", limit: 10)
        XCTAssertEqual(results.count, 2, "both mention git")
        XCTAssertEqual(results.first?.url.host, "github.com", "host-prefix match outranks a path match")
    }

    func testBestCompletionMatchesHostPrefix() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await store.record(url: URL(string: "https://github.com/explore")!, title: "Explore")

        let completion = await store.bestCompletion(for: "git")
        XCTAssertEqual(completion?.url.host, "github.com")

        let none = await store.bestCompletion(for: "zz")
        XCTAssertNil(none, "no host begins with the prefix")
    }

    func testRemoveAndClear() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await store.record(url: URL(string: "https://a.com")!, title: "A")
        await store.record(url: URL(string: "https://b.com")!, title: "B")

        await store.remove(url: URL(string: "https://a.com")!)
        let afterRemove = await store.all().count
        XCTAssertEqual(afterRemove, 1)

        await store.clear()
        let afterClear = await store.all().count
        XCTAssertEqual(afterClear, 0)
    }

    func testPersistsAcrossInstances() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-hist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = HistoryStore(fileURL: url)
        await first.record(url: URL(string: "https://keep.com")!, title: "Keep")
        await first.flushNow()   // deterministic synchronous write, no debounce race

        let second = HistoryStore(fileURL: url)
        let all = await second.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "Keep")
    }
}
