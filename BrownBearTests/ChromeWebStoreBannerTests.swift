//
//  ChromeWebStoreBannerTests.swift
//  BrownBearTests
//
//  Detection logic for the in-page "Add to BrownBear" banner: recognizing a Chrome Web Store detail
//  page (new + legacy hosts) and deriving a display name from the URL slug. Non-store pages and the
//  store's non-detail pages must not trigger the banner.
//

import XCTest
@testable import BrownBear

@MainActor
final class ChromeWebStoreBannerTests: XCTestCase {

    // A real uBlock Origin-style id: 32 chars, all in a–p.
    private let sampleID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"

    private func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/invalid")
    }

    func testDetectsNewStoreHost() {
        let detail = url("https://chromewebstore.google.com/detail/ublock-origin/\(sampleID)")
        XCTAssertEqual(BrownBearBrowserViewController.chromeWebStoreExtensionID(for: detail), sampleID)
    }

    func testDetectsLegacyStorePath() {
        let detail = url("https://chrome.google.com/webstore/detail/ublock-origin/\(sampleID)")
        XCTAssertEqual(BrownBearBrowserViewController.chromeWebStoreExtensionID(for: detail), sampleID)
    }

    func testIgnoresNonStorePages() {
        XCTAssertNil(BrownBearBrowserViewController.chromeWebStoreExtensionID(for: url("https://example.com/\(sampleID)")))
        // chrome.google.com but not the /webstore path.
        XCTAssertNil(BrownBearBrowserViewController.chromeWebStoreExtensionID(for: url("https://chrome.google.com/intl/en/")))
        // Store home (no detail id in the path).
        XCTAssertNil(BrownBearBrowserViewController.chromeWebStoreExtensionID(for: url("https://chromewebstore.google.com/category/extensions")))
    }

    func testNameFromSlug() {
        let detail = url("https://chromewebstore.google.com/detail/dark-reader/\(sampleID)")
        XCTAssertEqual(BrownBearBrowserViewController.storeExtensionName(from: detail), "Dark Reader")
    }

    func testNameFallsBackWhenNoSlug() {
        // id directly under /detail with no slug component before it.
        let detail = url("https://chromewebstore.google.com/\(sampleID)")
        XCTAssertEqual(BrownBearBrowserViewController.storeExtensionName(from: detail), "this extension")
    }
}
