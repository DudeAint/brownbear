//
//  ExtensionTabRestorePlanTests.swift
//  BrownBearTests
//
//  A persisted extension page tab (chrome-extension:// / moz-extension://) restored to the New Tab page
//  because session restore couldn't host that scheme. The fix rebuilds the per-extension page session and
//  swaps it in place; extensionRestorePlan is the pure piece that decides WHICH packaged resource to load
//  (everything after scheme://host/, preserving query/fragment) and whether it should restore as a
//  newtab-override page vs an options-style page. Tested here; the async session/web-view build + the
//  in-place TabManager swap are exercised by the CI build + device pass.
//

import XCTest
@testable import BrownBear

final class ExtensionTabRestorePlanTests: XCTestCase {

    private func plan(_ string: String, newTabOverride: String? = nil)
        -> (resource: String, isNewTabOverride: Bool) {
        BrownBearBrowserViewController.extensionRestorePlan(url: URL(string: string)!,
                                                            newTabOverride: newTabOverride)
    }

    // MARK: - Resource extraction (everything after scheme://host/)

    func testResourceIsPathAfterHost() {
        // The 32-char host is the extension id; the resource is the packaged file it should load.
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html")
        XCTAssertEqual(p.resource, "options.html")
    }

    func testResourcePreservesNestedPath() {
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/dashboard/pages/main.html")
        XCTAssertEqual(p.resource, "dashboard/pages/main.html")
    }

    func testResourcePreservesQueryAndFragment() {
        // The page must land on the EXACT resource — query + fragment carry page state (uBO dashboard panes).
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/dashboard.html?tab=settings#net")
        XCTAssertEqual(p.resource, "dashboard.html?tab=settings#net")
    }

    func testResourceEmptyForBareOrigin() {
        // chrome-extension://id/ with no path → empty resource → the session falls back to the kind-default.
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/")
        XCTAssertEqual(p.resource, "")
    }

    func testMozExtensionSchemeResource() {
        // Firefox builds serve under moz-extension://; the prefix strip is scheme-agnostic.
        let p = plan("moz-extension://abcdefghijklmnopabcdefghijklmnop/options/index.html")
        XCTAssertEqual(p.resource, "options/index.html")
    }

    // MARK: - newtab-override detection

    func testNewTabOverrideMatchedByPath() {
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/newtab.html",
                     newTabOverride: "newtab.html")
        XCTAssertTrue(p.isNewTabOverride, "a page whose path is the newtab override restores as a newtab page")
    }

    func testNewTabOverrideMatchedDespiteLeadingSlashInManifest() {
        // A manifest may declare the override with a leading slash; the comparison normalizes both.
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/index.html",
                     newTabOverride: "/index.html")
        XCTAssertTrue(p.isNewTabOverride)
    }

    func testNewTabOverrideIgnoresQueryWhenMatchingPath() {
        // Detection compares the PATH only — a query on the restored URL doesn't defeat the match.
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/newtab.html?ref=1",
                     newTabOverride: "newtab.html")
        XCTAssertTrue(p.isNewTabOverride)
        XCTAssertEqual(p.resource, "newtab.html?ref=1")
    }

    func testOptionsPageIsNotNewTabOverride() {
        // A different page (the options page) with a newtab override present must NOT be treated as newtab.
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html",
                     newTabOverride: "newtab.html")
        XCTAssertFalse(p.isNewTabOverride)
    }

    func testNoOverrideDeclaredIsNotNewTab() {
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html", newTabOverride: nil)
        XCTAssertFalse(p.isNewTabOverride)
    }

    func testBareOriginIsNotNewTabOverrideEvenIfOverrideDeclared() {
        // Empty path must not spuriously match an override (guards the override == "" edge).
        let p = plan("chrome-extension://abcdefghijklmnopabcdefghijklmnop/", newTabOverride: "")
        XCTAssertFalse(p.isNewTabOverride)
    }
}
