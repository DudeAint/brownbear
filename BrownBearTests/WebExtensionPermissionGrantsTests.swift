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

    // MARK: - chrome.permissions.onAdded / onRemoved fan-out (delta diffing)

    func testGrantBroadcastsAddedDelta() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        let exp = expectation(forNotification: .brownBearExtensionPermissionsDidChange, object: nil) { note in
            guard let info = note.userInfo, info["extensionID"] as? String == "ext1" else { return false }
            let added = info["added"] as? [String: Any] ?? [:]
            let removed = info["removed"] as? [String: Any] ?? [:]
            return Set(added["permissions"] as? [String] ?? []) == ["bookmarks"]
                && Set(added["origins"] as? [String] ?? []) == ["https://a.com/*"]
                && (removed["permissions"] as? [String] ?? []).isEmpty
                && (removed["origins"] as? [String] ?? []).isEmpty
        }
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks"], origins: ["https://a.com/*"]))
        await fulfillment(of: [exp], timeout: 2.0)
    }

    func testReGrantingHeldPermissionFiresNothing() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks"]))  // first grant fires
        let exp = expectation(forNotification: .brownBearExtensionPermissionsDidChange, object: nil) { note in
            (note.userInfo?["extensionID"] as? String) == "ext1"   // any further post for ext1 = failure
        }
        exp.isInverted = true
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks"]))  // re-grant held → empty delta
        await fulfillment(of: [exp], timeout: 0.4)
    }

    func testSetGrantedBroadcastsRemovedDelta() async {
        let store = WebExtensionPermissionGrants(fileURL: tempURL())
        await store.grant(extensionID: "ext1", .init(permissions: ["bookmarks", "history"]))
        let exp = expectation(forNotification: .brownBearExtensionPermissionsDidChange, object: nil) { note in
            guard let info = note.userInfo, info["extensionID"] as? String == "ext1" else { return false }
            let added = info["added"] as? [String: Any] ?? [:]
            let removed = info["removed"] as? [String: Any] ?? [:]
            return Set(removed["permissions"] as? [String] ?? []) == ["bookmarks"]
                && (added["permissions"] as? [String] ?? []).isEmpty
        }
        await store.setGranted(extensionID: "ext1", .init(permissions: ["history"]))
        await fulfillment(of: [exp], timeout: 2.0)
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
