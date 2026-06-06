//
//  OmniboxInputClassifierTests.swift
//  BrownBearTests
//
//  Table-driven tests for the omnibox URL/search heuristic — the logic that decides whether
//  typed text navigates or searches. Includes malformed and edge input per CLAUDE.md §6.
//

import XCTest
@testable import BrownBear

final class OmniboxInputClassifierTests: XCTestCase {

    private let classifier = OmniboxInputClassifier(searchTemplate: "https://example-search.test/?q=%@")

    // MARK: - Navigations

    func testBareHostBecomesHTTPSURL() throws {
        let destination = try classifier.destination(for: "example.com")
        guard case .url(let url) = destination else { return XCTFail("expected .url, got \(destination)") }
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testHostWithPathAndPort() throws {
        let destination = try classifier.destination(for: "example.com:8080/path?x=1")
        guard case .url(let url) = destination else { return XCTFail("expected .url") }
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.port, 8080)
    }

    func testExplicitHTTPSchemeIsHonored() throws {
        let destination = try classifier.destination(for: "http://insecure.example/page")
        guard case .url(let url) = destination else { return XCTFail("expected .url") }
        XCTAssertEqual(url.scheme, "http")
    }

    func testLocalhostWithPortIsURL() throws {
        let destination = try classifier.destination(for: "localhost:3000")
        guard case .url(let url) = destination else { return XCTFail("expected .url") }
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 3000)
    }

    func testIPv4IsURL() throws {
        let destination = try classifier.destination(for: "192.168.0.1/admin")
        guard case .url(let url) = destination else { return XCTFail("expected .url") }
        XCTAssertEqual(url.host, "192.168.0.1")
    }

    func testAboutBlankIsURL() throws {
        let destination = try classifier.destination(for: "about:blank")
        guard case .url(let url) = destination else { return XCTFail("expected .url") }
        XCTAssertEqual(url.absoluteString, "about:blank")
    }

    // MARK: - Searches

    func testMultiWordQueryBecomesSearch() throws {
        let destination = try classifier.destination(for: "best swift libraries")
        guard case .search(let url) = destination else { return XCTFail("expected .search") }
        XCTAssertTrue(url.absoluteString.hasPrefix("https://example-search.test/?q="))
        XCTAssertTrue(url.absoluteString.contains("best%20swift%20libraries"))
    }

    func testSingleWordWithoutDotIsSearch() throws {
        let destination = try classifier.destination(for: "swift")
        guard case .search = destination else { return XCTFail("expected .search for a bare word") }
    }

    func testSingleWordWithDotIsURL() throws {
        let destination = try classifier.destination(for: "swift.org")
        guard case .url = destination else { return XCTFail("expected .url for a dotted host") }
    }

    func testQueryWithSpecialCharactersIsEncoded() throws {
        let destination = try classifier.destination(for: "c++ & rust?")
        guard case .search(let url) = destination else { return XCTFail("expected .search") }
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertTrue(url.absoluteString.contains("%26")) // '&' encoded
    }

    func testTrailingDotIsNotAValidTLD() throws {
        // "foo." has no real TLD label, so it should be treated as a search, not a host.
        let destination = try classifier.destination(for: "foo.")
        guard case .search = destination else { return XCTFail("expected .search for 'foo.'") }
    }

    func testNumericTLDIsRejectedAsHost() throws {
        // A TLD must be letters; "1.2" is not a hostname (and not a full IPv4), so → search.
        let destination = try classifier.destination(for: "1.2")
        guard case .search = destination else { return XCTFail("expected .search for '1.2'") }
    }

    // MARK: - Invalid

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try classifier.destination(for: "   ")) { error in
            XCTAssertEqual(error as? BrownBearError, .invalidOmniboxInput("   "))
        }
    }

    // MARK: - NavigationState display helpers

    func testDisplayHostStripsWWW() {
        var state = NavigationState()
        state.url = URL(string: "https://www.apple.com/iphone")
        XCTAssertEqual(state.displayHost, "apple.com")
    }

    func testDisplayTitleFallsBackToHostThenPlaceholder() {
        var state = NavigationState()
        XCTAssertEqual(state.displayTitle, "New Tab")
        state.url = URL(string: "https://news.ycombinator.com")
        XCTAssertEqual(state.displayTitle, "news.ycombinator.com")
        state.title = "Hacker News"
        XCTAssertEqual(state.displayTitle, "Hacker News")
    }
}
