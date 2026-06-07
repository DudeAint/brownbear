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
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-site-\(UUID().uuidString).json")
        return (SiteSettingsStore(fileURL: fileURL), fileURL)
    }

    /// Non-failing URL builder for static literals — keeps the tests free of force-unwraps.
    private func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/invalid-test-url")
    }

    func testWwwAndPathsShareOneHostEntry() async {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await store.setDesktopUA(true, for: url("https://www.example.com/a"))
        let viaOtherPath = await store.settings(for: url("https://example.com/b?q=1"))
        XCTAssertEqual(viaOtherPath.desktopUA, true, "www + path differences map to the same host")

        let hosts = await store.allHosts()
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.host, "example.com")
    }

    func testEmptyEntryIsPruned() async {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let site = url("https://example.com")

        await store.setZoom(1.5, for: site)
        let afterSet = await store.allHosts().count
        XCTAssertEqual(afterSet, 1)

        await store.setZoom(nil, for: site)   // back to default → entry pins nothing
        let afterReset = await store.allHosts().count
        XCTAssertEqual(afterReset, 0, "an entry that pins nothing is pruned")
    }

    func testIndependentFieldsCoexist() async {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let site = url("https://example.com")

        await store.setDesktopUA(true, for: site)
        await store.setBlockContent(false, for: site)
        let settings = await store.settings(for: site)
        XCTAssertEqual(settings.desktopUA, true)
        XCTAssertEqual(settings.blockContent, false)
        XCTAssertNil(settings.zoom)
    }

    func testHostlessURLsAreIgnored() async {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await store.setZoom(2.0, for: url("about:blank"))
        let count = await store.allHosts().count
        XCTAssertEqual(count, 0, "about:blank has no host to scope to")
    }

    func testPersistsAcrossInstances() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-site-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let first = SiteSettingsStore(fileURL: fileURL)
        await first.setZoom(1.25, for: url("https://keep.com"))

        let second = SiteSettingsStore(fileURL: fileURL)
        let settings = await second.settings(for: url("https://keep.com"))
        XCTAssertEqual(settings.zoom, 1.25)
    }
}
