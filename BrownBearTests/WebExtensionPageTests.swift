//
//  WebExtensionPageTests.swift
//  BrownBearTests
//
//  Module 6 Phase 3: the chrome-extension:// scheme handler's content-type mapping (pure) and a
//  guard that the extension page runtime is actually bundled (so popups/options can load).
//

import XCTest
@testable import BrownBear

final class WebExtensionPageTests: XCTestCase {

    func testSchemeHandlerMIMETypes() {
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "popup.html"), "text/html; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "ui/options.htm"), "text/html; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "js/popup.js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "style.css"), "text/css; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "data.json"), "application/json; charset=utf-8")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "icon.png"), "image/png")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "logo.svg"), "image/svg+xml")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "font.woff2"), "font/woff2")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "blob.bin"), "application/octet-stream")
        XCTAssertEqual(WebExtensionSchemeHandler.mimeType(forPath: "noext"), "application/octet-stream")
    }

    func testPageRuntimeIsBundled() {
        let url = Bundle.main.url(forResource: "brownbear-webext-page", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-page", withExtension: "js")
        XCTAssertNotNil(url, "brownbear-webext-page.js must be bundled so popup/options pages get chrome.*")
    }

    // MARK: - Blank/stuck-page diagnostic

    /// The load probe maps body-state + the page-module run report into a Logs line. The point of the
    /// run report is to tell apart a module that THREW (names it) from a bundle that fully ran but is
    /// still waiting on the worker — these need different fixes, so the message must distinguish them.
    func testPageDiagnostic() {
        // No run report at all (pre-bundler page, or the bundle never executed): the legacy message.
        XCTAssertEqual(
            WebExtensionPageViewController.pageDiagnostic(
                kind: "Popup", state: "blank", ran: nil, total: nil, errors: []),
            "Popup page rendered 'blank' — its script/module likely failed to run")

        // A module threw: name it. Later entries still ran (2/4), which is the Chrome-parity fix at work.
        XCTAssertEqual(
            WebExtensionPageViewController.pageDiagnostic(
                kind: "Popup", state: "still-loading", ran: 2, total: 4,
                errors: [["entry": "js/i18n.js", "message": "TypeError: undefined is not an object"]]),
            "Popup page rendered 'still-loading' — page module bundle ran 2/4 entries; "
            + "first failing module js/i18n.js: TypeError: undefined is not an object")

        // Every module ran, no errors, yet still loading → the page is waiting on the background worker,
        // NOT a failed module. Distinct cause, distinct message.
        XCTAssertEqual(
            WebExtensionPageViewController.pageDiagnostic(
                kind: "Options", state: "still-loading", ran: 7, total: 7, errors: []),
            "Options page rendered 'still-loading' — page module bundle ran 7/7 entries "
            + "(all modules ran — the page is waiting on the background worker)")

        // Page rendered OK but one entry still failed (a degraded feature) — worth a single warn that names it.
        XCTAssertEqual(
            WebExtensionPageViewController.pageDiagnostic(
                kind: "Popup", state: "ok", ran: 3, total: 4,
                errors: [["entry": "js/theme.js", "message": "boom"]]),
            "Popup page rendered 'ok' — page module bundle ran 3/4 entries; first failing module js/theme.js: boom")
    }
}
