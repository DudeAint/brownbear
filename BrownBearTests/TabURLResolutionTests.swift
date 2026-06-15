//
//  TabURLResolutionTests.swift
//  BrownBearTests
//
//  A tab must not "forget" its page when WebKit reclaims its off-screen web-content process under memory
//  pressure: after that, webView.url reports nil, and without a retained anchor the tab's published state
//  — and therefore the persisted session record — would collapse to "no URL", so the tab would restore as
//  a blank New Tab even though it had a site (the saved thumbnail still showing it). Tab.resolvedURL is the
//  pure fallback rule behind that retention (real renderer URL → pending → last-committed), tested here.
//  (The live KVO/renderer timing needs a real web view, so the resolution rule is tested pure.)
//

import XCTest
@testable import BrownBear

final class TabURLResolutionTests: XCTestCase {

    private let page = URL(string: "https://example.com/article")!
    private let other = URL(string: "https://example.org/")!
    private let blank = URL(string: "about:blank")!

    // MARK: - A live renderer URL is authoritative

    func testRealRendererURLWins() {
        // Even with a stale pending/last-committed around, the renderer's real URL is the truth.
        XCTAssertEqual(
            Tab.resolvedURL(webViewURL: page, pendingURL: other, lastCommittedURL: other),
            page)
    }

    // MARK: - about:blank is the New Tab page, not a destination

    func testAboutBlankResolvesToNilAndDoesNotResurrectRetainedURL() {
        // The in-app New Tab page loads via loadHTMLString(baseURL: nil) → webView.url == about:blank.
        // It must resolve to nil (omnibox shows its placeholder) and must NOT resurrect a retained URL,
        // or a genuine New Tab would wrongly display the previous page's address.
        XCTAssertNil(Tab.resolvedURL(webViewURL: blank, pendingURL: nil, lastCommittedURL: page))
    }

    // MARK: - Renderer loss (webView.url == nil) falls back

    func testNilRendererFallsBackToLastCommittedURL() {
        // The regression this fixes: renderer reclaimed → webView.url nil, nothing pending → keep showing
        // (and persisting) the last real URL so the tab restores its page, not a New Tab.
        XCTAssertEqual(
            Tab.resolvedURL(webViewURL: nil, pendingURL: nil, lastCommittedURL: page),
            page)
    }

    func testNilRendererPrefersPendingOverLastCommitted() {
        // A queued navigation (pending) is newer intent than the last committed page, so it wins.
        XCTAssertEqual(
            Tab.resolvedURL(webViewURL: nil, pendingURL: other, lastCommittedURL: page),
            other)
    }

    func testNilRendererWithPendingOnly() {
        // A freshly created tab with a deferred first load and nothing committed yet.
        XCTAssertEqual(
            Tab.resolvedURL(webViewURL: nil, pendingURL: page, lastCommittedURL: nil),
            page)
    }

    func testNilEverywhereResolvesToNil() {
        // A brand-new blank tab with no URL anywhere → genuinely the New Tab page.
        XCTAssertNil(Tab.resolvedURL(webViewURL: nil, pendingURL: nil, lastCommittedURL: nil))
    }
}
