//
//  SiteSettingsStoreTests.swift
//  BrownBearTests
//
//  Pure-logic tests for per-host site settings: host normalization (www-stripping, sharing across
//  paths/schemes), field updates, pruning of empty entries, hostless URLs, and persistence across
//  instances. (awaits are hoisted out of XCTAssert autoclosures, which cannot host `await`.)
//

import XCTest
@testable import BrownBear

final class SiteSettingsStoreTests: XCTestCase {

    private func makeStore() -> (SiteSettingsStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-site-\(UUID().uuidString).json")
        return (SiteSettingsStore(fileURL: url), url)
    }

    func testWwwAndPathsShareOneHostEntry() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await store.setDesktopUA(true, for: URL(string: "https://www.example.com/a")!)
        let viaOtherPath = await store.settings(for: URL(string: "https://example.com/b?q=1")!)
        XCTAssertEqual(viaOtherPath.desktopUA, true, "www + path differences map to the same host")

        let hosts = await store.allHosts()
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.host, "example.com")
    }

    func testEmptyEntryIsPruned() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let site = URL(string: "https://example.com")!

        await store.setZoom(1.5, for: site)
        let afterSet = await store.allHosts().count
        XCTAssertEqual(afterSet, 1)

        await store.setZoom(nil, for: site)   // back to default → entry pins nothing
        let afterReset = await store.allHosts().count
        XCTAssertEqual(afterReset, 0, "an entry that pins nothing is pruned")
    }

    func testIndependentFieldsCoexist() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let site = URL(string: "https://example.com")!

        await store.setDesktopUA(true, for: site)
        await store.setBlockContent(false, for: site)
        let s = await store.settings(for: site)
        XCTAssertEqual(s.desktopUA, true)
        XCTAssertEqual(s.blockContent, false)
        XCTAssertNil(s.zoom)
    }

    func testHostlessURLsAreIgnored() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await store.setZoom(2.0, for: URL(string: "about:blank")!)
        let count = await store.allHosts().count
        XCTAssertEqual(count, 0, "about:blank has no host to scope to")
    }

    func testPersistsAcrossInstances() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-site-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SiteSettingsStore(fileURL: url)
        await first.setZoom(1.25, for: URL(string: "https://keep.com")!)

        let second = SiteSettingsStore(fileURL: url)
        let s = await second.settings(for: URL(string: "https://keep.com")!)
        XCTAssertEqual(s.zoom, 1.25)
    }
}
