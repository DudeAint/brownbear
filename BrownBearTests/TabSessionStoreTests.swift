//
//  TabSessionStoreTests.swift
//  BrownBearTests
//
//  The tab-session persistence that restores the user's open tabs after the app closes: records
//  round-trip through UserDefaults, an empty session clears the store (an emptied window doesn't
//  resurrect tabs), and a nil active index is preserved.
//

import XCTest
@testable import BrownBear

@MainActor
final class TabSessionStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TabSessionStore.clear()
    }

    override func tearDown() {
        TabSessionStore.clear()
        super.tearDown()
    }

    func testRoundTripsRecordsAndActiveIndex() {
        let records = [
            TabSessionStore.Record(url: "https://example.com/", title: "Example"),
            TabSessionStore.Record(url: nil, title: "New Tab"),
            TabSessionStore.Record(url: "https://news.example.org/x", title: "News")
        ]
        TabSessionStore.save(records: records, activeIndex: 2)

        let session = TabSessionStore.load()
        XCTAssertEqual(session.records, records, "records (url + title + order) round-trip")
        XCTAssertEqual(session.activeIndex, 2, "the active index is preserved")
    }

    func testEmptyRecordsClearsTheSession() {
        TabSessionStore.save(records: [TabSessionStore.Record(url: "https://a.test/", title: "A")], activeIndex: 0)
        XCTAssertFalse(TabSessionStore.load().records.isEmpty, "precondition: a session is stored")

        TabSessionStore.save(records: [], activeIndex: nil)   // an emptied window
        XCTAssertTrue(TabSessionStore.load().records.isEmpty, "saving an empty session clears the store")
    }

    func testNilActiveIndexIsPreserved() {
        TabSessionStore.save(records: [TabSessionStore.Record(url: "https://a.test/", title: "A")], activeIndex: nil)
        XCTAssertNil(TabSessionStore.load().activeIndex, "a nil active index survives the round-trip")
    }

    func testLoadWithoutAnythingSavedIsEmpty() {
        XCTAssertTrue(TabSessionStore.load().records.isEmpty, "no saved session → empty records")
        XCTAssertNil(TabSessionStore.load().activeIndex, "no saved session → nil active index")
    }
}
