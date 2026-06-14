//
//  SearchBangTests.swift
//  BrownBearTests
//
//  Pure-logic tests for the quick-search bang registry: URL building, match-in-text (leading / trailing /
//  unknown), and prefix autocomplete ordering.
//

import XCTest
@testable import BrownBear

final class SearchBangTests: XCTestCase {

    private let yt = SearchBang(key: "yt", name: "YouTube",
                                searchTemplate: "https://www.youtube.com/results?search_query=%@",
                                home: "https://www.youtube.com")

    func testURLForQueryFillsAndEncodes() {
        let url = yt.url(for: "funny cats")
        XCTAssertEqual(url?.host, "www.youtube.com")
        XCTAssertTrue(url?.absoluteString.contains("funny%20cats") ?? false)
    }

    func testURLForEmptyQueryIsHome() {
        XCTAssertEqual(yt.url(for: "")?.absoluteString, "https://www.youtube.com")
        XCTAssertEqual(yt.url(for: "   ")?.absoluteString, "https://www.youtube.com")
    }

    func testMatchLeadingBang() {
        let match = SearchBangRegistry.match(in: "!yt funny cats")
        XCTAssertEqual(match?.bang.key, "yt")
        XCTAssertEqual(match?.query, "funny cats")
    }

    func testMatchTrailingBang() {
        let match = SearchBangRegistry.match(in: "swift docs !gh")
        XCTAssertEqual(match?.bang.key, "gh")
        XCTAssertEqual(match?.query, "swift docs")
    }

    func testMatchBareBangHasEmptyQuery() {
        let match = SearchBangRegistry.match(in: "!w")
        XCTAssertEqual(match?.bang.key, "w")
        XCTAssertEqual(match?.query, "")
    }

    func testUnknownBangDoesNotMatch() {
        XCTAssertNil(SearchBangRegistry.match(in: "!zzz hello"))
        XCTAssertNil(SearchBangRegistry.match(in: "no bang here"))
        XCTAssertNil(SearchBangRegistry.match(in: "!"))   // a lone "!" is not a bang token
    }

    func testFirstKnownBangWins() {
        // Unknown "!zzz" is skipped; the known "!g" is the one that matches.
        let match = SearchBangRegistry.match(in: "!zzz !g query")
        XCTAssertEqual(match?.bang.key, "g")
        XCTAssertEqual(match?.query, "!zzz query")
    }

    func testMatchingPrefixSortsShortestKeyFirst() {
        let matches = SearchBangRegistry.matchingPrefix("g")
        XCTAssertEqual(matches.first?.key, "g")            // "g" before "gh"
        XCTAssertTrue(matches.contains { $0.key == "gh" })
    }

    func testEmptyPrefixReturnsAllBangs() {
        XCTAssertEqual(SearchBangRegistry.matchingPrefix("").count, SearchBangRegistry.defaults.count)
    }

    func testRegistryKeysAreUnique() {
        let keys = SearchBangRegistry.defaults.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "bang keys must be unique (byKey dict would crash otherwise)")
    }
}
