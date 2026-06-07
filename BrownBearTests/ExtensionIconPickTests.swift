//
//  ExtensionIconPickTests.swift
//  BrownBearTests
//
//  The dashboard extension-row icon picker: from a `size → path` map it should prefer a crisp size
//  near 64 (for a 28pt view), fall back to the largest available, ignore empty paths, and return nil
//  for an empty/nil map (caller then shows the puzzle placeholder).
//

import XCTest
@testable import BrownBear

final class ExtensionIconPickTests: XCTestCase {

    func testPrefersSizeNearestSixtyFour() {
        let path = ExtensionIconView.pickIconPath(from: ["16": "a.png", "48": "b.png", "128": "c.png"])
        XCTAssertEqual(path, "b.png")   // 48 is closest to 64 within [32,128]
    }

    func testFallsBackToLargestWhenNoneInPreferredRange() {
        let path = ExtensionIconView.pickIconPath(from: ["16": "small.png", "24": "med.png"])
        XCTAssertEqual(path, "med.png")   // none in [32,128] → largest available
    }

    func testIgnoresEmptyPaths() {
        let path = ExtensionIconView.pickIconPath(from: ["48": "", "32": "ok.png"])
        XCTAssertEqual(path, "ok.png")
    }

    func testNilAndEmptyMapsReturnNil() {
        XCTAssertNil(ExtensionIconView.pickIconPath(from: nil))
        XCTAssertNil(ExtensionIconView.pickIconPath(from: [:]))
        XCTAssertNil(ExtensionIconView.pickIconPath(from: ["48": ""]))
    }

    func testNonNumericKeyTreatedAsZeroSoRealSizeWins() {
        // A bare "default_icon": "icon.png" is stored under "0"; a real size should still be chosen.
        let path = ExtensionIconView.pickIconPath(from: ["0": "bare.png", "64": "real.png"])
        XCTAssertEqual(path, "real.png")
    }
}
