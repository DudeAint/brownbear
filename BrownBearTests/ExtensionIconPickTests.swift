//
//  ExtensionIconPickTests.swift
//  BrownBearTests
//
//  The shared extension-action icon picker (WebExtensionIconResolver), used by BOTH the dashboard
//  Extensions list and the browser quick-menu rows. From a `size → path` map it prefers a crisp size
//  near 64 (for a 28pt view), falls back to the largest available, ignores empty paths, and returns nil
//  for an empty/nil map (caller then shows the puzzle placeholder). bestIconPath prefers the action's
//  own icon, else the manifest's top-level `icons` (the Chrome fallback that keeps both surfaces in sync).
//

import XCTest
@testable import BrownBear

final class ExtensionIconPickTests: XCTestCase {

    func testPrefersSizeNearestSixtyFour() {
        let path = WebExtensionIconResolver.pickIconPath(from: ["16": "a.png", "48": "b.png", "128": "c.png"])
        XCTAssertEqual(path, "b.png")   // 48 is closest to 64 within [32,128]
    }

    func testFallsBackToLargestWhenNoneInPreferredRange() {
        let path = WebExtensionIconResolver.pickIconPath(from: ["16": "small.png", "24": "med.png"])
        XCTAssertEqual(path, "med.png")   // none in [32,128] → largest available
    }

    func testIgnoresEmptyPaths() {
        let path = WebExtensionIconResolver.pickIconPath(from: ["48": "", "32": "ok.png"])
        XCTAssertEqual(path, "ok.png")
    }

    func testNilAndEmptyMapsReturnNil() {
        XCTAssertNil(WebExtensionIconResolver.pickIconPath(from: nil))
        XCTAssertNil(WebExtensionIconResolver.pickIconPath(from: [:]))
        XCTAssertNil(WebExtensionIconResolver.pickIconPath(from: ["48": ""]))
    }

    func testNonNumericKeyTreatedAsZeroSoRealSizeWins() {
        // A bare "default_icon": "icon.png" is stored under "0"; a real size should still be chosen.
        let path = WebExtensionIconResolver.pickIconPath(from: ["0": "bare.png", "64": "real.png"])
        XCTAssertEqual(path, "real.png")
    }

    // MARK: - bestIconPath (the action → manifest-icons fallback both surfaces share)

    func testBestIconPathPrefersActionIcon() throws {
        let manifest = try WebExtensionManifest.parse([
            "manifest_version": 3,
            "name": "X", "version": "1",
            "icons": ["128": "icons/128.png"],
            "action": ["default_icon": ["48": "action/48.png"]]
        ])
        XCTAssertEqual(WebExtensionIconResolver.bestIconPath(manifest), "action/48.png")
    }

    func testBestIconPathFallsBackToManifestIconsWhenActionHasNone() throws {
        // The common case that left the quick menu blank: an action with no default_icon. Both surfaces
        // must fall back to the top-level manifest icons so the real branded icon shows.
        let manifest = try WebExtensionManifest.parse([
            "manifest_version": 2,
            "name": "X", "version": "1",
            "icons": ["38": "icons/38.png"],
            "browser_action": [:]
        ])
        XCTAssertEqual(WebExtensionIconResolver.bestIconPath(manifest), "icons/38.png")
    }

    func testBestIconPathNilWhenNeitherDeclared() throws {
        let manifest = try WebExtensionManifest.parse([
            "manifest_version": 3, "name": "X", "version": "1"
        ])
        XCTAssertNil(WebExtensionIconResolver.bestIconPath(manifest))
        XCTAssertNil(WebExtensionIconResolver.bestIconPath(nil))
    }
}
