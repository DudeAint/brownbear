//
//  VerticalTabsTests.swift
//  BrownBearTests
//
//  Tests the pure pieces of the Orion/Kagi vertical-tabs panel: the title/host search filter (the only
//  logic that can diverge from the grid) and the new tab-switcher AppSettings (default, round-trip, and
//  the invalid-rawValue fallback the getters rely on). The panel view itself is UIKit and exercised by
//  the CI build + device pass, not here.
//

import XCTest
@testable import BrownBear

final class VerticalTabsTests: XCTestCase {

    // MARK: - Search filter (VerticalTabsPanelViewController.tabMatches)

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(VerticalTabsPanelViewController.tabMatches(title: "Anything", host: "example.com", query: ""))
        XCTAssertTrue(VerticalTabsPanelViewController.tabMatches(title: "", host: nil, query: "   "))
    }

    func testMatchesOnTitleCaseInsensitively() {
        XCTAssertTrue(VerticalTabsPanelViewController.tabMatches(title: "Tampermonkey Dashboard",
                                                                host: "openuserjs.org", query: "tamper"))
        XCTAssertTrue(VerticalTabsPanelViewController.tabMatches(title: "GitHub", host: nil, query: "HUB"))
    }

    func testMatchesOnHostWhenTitleDoesNot() {
        XCTAssertTrue(VerticalTabsPanelViewController.tabMatches(title: "Untitled",
                                                                host: "news.ycombinator.com", query: "ycombinator"))
    }

    func testNoMatchReturnsFalse() {
        XCTAssertFalse(VerticalTabsPanelViewController.tabMatches(title: "Weather",
                                                                 host: "weather.com", query: "stocks"))
    }

    func testNilHostWithNonMatchingTitleIsFalse() {
        XCTAssertFalse(VerticalTabsPanelViewController.tabMatches(title: "New Tab", host: nil, query: "github"))
    }

    func testQueryIsTrimmedBeforeMatching() {
        XCTAssertTrue(VerticalTabsPanelViewController.tabMatches(title: "Reddit", host: "reddit.com", query: "  reddit  "))
    }

    // MARK: - Settings enums

    func testSwitcherStyleAndSideTitlesAndCases() {
        XCTAssertEqual(TabSwitcherStyle.allCases, [.grid, .vertical])
        XCTAssertEqual(TabSwitcherStyle.grid.title, "Grid")
        XCTAssertEqual(TabSwitcherStyle.vertical.title, "Vertical list")
        XCTAssertEqual(VerticalTabsSide.allCases, [.right, .left])
        XCTAssertEqual(VerticalTabsSide.right.title, "Right")
        XCTAssertEqual(VerticalTabsSide.left.title, "Left")
    }

    func testInvalidRawValueIsNil() {
        // The AppSettings getters depend on an unknown stored string falling back to the default.
        XCTAssertNil(TabSwitcherStyle(rawValue: "carousel"))
        XCTAssertNil(VerticalTabsSide(rawValue: "top"))
    }

    func testAppSettingsRoundTripsAndDefaults() {
        let defaults = UserDefaults.standard
        let styleKey = AppSettings.Key.tabSwitcherStyle
        let sideKey = AppSettings.Key.verticalTabsSide
        let savedStyle = defaults.string(forKey: styleKey)
        let savedSide = defaults.string(forKey: sideKey)
        defer {
            if let savedStyle { defaults.set(savedStyle, forKey: styleKey) }
            else { defaults.removeObject(forKey: styleKey) }
            if let savedSide { defaults.set(savedSide, forKey: sideKey) }
            else { defaults.removeObject(forKey: sideKey) }
        }

        // Default (no stored value) is grid + right (Orion's default edge).
        defaults.removeObject(forKey: styleKey)
        defaults.removeObject(forKey: sideKey)
        XCTAssertEqual(AppSettings.tabSwitcherStyle, .grid)
        XCTAssertEqual(AppSettings.verticalTabsSide, .right)

        // Round-trip through the setters.
        AppSettings.tabSwitcherStyle = .vertical
        AppSettings.verticalTabsSide = .left
        XCTAssertEqual(AppSettings.tabSwitcherStyle, .vertical)
        XCTAssertEqual(AppSettings.verticalTabsSide, .left)
    }
}
