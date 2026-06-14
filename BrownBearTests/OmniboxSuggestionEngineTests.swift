//
//  OmniboxSuggestionEngineTests.swift
//  BrownBearTests
//
//  Pure-logic tests for the omnibox suggestion engine: the typed-text default row leads, history
//  matches follow and are de-duplicated against it, and blank input yields nothing.
//

import XCTest
@testable import BrownBear

final class OmniboxSuggestionEngineTests: XCTestCase {

    private let template = "https://www.google.com/search?q=%@"

    private func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/invalid")
    }

    func testBlankQueryYieldsNoSuggestions() {
        XCTAssertTrue(OmniboxSuggestionEngine.compose(rawQuery: "   ", historyMatches: [],
                                                      searchTemplate: template).isEmpty)
    }

    func testSearchQueryLeadsWithSearchRow() {
        let result = OmniboxSuggestionEngine.compose(rawQuery: "hello world", historyMatches: [],
                                                     searchTemplate: template)
        XCTAssertEqual(result.first?.kind, .search)
        XCTAssertEqual(result.first?.title, "hello world")
        XCTAssertEqual(result.first?.iconName, "magnifyingglass")
    }

    func testHostLikeQueryLeadsWithURLRow() {
        let result = OmniboxSuggestionEngine.compose(rawQuery: "example.com", historyMatches: [],
                                                     searchTemplate: template)
        XCTAssertEqual(result.first?.kind, .url)
        XCTAssertEqual(result.first?.url, url("https://example.com"))
    }

    func testHistoryMatchesFollowDefaultRow() {
        let history = [
            HistoryEntry(url: url("https://news.example.org/a"), title: "Example News"),
            HistoryEntry(url: url("https://blog.example.net/b"), title: "Example Blog")
        ]
        let result = OmniboxSuggestionEngine.compose(rawQuery: "example things",
                                                     historyMatches: history, searchTemplate: template)
        XCTAssertEqual(result.count, 3)                 // 1 default + 2 history
        XCTAssertEqual(result[0].kind, .search)
        XCTAssertEqual(result[1].kind, .history)
        XCTAssertEqual(result[1].title, "Example News")
        XCTAssertEqual(result[2].title, "Example Blog")
    }

    func testHistoryEntryEqualToDefaultURLIsDeduped() {
        // Typing a bare host produces a .url default for https://example.com; a history entry for the
        // exact same URL must not appear twice.
        let history = [HistoryEntry(url: url("https://example.com"), title: "Example")]
        let result = OmniboxSuggestionEngine.compose(rawQuery: "example.com",
                                                     historyMatches: history, searchTemplate: template)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .url)
    }

    // MARK: - Search bangs

    func testActiveBangNamesTheEngineInTheDefaultRow() {
        let result = OmniboxSuggestionEngine.compose(rawQuery: "!yt funny cats", historyMatches: [],
                                                     searchTemplate: template)
        XCTAssertEqual(result.first?.kind, .search)
        XCTAssertEqual(result.first?.title, "!yt funny cats")
        XCTAssertEqual(result.first?.subtitle, "Search YouTube")
    }

    func testTrailingBangAlsoNamesTheEngine() {
        let result = OmniboxSuggestionEngine.compose(rawQuery: "swift docs !gh", historyMatches: [],
                                                     searchTemplate: template)
        XCTAssertEqual(result.first?.subtitle, "Search GitHub")
    }

    func testTypingBangPrefixListsMatchingEngines() {
        let result = OmniboxSuggestionEngine.compose(rawQuery: "!g", historyMatches: [],
                                                     searchTemplate: template)
        // "!g" matches "g" (Google) and "gh" (GitHub); shortest key first.
        XCTAssertEqual(result.first?.title, "!g")
        XCTAssertEqual(result.first?.subtitle, "Google")
        XCTAssertTrue(result.contains { $0.title == "!gh" && $0.subtitle == "GitHub" })
    }

    func testBareBangListsAllEngines() {
        let result = OmniboxSuggestionEngine.compose(rawQuery: "!", historyMatches: [],
                                                     searchTemplate: template)
        XCTAssertEqual(result.count, SearchBangRegistry.defaults.count)
        XCTAssertTrue(result.allSatisfy { $0.title.hasPrefix("!") })
    }

    func testTopSitesMapToHistorySuggestions() {
        let entries = [
            HistoryEntry(url: url("https://a.com"), title: "A"),
            HistoryEntry(url: url("https://www.b.com"), title: "B")
        ]
        let result = OmniboxSuggestionEngine.topSites(entries)
        XCTAssertEqual(result.map(\.kind), [.history, .history])
        XCTAssertEqual(result[1].subtitle, "b.com")     // www-stripped host
    }
}
