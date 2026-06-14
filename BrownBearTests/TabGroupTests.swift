//
//  TabGroupTests.swift
//  BrownBearTests
//
//  The tab-group model + persistence: a TabGroup round-trips through Codable, the preset colors are
//  distinct and stable, the suggested-color helper cycles the palette, and TabGroupStore persists the
//  group definitions (round-trip, empty-clears, absent-is-empty) the way the session store does for tabs.
//

import XCTest
@testable import BrownBear

@MainActor
final class TabGroupTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TabGroupStore.save([])   // clear any prior state
    }

    override func tearDown() {
        TabGroupStore.save([])
        super.tearDown()
    }

    // MARK: - Model

    func testTabGroupCodableRoundTrip() throws {
        let group = TabGroup(id: UUID(), name: "Work", color: .blue)
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(TabGroup.self, from: data)
        XCTAssertEqual(decoded, group, "id + name + color survive a Codable round-trip")
    }

    func testColorHexesAreDistinct() {
        let hexes = TabGroupColor.allCases.map(\.hex)
        XCTAssertEqual(Set(hexes).count, TabGroupColor.allCases.count, "every preset color has a distinct hex")
    }

    func testColorDisplayNamesAreNonEmpty() {
        for color in TabGroupColor.allCases {
            XCTAssertFalse(color.displayName.isEmpty, "\(color.rawValue) has a display name")
        }
    }

    func testSuggestedColorCyclesThroughPalette() {
        let all = TabGroupColor.allCases
        XCTAssertEqual(TabGroupColor.suggested(forExistingCount: 0), all[0])
        XCTAssertEqual(TabGroupColor.suggested(forExistingCount: 1), all[1])
        // Wraps back to the start once past the palette length.
        XCTAssertEqual(TabGroupColor.suggested(forExistingCount: all.count), all[0])
        XCTAssertEqual(TabGroupColor.suggested(forExistingCount: all.count + 1), all[1])
    }

    // MARK: - Store

    func testStoreRoundTripsGroupsInOrder() {
        let groups = [
            TabGroup(id: UUID(), name: "Work", color: .blue),
            TabGroup(id: UUID(), name: "Reading", color: .green),
            TabGroup(id: UUID(), name: "Shopping", color: .pink)
        ]
        TabGroupStore.save(groups)
        XCTAssertEqual(TabGroupStore.load(), groups, "groups (id + name + color + order) round-trip")
    }

    func testStoreEmptyClears() {
        TabGroupStore.save([TabGroup(id: UUID(), name: "Temp", color: .red)])
        XCTAssertFalse(TabGroupStore.load().isEmpty, "precondition: a group is stored")
        TabGroupStore.save([])
        XCTAssertTrue(TabGroupStore.load().isEmpty, "saving an empty list clears the store")
    }

    func testStoreLoadWithoutAnythingSavedIsEmpty() {
        XCTAssertTrue(TabGroupStore.load().isEmpty, "no saved groups → empty list")
    }
}
