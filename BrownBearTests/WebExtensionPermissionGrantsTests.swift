//
//  WebExtensionPermissionGrantsTests.swift
//  BrownBearTests
//
//  The runtime grant store behind chrome.permissions.request/remove and runtime.setUninstallURL:
//  grants are per-extension isolated, removal prunes, the uninstall URL round-trips, and everything
//  persists across a fresh store pointed at the same file.
//

import XCTest
@testable import BrownBear

final class WebExtensionPermissionGrantsTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bbperms-\(UUID().uuidString).json")
    }

    func testGrantAndQuery() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks"], origins: ["https://a.com/*"]))
        let granted = await store.granted(extensionID: "ext1")
        XCTAssertEqual(granted.permissions, ["bookmarks"])
        XCTAssertEqual(granted.origins, ["https://a.com/*"])
    }

    func testGrantsAreIsolatedPerExtension() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks"]))
        let other = await store.granted(extensionID: "ext2")
        XCTAssertTrue(other.isEmpty, "one extension's grants never leak to another")
    }

    func testGrantUnionsWithExisting() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks"]))
        await store.grant(extensionID: "ext1", .init(permissions: ["history"]))
        let granted = await store.granted(extensionID: "ext1")
        XCTAssertEqual(granted.permissions, ["bookmarks", "history"])
    }

    func testSetGrantedReplacesAndPrunes() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks", "history"]))
        await store.setGranted(extensionID: "ext1", .init(permissions: ["history"]))
        let afterReplace = await store.granted(extensionID: "ext1")
        XCTAssertEqual(afterReplace.permissions, ["history"])
        await store.setGranted(extensionID: "ext1", .init())
        let afterEmpty = await store.granted(extensionID: "ext1")
        XCTAssertTrue(afterEmpty.isEmpty)
    }

    func testUninstallURLRoundTrips() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        await store.setUninstallURL(extensionID: "ext1", url: "https://bye.example/")
        let stored = await store.uninstallURL(extensionID: "ext1")
        XCTAssertEqual(stored, "https://bye.example/")
        await store.setUninstallURL(extensionID: "ext1", url: "")
        let cleared = await store.uninstallURL(extensionID: "ext1")
        XCTAssertNil(cleared)
    }

    func testClearDropsEverything() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks"]))
        await store.setUninstallURL(extensionID: "ext1", url: "https://bye.example/")
        await store.clear(extensionID: "ext1")
        let granted = await store.granted(extensionID: "ext1")
        XCTAssertTrue(granted.isEmpty)
        let url = await store.uninstallURL(extensionID: "ext1")
        XCTAssertNil(url)
    }

    func testPersistsAcrossInstances() async {
        let url = tempURL()
        let first = WebExtensionPermissionGrants(fileURL: url)
        await first.grant(extensionID: "ext1", .init(permissions: ["bookmarks"], origins: ["https://a.com/*"]))
        await first.setUninstallURL(extensionID: "ext1", url: "https://bye.example/")

        let second = WebExtensionPermissionGrants(fileURL: url)
        let granted = await second.granted(extensionID: "ext1")
        XCTAssertEqual(granted.permissions, ["bookmarks"])
        XCTAssertEqual(granted.origins, ["https://a.com/*"])
        let storedURL = await second.uninstallURL(extensionID: "ext1")
        XCTAssertEqual(storedURL, "https://bye.example/")
    }
}
