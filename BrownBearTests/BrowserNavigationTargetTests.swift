//
//  BrowserNavigationTargetTests.swift
//  BrownBearTests
//
//  webNavigation.onBeforeNavigate must report the navigation TARGET (where it's going), not the
//  previous committed page. The controller captures the target at policy-decision time and consumes it
//  at didStartProvisionalNavigation; beforeNavigateURL() is the capture-vs-fallback choice, tested here.
//  (The live WKNavigationDelegate timing needs a real web view, so the resolution rule is tested pure.)
//

import XCTest
@testable import BrownBear

@MainActor
final class BrowserNavigationTargetTests: XCTestCase {

    func testCapturedTargetWinsOverWebViewURL() {
        // webView.url is still the OLD page during provisional navigation; the captured target wins.
        XCTAssertEqual(
            BrownBearBrowserViewController.beforeNavigateURL(captured: "https://b.com/", fallback: "https://a.com/"),
            "https://b.com/")
    }

    func testFallsBackToWebViewURLWhenNoTargetCaptured() {
        XCTAssertEqual(
            BrownBearBrowserViewController.beforeNavigateURL(captured: nil, fallback: "https://a.com/"),
            "https://a.com/")
    }

    func testEmptyStringWhenNeitherPresent() {
        XCTAssertEqual(BrownBearBrowserViewController.beforeNavigateURL(captured: nil, fallback: nil), "")
    }
}
